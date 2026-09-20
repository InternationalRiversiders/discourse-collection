# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # 21075 collection_topic_added — tells a collection's subscribers that the collection
    # gained a topic (docs/09 §2). A collect enqueues this job with no delay, one run per
    # collect: the run is judged against the collect that opened it, never against the
    # collection as it stands when the run fires.
    #
    # A run *replaces* the subscriber's notification for this collection rather than
    # appending another one: the rows this run's recipients already hold are deleted, and
    # one fresh row each is inserted, in a single transaction. The fresh row is what makes
    # the replacement visible — a notification counts as news only while its id is above
    # User#seen_notification_id, which is pushed up to the newest notification id every
    # time the user menu loads (NotificationsController#index →
    # User#bump_last_seen_notification!). User#unread_notifications and the header badge
    # User#all_unread_notifications_count both read that mark, so an id the subscriber has
    # already seen can never move either of them.
    #
    # One transaction rather than delete-then-insert, because a run interrupted between the
    # two would leave those subscribers with no notification at all: the invariant this job
    # keeps is "at least one", never zero. Two runs racing can still leave two rows (each
    # deletes only the ids its own snapshot saw); that is the harmless direction, and the
    # collection's next collect collapses it.
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
    # recipient's own Guardian rather than a second statement of its rules. A subscriber the
    # run filters out keeps the row they already held, untouched.
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

        inserted_ids = replace(collection.id, recipient_ids, data)

        # insert_all! and delete_all both bypass the model callbacks, and one of them is
        # where the live notification state is published from
        # (Notification#refresh_notification_count, after_commit), so every recipient is
        # pushed here.
        ::User.where(id: recipient_ids).find_each(&:publish_notifications_state)

        notify_created(inserted_ids)
      end

      private

      def notification_type
        ::Notification.types[:collection_topic_added]
      end

      # One transaction: the rows this batch already held go, one fresh row per recipient
      # comes in. Returns the inserted ids for the :notification_created replay below.
      def replace(collection_id, recipient_ids, data)
        stale_ids = stale_notification_ids(collection_id, recipient_ids)

        ::Notification.transaction do
          ::Notification.where(id: stale_ids).delete_all if stale_ids.present?

          ::Notification.insert_all!(rows(recipient_ids, data), returning: %i[id]).rows.flatten
        end
      end

      # The row a collect hands a recipient. topic_id / post_number stay NULL by omission —
      # their absence is the point of the type (docs/09 §1): it keeps core's per-topic read
      # and cleanup paths off these rows. high_priority is computed the way core computes it
      # for its own bulk inserts.
      def rows(recipient_ids, data)
        now = Time.zone.now
        high_priority = ::Notification.high_priority_types.include?(notification_type)

        recipient_ids.map do |user_id|
          {
            user_id: user_id,
            notification_type: notification_type,
            data: data,
            read: false,
            high_priority: high_priority,
            created_at: now,
            updated_at: now,
          }
        end
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

      # The rows this run's recipients already hold for this collection, read or not — all
      # of them are being replaced. Read by user_id and filtered on the collection_id inside
      # data: the only index reaching them is (user_id, created_at), because the query
      # cannot carry the unread-only predicate core's partial index is built on.
      def stale_notification_ids(collection_id, recipient_ids)
        ::Notification
          .where(user_id: recipient_ids, notification_type: notification_type)
          .where("data::jsonb ->> 'collection_id' = ?", collection_id.to_s)
          .pluck(:id)
      end

      # The event a core create fires from its own after_commit (app/models/notification.rb).
      # This job inserts its rows itself, so it replays it by hand — after the commit, like
      # the push above.
      def notify_created(inserted_ids)
        return if inserted_ids.empty?

        ::Notification
          .where(id: inserted_ids)
          .includes(:user)
          .find_each do |notification|
            ::DiscourseEvent.trigger(:notification_created, notification)
          end
      end
    end
  end
end
