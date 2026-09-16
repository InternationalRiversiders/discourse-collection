# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # 21075 collection_topic_added — tells a collection's subscribers that the collection
    # gained a topic (docs/09 §2). A collect enqueues this job with no delay, one run per
    # collect: the run is judged against the collect that opened it, never against the
    # collection as it stands when the run fires.
    #
    # A run *refreshes* the subscriber's notification for this collection rather than
    # appending another one. The notification carries no topic_id, so its identity is the
    # (user_id, data->>'collection_id') pair: a subscriber who already holds a row has it
    # rewritten — album name re-read, marked unread, moved to the top — and only a
    # subscriber without one gets a new row. Two runs racing on the same pair can therefore
    # leave two rows, which the collection's next collect collapses down to the highest id,
    # so repeated collects converge on one row per subscriber instead of piling up.
    #
    # Recipients are resolved live, as the run fires, rather than snapshotted at collect
    # time: the collection's subscriber rows minus the collecting user (never told about
    # their own collect) and minus subscribers with an active, unexpired ignore of the OP
    # of the collected topic (the same active-ignore scope core uses to fold that OP's
    # topics out of a subscriber's list, app/models/topic.rb:717, expiring_at:
    # Time.zone.now..). A staff OP is never "ignored", so nothing is excluded on that
    # account. The collection is re-checked too: a deleted collection cascades its
    # collection_topics and notifies nobody.
    #
    # Those recipients are then held to the topic's own visibility, since notifying a
    # subscriber about a topic the collection page would not show them is noise. The rules
    # are the reading page's own (docs/04 §1): a deleted topic notifies nobody, an unlisted
    # one is kept for the recipients that page would list it to (staff and TL4 — the same
    # guardian.can_see_unlisted_topics? it filters with), and everything else is the
    # recipient's own Guardian rather than a second statement of its rules.
    #
    # The notification carries no topic, so the destination is always the collection page.
    # data holds locators only: display_username (the slot the core renders as the first
    # line, fed the collection name) and collection_id (for the frontend renderer to build
    # the href). Both copy lines are written by the frontend renderer.
    class NotifyTopicAdded < ::Jobs::Base
      def execute(args = {})
        collection = ::DiscourseCollection::Collection.find_by(id: args[:collection_id])
        return if collection.nil?

        # A deleted topic is listed by the collection page to nobody (its feed joins on
        # topics.deleted_at IS NULL), so it notifies nobody here either — staff included,
        # which is why it is settled once rather than left to the recipients' Guardian
        # (can_see_topic? does serve a deleted topic to a moderator of its category).
        topic = ::Topic.find_by(id: args[:topic_id])
        return if topic.nil? || topic.deleted_at.present?

        recipient_ids = resolve_recipients(collection, topic, args[:actor_user_id])
        return if recipient_ids.empty?

        data = { display_username: collection.name, collection_id: collection.id }.to_json

        existing = existing_notifications(collection.id, recipient_ids)
        refreshing_ids = existing.map(&:last).uniq
        keep_ids, extra_ids = survivors(existing)
        fresh_ids = recipient_ids - refreshing_ids

        if keep_ids.present?
          refresh(keep_ids, extra_ids, data)

          # update_all and delete_all both bypass the model callbacks, and one of them is
          # where the live notification state is published from
          # (Notification#refresh_notification_count, after_commit). Left to itself, a
          # recipient whose row was refreshed would keep a stale badge, so push for them
          # here — the payload is computed on read, so it also covers the unread count the
          # collapse just lowered.
          ::User.where(id: refreshing_ids).find_each(&:publish_notifications_state)
        end

        # BulkCreate is the one path that pushes for the recipients it inserts; it is run
        # after the transaction above so that its push lands after the commit.
        return if fresh_ids.empty?

        ::Notification::Action::BulkCreate.call(
          records:
            fresh_ids.map do |user_id|
              { user_id: user_id, notification_type: notification_type, data: data }
            end,
          skip_send_email: true,
        )
      end

      private

      def notification_type
        ::Notification.types[:collection_topic_added]
      end

      def resolve_recipients(collection, topic, actor_user_id)
        recipient_ids = subscriber_ids(collection) - [actor_user_id]
        recipient_ids -= ignoring_ids(topic.user_id, recipient_ids)
        visible_ids(topic, recipient_ids)
      end

      def subscriber_ids(collection)
        ::DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).pluck(
          :user_id,
        )
      end

      # The subscribers who ignore the OP of the collected topic, and only while their
      # ignore is unexpired — an expired row (still awaiting core's purge job) no longer
      # suppresses notifications, and a staff OP is exempt from the rule (docs/09 §2).
      # Queried live so ignores added since the collect apply.
      def ignoring_ids(topic_author_id, recipient_ids)
        author = ::User.find_by(id: topic_author_id)
        return [] if author.nil? || author.staff?

        ::IgnoredUser
          .where(ignored_user_id: author.id, user_id: recipient_ids)
          .where(expiring_at: Time.zone.now..)
          .pluck(:user_id)
      end

      # Who among the recipients would find the collected topic on the collection page. A
      # listed topic in an unrestricted category, not deleted, not a private message and not
      # a shared draft is visible to everyone — the common case, settled once instead of per
      # recipient. Everything else is the recipient's own Guardian to judge, never a
      # re-statement of its rules in SQL. The category is required rather than read with a
      # safe navigation because can_see_category?(nil) is false, the opposite of an
      # unrestricted category — core's CHECK constraint keeps a regular topic from having no
      # category, so that branch is a fallback rather than a state to reason about.
      def visible_ids(topic, recipient_ids)
        return recipient_ids if freely_visible?(topic)

        users = ::User.where(id: recipient_ids).index_by(&:id)
        recipient_ids.select do |user_id|
          user = users[user_id]
          user.present? && listed_for?(user, topic)
        end
      end

      # The two rules the reading page applies to a single row (docs/04 §1): can_see_topic?
      # is its read gate, and unlisted is a listing rule it settles per visitor with
      # can_see_unlisted_topics?. A listed topic is kept for whoever may read it; an unlisted
      # one only for the staff and TL4 who would still be shown it.
      def listed_for?(user, topic)
        guardian = ::Guardian.new(user)
        guardian.can_see_topic?(topic) && (topic.visible || guardian.can_see_unlisted_topics?)
      end

      # An unlisted topic is never freely visible: it belongs to some recipients and not
      # others, so it has to go the per-recipient way.
      def freely_visible?(topic)
        category = topic.category
        topic.visible && category.present? && !category.read_restricted? &&
          topic.deleted_at.nil? && !topic.shared_draft? && !topic.private_message?
      end

      # The rows these recipients already hold for this collection. Read by user_id and
      # filtered on the collection_id inside data — the only index reaching them is
      # (user_id, created_at), since a row that is already read is exactly the one to
      # refresh rather than replace and so the query cannot carry the unread-only
      # predicate core's partial index is built on.
      def existing_notifications(collection_id, recipient_ids)
        ::Notification
          .where(user_id: recipient_ids, notification_type: notification_type)
          .where("data::jsonb ->> 'collection_id' = ?", collection_id.to_s)
          .pluck(:id, :user_id)
      end

      # Splits the rows a recipient holds into the one to keep — the highest id — and the
      # duplicates to drop. A run drops only rows its own snapshot saw and keeps the highest
      # of them itself, so however two overlapping runs interleave, the newest row either of
      # them saw is kept: the pair can never come out of a collapse empty.
      def survivors(existing)
        keep_ids = []
        extra_ids = []

        existing.group_by(&:last).each_value do |rows|
          ids = rows.map(&:first).sort
          keep_ids << ids.pop
          extra_ids.concat(ids)
        end

        [keep_ids, extra_ids]
      end

      # Collapses the duplicates and refreshes the survivors in one transaction. created_at
      # is set explicitly: every notification list orders on it (the full page by
      # created_at desc, the user menu within each block), so a refresh that left it alone
      # would not move the notification back to the top where a new one would have landed.
      def refresh(keep_ids, extra_ids, data)
        now = Time.zone.now

        ::Notification.transaction do
          ::Notification.where(id: extra_ids).delete_all if extra_ids.present?

          ::Notification.where(id: keep_ids).update_all(
            data: data,
            read: false,
            created_at: now,
            updated_at: now,
          )
        end
      end
    end
  end
end
