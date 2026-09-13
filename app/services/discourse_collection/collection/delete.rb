# frozen_string_literal: true

module DiscourseCollection
  # DELETE /collections/:id.json — delete a collection (owner only, docs/02 §1 / docs/06 §2).
  #
  # Not open to staff and not available for ownerless collections (no owner row). Child rows
  # (teamworkers, topics, selected replies, subscribers) are removed by the DB-level
  # ON DELETE CASCADE foreign keys — no manual cleanup here.
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
  end
end
