# frozen_string_literal: true

module DiscourseCollection
  # docs/05 §2.5 POST /collections/invites/:invite_id/accept.json — accept an invitation.
  #
  # Common gate (with RejectInvite): the invite must exist and belong to the caller
  # (fetch scopes on invitee_user_id -> 404) and be a live pending row (accept NULL
  # inside the validity window -> else 422). Semantics per action_type:
  #   type=0 (join as co-maintainer): insert an is_owner=false row, or no-op when the
  #     invitee already holds one (the invite is still marked accepted). The cap was
  #     held at issue time, so accept only writes the row.
  #   type=1 (become the new owner): demote the current owner first (so the partial
  #     unique single-owner index is never momentarily violated), then promote the
  #     invitee (existing membership row or a fresh is_owner=true row); the new owner
  #     auto-subscribes (docs/08 §1) and subscribers_count is recomputed. Old owner is
  #     always demoted, never removed (their subscription row starts counting again).
  # In both cases the collection's updated_at is bumped to now; topic_count /
  # last_topic_added_at are untouched.
  class Collection::AcceptInvite
    include Service::Base
    # The type=1 checks and the owner switch are shared with the staff self-takeover
    # bypass (CreateInvite / docs/05 §2.7), so both paths land a transfer the same way.
    include Collection::OwnershipTransfer

    params do
      attribute :invite_id, :integer

      validates :invite_id, presence: true
    end

    model :invite, :fetch_invite
    model :collection, :fetch_collection

    transaction do
      step :ensure_pending
      only_if(:ownership_invite?) do
        step :ensure_new_owner_in_create_allowed_groups
        step :ensure_new_owner_within_collection_cap
        step :switch_owner
      end
      only_if(:maintainer_invite?) do
        step :ensure_joiner_in_teamworker_allowed_groups
        step :join_as_maintainer_on_accept
      end
      step :mark_accepted
    end
    # Post-transaction: only after the invite commits as accepted. Every successful
    # run (incl. the idempotent "already a co-maintainer" type=0 path) flips the row
    # from pending to accepted, so a result notification is always due — on a type=1
    # accept the inviter is demoted by now yet is still told (docs/09 §1).
    step :enqueue_result_notification
    # Post-transaction (docs/10 / docs/05 §2.5 step 6): once a type=1 accept has really
    # landed, a transfer issued by staff is an admin action and is logged here — the
    # acting user is the staff inviter, the target the new owner. type=0 accepts and
    # owner-initiated transfers are routine, not logged.
    step :record_owner_change_if_staff_initiated

    private

    def fetch_invite(params:, guardian:)
      # Scoping on invitee_user_id makes someone else's invite invisible (404).
      CollectionInvite.find_by(id: params.invite_id, invitee_user_id: guardian.user.id)
    end

    def fetch_collection(invite:)
      invite.collection
    end

    def ownership_invite?(invite:)
      invite.action_type == CollectionInvite::ACTION_TYPE_OWNER
    end

    def maintainer_invite?(invite:)
      invite.action_type == CollectionInvite::ACTION_TYPE_MAINTAINER
    end

    def ensure_pending(invite:)
      fail!(I18n.t("discourse_collection.errors.invite_not_pending")) unless invite.pending?
    end

    # Admission gate on a type=0 accept (docs/05 §2.5): the invitee is about to hold
    # an is_owner=false row, so they must be in collection_teamworker_allowed_groups
    # right now. Refusal rolls the transaction back — the invite stays pending.
    def ensure_joiner_in_teamworker_allowed_groups(guardian:)
      unless CollectionPolicy.allowed_to_become_teamworker?(guardian.user)
        fail!(I18n.t("discourse_collection.errors.joiner_not_in_teamworker_allowed_groups"))
      end
    end

    def join_as_maintainer_on_accept(collection:, invite:)
      user_id = invite.invitee_user_id

      # Defensive re-check: the invitee may have become the owner since the invite was
      # issued; owner-row changes only ever go through a type=1 invite.
      owner_row = CollectionTeamworker.find_by(collection_id: collection.id, is_owner: true)
      if owner_row&.user_id == user_id
        fail!(I18n.t("discourse_collection.errors.owner_membership_change_not_allowed"))
        return
      end

      # Already a co-maintainer (e.g. re-invited) -> idempotent no-op: skip the insert
      # and the updated_at bump, just mark the invite accepted.
      return if CollectionTeamworker.exists?(
        collection_id: collection.id,
        user_id:,
        is_owner: false,
      )

      CollectionTeamworker.create!(
        collection_id: collection.id,
        user_id:,
        is_owner: false,
      )
      collection.update!(updated_at: Time.zone.now)
    end

    def mark_accepted(invite:)
      invite.update!(accept: true)
    end

    # 21077 collection_invitation_accepted (docs/09 §1): the inviter learns their
    # invite was accepted. The job reads accept itself, so only the row id is passed.
    def enqueue_result_notification(invite:)
      ::Jobs.enqueue(::Jobs::DiscourseCollection::NotifyInvitationResult, invite_id: invite.id)
    end
  end
end
