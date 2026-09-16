# frozen_string_literal: true

module DiscourseCollection
  # DELETE /collections/:id.json — delete a collection (owner only, docs/02 §1 / docs/06 §2).
  #
  # Not open to staff and not available for ownerless collections (no owner row). Child rows
  # (teamworkers, topics, selected replies, subscribers) are removed by the DB-level
  # ON DELETE CASCADE foreign keys — no manual cleanup here.
  #
  # The notifications about the collection are the exception: `notifications` is a core table
  # no plugin FK reaches, and core's own cleanup is anchored on topic_id — which these rows
  # deliberately do not carry — so they are removed here or never. That removal runs as
  # Jobs::DiscourseCollection::PurgeCollectionNotifications, enqueued from a post-transaction
  # step instead of inline: its lookup is a `data::jsonb ->> 'collection_id'` expression that
  # no index matches, so waiting for it would tie the endpoint's response time to the forum's
  # notification volume rather than to this collection. Putting an index behind it is not the
  # way out either — the `data` expression indexes on that table are core's, made for core and
  # its bundled plugins, and a third-party plugin adding one has no guarantee it survives core
  # touching the column. docs/09 §4 has that reasoning in full, plus what the asynchronous
  # cleanup leaves inconsistent in between.
  class Collection::Delete
    include Service::Base

    params do
      attribute :id, :integer
      validates :id, presence: true
    end

    model :collection
    policy :can_delete_collection

    transaction do
      step :destroy_collection
    end
    # Post-transaction: the row is gone only once the delete has committed, and the enqueue
    # belongs on this side of it — enqueued inside, a rolled-back delete would hand the job a
    # collection that still exists. Enqueues carry the id, so the job reads nothing that the
    # delete removed.
    step :enqueue_notification_cleanup

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def can_delete_collection(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).owner?
    end

    def destroy_collection(collection:)
      collection.destroy!
    end

    def enqueue_notification_cleanup(collection:)
      ::Jobs.enqueue(
        ::Jobs::DiscourseCollection::PurgeCollectionNotifications,
        collection_id: collection.id,
      )
    end
  end
end
