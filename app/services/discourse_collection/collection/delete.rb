# frozen_string_literal: true

module DiscourseCollection
  # DELETE /collections/:id.json — delete a collection (owner only, docs/02 §1 / docs/06 §2).
  #
  # Not open to staff and not available for ownerless collections (no owner row). Child rows
  # (teamworkers, topics, selected replies, subscribers) are removed by the DB-level
  # ON DELETE CASCADE foreign keys — no manual cleanup here. The notifications about the
  # collection are the exception: `notifications` is a core table no plugin FK reaches, and
  # core's own cleanup is anchored on topic_id — which these rows deliberately do not carry
  # — so they are deleted here or never.
  class Collection::Delete
    include Service::Base

    params do
      attribute :id, :integer
      validates :id, presence: true
    end

    model :collection
    policy :can_delete_collection

    transaction do
      step :purge_collection_notifications
      step :destroy_collection
    end
    # Post-transaction: the rows are gone only once the delete has committed.
    step :publish_notifications_state

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def can_delete_collection(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).owner?
    end

    # Every notification ever written for this collection — all four types of docs/09 §1,
    # since a deleted collection leaves each of them pointing nowhere. Inside the
    # transaction so a failed delete takes the purge down with it: left for afterwards,
    # "collection gone, notifications stranded" would be a state nothing ever reaches
    # again. The user ids are read first — the rows are what names them.
    def purge_collection_notifications(collection:)
      scope =
        ::Notification
          .where(
            notification_type: [
              ::Notification.types[:collection_topic_added],
              ::Notification.types[:collection_invitation],
              ::Notification.types[:collection_invitation_accepted],
              ::Notification.types[:collection_invitation_declined],
            ],
          )
          .where("data::jsonb ->> 'collection_id' = ?", collection.id.to_s)

      context[:notified_user_ids] = scope.distinct.pluck(:user_id)
      scope.delete_all
    end

    def destroy_collection(collection:)
      collection.destroy!
    end

    # delete_all bypasses the AR callbacks, and the live notification state is published
    # from one of them (Notification#refresh_notification_count, after_commit) — so the
    # users whose rows are gone are pushed here instead. Loaded fresh: the counts
    # publish_notifications_state reads are memoized per instance.
    def publish_notifications_state(notified_user_ids:)
      ::User.where(id: notified_user_ids).find_each(&:publish_notifications_state)
    end
  end
end
