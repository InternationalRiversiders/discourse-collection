# frozen_string_literal: true

module DiscourseCollection
  # Inbox shape for one invite (docs/05 §2.4): the invitee is omitted (every row
  # is "mine"), and the collection carries an owner snapshot (nullable = ownerless)
  # so the invitee can judge the collection without a second call (docs/03 §4) — especially for a
  # type=1 "become the owner" invite. Owner snapshots are pre-loaded per request by
  # the controller (owner_users option).
  class CollectionInviteInboxSerializer < CollectionInviteBaseSerializer
    def collection
      collection = object.collection
      owner = @options.fetch(:owner_users, {})[collection.id]
      {
        id: collection.id,
        name: collection.name,
        owner: owner && ::BasicUserSerializer.new(owner, scope:, root: false).as_json,
      }
    end
  end
end
