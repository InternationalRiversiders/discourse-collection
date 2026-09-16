# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # Removes the notifications a deleted collection left behind (docs/09 §4). Core's own
    # cleanup of "notifications about a deleted thing" is anchored on topic_id — a key these
    # four types deliberately do not carry — so nothing but this plugin ever reaches them.
    #
    # Enqueued after the delete commits rather than run inside it: the lookup is a
    # `data::jsonb ->> 'collection_id'` expression over the core notifications table, which no
    # index matches (the `data` expression indexes core carries are core's own, and a
    # third-party plugin adding one to that table has no guarantee behind it) — so running it
    # in the request made the delete endpoint's response time follow the forum's total
    # notification volume instead of the collection's own size. The price is the window
    # between the commit and this run, in which a notification still points at a collection
    # that is already gone, and a run that never happens leaves the rows where they are.
    #
    # Idempotent: the row set is addressed by the locator alone, so a retry deletes whatever
    # is left of it.
    class PurgeCollectionNotifications < ::Jobs::Base
      def execute(args = {})
        collection_id = args[:collection_id]
        return if collection_id.blank?

        scope = notification_scope(collection_id)
        # Read before the delete: the rows are what name the users. Everyone whose badge moved
        # has to be published for explicitly — delete_all bypasses the AR callbacks, and the
        # live state is published from one of them (Notification#refresh_notification_count,
        # after_commit).
        notified_user_ids = scope.distinct.pluck(:user_id)
        scope.delete_all

        # Loaded fresh: the counts publish_notifications_state reads are memoized per instance.
        ::User.where(id: notified_user_ids).find_each(&:publish_notifications_state)
      end

      private

      # Every notification ever written for this collection — all four types of docs/09 §1,
      # since a deleted collection leaves each of them pointing nowhere. ->> reads text, so
      # the locator is compared as a string. The type clause stays as the "this plugin's
      # types only" guard.
      def notification_scope(collection_id)
        ::Notification
          .where(
            notification_type: [
              ::Notification.types[:collection_topic_added],
              ::Notification.types[:collection_invitation],
              ::Notification.types[:collection_invitation_accepted],
              ::Notification.types[:collection_invitation_declined],
            ],
          )
          .where("data::jsonb ->> 'collection_id' = ?", collection_id.to_s)
      end
    end
  end
end
