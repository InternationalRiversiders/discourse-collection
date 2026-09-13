# frozen_string_literal: true

module DiscourseCollection
  # Shared invitation shape (docs/05 §2.1 / §2.3 / §2.4). status is computed on
  # the fly from created_at and the two time-gate settings; expires_at = created_at +
  # validity. inviter may be nil (account deleted — FK is SET NULL), so it is guarded.
  class CollectionInviteBaseSerializer < ::ApplicationSerializer
    attributes :id,
               :action_type,
               :status,
               :inviter,
               :collection,
               :created_at,
               :expires_at

    def inviter
      basic_user(object.inviter)
    end

    # Management shape: the collection is only a pointer (id + name) — full collection
    # detail is fetched via docs/03 §4. The inbox shape overrides this to carry an owner
    # snapshot (see CollectionInviteInboxSerializer).
    def collection
      collection = object.collection
      { id: collection.id, name: collection.name }
    end

    def status
      object.status
    end

    def expires_at
      object.expires_at
    end

    private

    def basic_user(user)
      user && ::BasicUserSerializer.new(user, scope:, root: false).as_json
    end
  end
end
