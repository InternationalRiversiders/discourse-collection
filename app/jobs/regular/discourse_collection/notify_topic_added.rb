# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # 21075 collection_topic_added — tells a collection's subscribers that they gained
    # topics (docs/09 §2). A fresh collect (docs/04 §3) schedules this job one silence window
    # out; every further collect schedules another run stamped with the membership row it
    # inserted, so a burst keeps pushing the deadline out and only its last run sends.
    #
    # What a run sends therefore depends on one live comparison: its stamp must still be the
    # created_at of the collection's newest membership row. A run scheduled by an earlier
    # collect — or by a collect that has since been un-collected — finds a different newest
    # row and stays quiet; un-collecting some older topic leaves the newest row alone and
    # the run goes out. Nothing has to be tracked or cleared to reach that verdict, which is
    # the point of the design (TopicAddedNotificationBatch has the full rules).
    #
    # Nothing else about the batch is snapshotted either: recipients are resolved live — the
    # collection's subscriber rows minus the collecting user (never told about their own
    # collect) and minus subscribers with an active, unexpired ignore of the OP of the topic
    # that opened this run (docs/09 §2; the same active-ignore scope core uses to fold
    # that OP's topics out of a subscriber's list, app/models/topic.rb:717, expiring_at:
    # Time.zone.now..). A staff OP is never "ignored", so nothing is excluded on that
    # account. The collection is re-checked too: a deleted collection cascades its
    # collection_topics and notifies nobody.
    #
    # The notification carries no topic — a batch may span several, so the destination is
    # always the collection page. data holds locators only: display_username (the slot the
    # core renders as the first line, fed the collection name) and collection_id (for the
    # frontend renderer to build the href). Both copy lines are written by the frontend
    # renderer.
    class NotifyTopicAdded < ::Jobs::Base
      def execute(args = {})
        collection_id = args[:collection_id]
        stamp = args[:stamp]
        batch = ::DiscourseCollection::TopicAddedNotificationBatch

        return unless batch.current?(collection_id, stamp)

        collection = ::DiscourseCollection::Collection.find_by(id: collection_id)
        return if collection.nil?

        # Claimed after the collection is found, so a retry of this run — the one case that
        # reaches the same stamp twice — cannot notify everybody a second time.
        return unless batch.claim!(collection_id, stamp)

        recipient_ids = subscriber_ids(collection) - [args[:actor_user_id]]
        recipient_ids -= ignoring_ids(args[:topic_author_id], recipient_ids)
        return if recipient_ids.empty?

        data = { display_username: collection.name, collection_id: collection.id }.to_json

        recipient_ids.each do |user_id|
          ::Notification.create!(
            notification_type: ::Notification.types[:collection_topic_added],
            user_id: user_id,
            data: data,
          )
        end
      end

      private

      def subscriber_ids(collection)
        ::DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).pluck(
          :user_id,
        )
      end

      # The subscribers who ignore the OP of the topic that opened this run, and only while
      # their ignore is unexpired — an expired row (still awaiting core's purge job) no longer
      # suppresses notifications, and a staff OP is exempt from the rule (docs/09 §2). Queried
      # live so ignores added since the collect apply.
      def ignoring_ids(topic_author_id, recipient_ids)
        author = ::User.find_by(id: topic_author_id)
        return [] if author.nil? || author.staff?

        ::IgnoredUser
          .where(ignored_user_id: author.id, user_id: recipient_ids)
          .where(expiring_at: Time.zone.now..)
          .pluck(:user_id)
      end
    end
  end
end
