# frozen_string_literal: true

module DiscourseCollection
  # Management / creation shape for one invite (docs/05 §2.1 create response,
  # docs/05 §2.3 per-collection record): every field, including the invitee.
  class CollectionInviteSerializer < CollectionInviteBaseSerializer
    attributes :invitee

    def invitee
      basic_user(object.invitee)
    end
  end
end
