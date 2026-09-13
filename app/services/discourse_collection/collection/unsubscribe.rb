# frozen_string_literal: true

module DiscourseCollection
  # DELETE /collections/:id/subscription.json — unsubscribe (any signed-in user).
  #
  # Idempotent: no subscription row is a no-op 200. Unsubscribing deletes the acting
  # user's row. The collection owner never counts (docs/08 §1 — the owner's own row, if
  # present, is excluded from subscribers_count), so deleting the owner's row does not
  # decrement the count — only a non-owner unsubscribe takes it down by 1.
  class Collection::Unsubscribe
    include Service::Base

    params do
      attribute :id, :integer

      validates :id, presence: true
    end

    model :collection

    transaction do
      step :unsubscribe
    end

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def unsubscribe(collection:, guardian:)
      user = guardian.user
      row = CollectionSubscriber.find_by(collection_id: collection.id, user_id: user.id)
      return if row.blank?

      is_owner =
        CollectionTeamworker.exists?(collection_id: collection.id, user_id: user.id, is_owner: true)

      row.destroy!
      Collection.decrement_subscribers_count!(collection) unless is_owner
    end
  end
end
