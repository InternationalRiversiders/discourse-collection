# frozen_string_literal: true

module DiscourseCollection
  # PUT /collections/:id/read_notifications.json — mark everything the caller has unread
  # about this collection as read.
  #
  # Core marks a notification read on two paths only: clicking the notification itself
  # (the Discourse-Clear-Notifications header, by id) or an explicit dismiss. "Arriving at
  # the object the notification talks about" exists for topics alone
  # (Notification.mark_posts_read, which matches on topic_id + post_number) — keys these
  # rows deliberately do not carry — so a visitor reaching the collection page from the
  # list, the activity tab or a direct link keeps a stale unread badge, counted in the red
  # dot. The three types pointing at the collection page (docs/09 §1) are covered here;
  # 21076 points at the invitation inbox instead, and is deleted outright once it is
  # answered or revoked.
  #
  # Only the caller's own rows are touched, so there is no policy: having opened the page
  # is what this records. The write is a single UPDATE — nothing has to succeed or fail
  # with it — so no transaction wraps it.
  class Collection::MarkNotificationsRead
    include Service::Base

    params do
      attribute :id, :integer

      validates :id, presence: true
    end

    model :collection

    step :mark_notifications_read
    step :publish_notifications_state

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    # Scoped to the caller, so the scan is bounded by their own notifications rather than by
    # the table, and read: false keeps already-read rows out of the update. `data ->>`
    # returns text, hence the string the collection id is compared against. The unread ids
    # are read first: an empty result means there is nothing to write and nobody to publish
    # for — the common case, since the client gate opens per type rather than per collection.
    def mark_notifications_read(collection:, guardian:)
      user = guardian.user
      unread_ids =
        ::Notification
          .where(
            user_id: user.id,
            notification_type: [
              ::Notification.types[:collection_topic_added],
              ::Notification.types[:collection_invitation_accepted],
              ::Notification.types[:collection_invitation_declined],
            ],
            read: false,
          )
          .where("data::jsonb ->> 'collection_id' = ?", collection.id.to_s)
          .pluck(:id)

      if unread_ids.empty?
        context[:affected_user_ids] = []
      else
        ::Notification.read(user, unread_ids)
        context[:affected_user_ids] = [user.id]
      end
    end

    # update_all bypasses the AR callbacks, and the live notification state is published
    # from one of them (Notification#refresh_notification_count, after_commit) — so the
    # caller is pushed here instead, from a freshly loaded row: the counts
    # publish_notifications_state reads are memoized per instance. An empty list pushes
    # nothing, which is how the no-unread path stays free.
    def publish_notifications_state(affected_user_ids:)
      ::User.where(id: affected_user_ids).find_each(&:publish_notifications_state)
    end
  end
end
