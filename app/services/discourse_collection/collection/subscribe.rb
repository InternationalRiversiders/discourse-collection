# frozen_string_literal: true

module DiscourseCollection
  # POST /collections/:id/subscription.json — subscribe (any signed-in user).
  #
  # Idempotent: an existing subscription row is a no-op 200. Subscribing inserts one
  # collection_subscribers row. The collection owner never counts (docs/08 §1 — owner
  # auto-subscribes on creation/promotion and stays counted-zero even after an
  # unsubscribe/resubscribe cycle), so only a non-owner subscribe bumps the stored
  # subscribers_count by +1. Subscription is not collection activity: updated_at is not
  # touched (docs/08 only maintains subscribers_count here).
  class Collection::Subscribe
    include Service::Base

    params do
      attribute :id, :integer

      validates :id, presence: true
    end

    model :collection

    transaction do
      step :subscribe
    end

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def subscribe(collection:, guardian:)
      user = guardian.user
      return if CollectionSubscriber.exists?(collection_id: collection.id, user_id: user.id)

      is_owner =
        CollectionTeamworker.exists?(collection_id: collection.id, user_id: user.id, is_owner: true)

      CollectionSubscriber.create!(collection_id: collection.id, user_id: user.id)

      Collection.increment_subscribers_count!(collection) unless is_owner
    end
  end
end
