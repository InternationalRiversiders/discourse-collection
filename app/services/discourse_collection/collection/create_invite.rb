# frozen_string_literal: true

module DiscourseCollection
  # docs/05 §2.1 POST /collections/:id/invites.json — issue an invitation.
  #
  # Business rules (docs/05 §2.1): a type=0 (co-maintainer) invite may be issued by
  # the current owner only (an ownerless collection has nobody to invite); a type=1
  # (become the owner) invite by the current owner (self-transfer) or staff on any
  # collection (incl. designating a first owner on an ownerless one). Type=0 enforces the
  # co-maintainer cap at issue time — the row count is held on issue and only written
  # on accept, so the spot is reserved before the invitee answers; a pending type=1 is
  # unique per collection (one open ownership ticket at a time). The invite is process
  # state, not collection activity: updated_at / topic_count / last_topic_added_at are not
  # touched. Same-target-same-type idempotency is handled by the controller, which
  # returns the live pending row with 200 before this service runs — behind the rule
  # below, so the early return never answers a caller who may not issue the invite.
  #
  # One case leaves that flow behind entirely (docs/05 §2.7): a staff member naming
  # THEMSELVES as the new owner. There is nobody to wait for, so the invitation and its
  # acceptance land in the same transaction — the checks it keeps are the type=1 ones,
  # and the row it writes is already accepted, as the record of a takeover.
  class Collection::CreateInvite
    include Service::Base
    # The type=1 checks and the owner switch are shared with AcceptInvite, so a
    # self-takeover lands a transfer exactly the way an accepted invite does.
    include Collection::OwnershipTransfer

    params do
      attribute :id, :integer
      attribute :user_id, :integer
      attribute :action_type, :integer

      validates :id, :user_id, :action_type, presence: true
      validate :action_type_is_valid

      private

      def action_type_is_valid
        unless [
                 CollectionInvite::ACTION_TYPE_MAINTAINER,
                 CollectionInvite::ACTION_TYPE_OWNER,
               ].include?(action_type)
          errors.add(:base, I18n.t("discourse_collection.errors.invite_action_type_invalid"))
        end
      end
    end

    model :collection
    model :invitee, :fetch_invitee
    model :invite, :build_invite
    policy :can_create_invite

    transaction do
      # docs/05 §2.7 bypass: the inviter is the invitee and holds the staff management role,
      # so the ownership changes now instead of parking a question nobody would answer.
      # The regular steps below are skipped rather than re-tuned; the type=1 checks it
      # keeps and the transfer itself are the accept path's own
      # (Collection::OwnershipTransfer), so the two ways in cannot drift apart.
      only_if(:staff_self_takeover?) do
        step :ensure_inviter_is_not_the_owner
        step :ensure_no_pending_ownership_invite
        step :ensure_new_owner_in_create_allowed_groups
        step :ensure_new_owner_within_collection_cap
        step :ensure_ownership_transfer_within_teamworker_cap
        step :take_over_as_owner
      end

      only_if(:regular_invite?) do
        step :ensure_user_is_not_the_inviter
        only_if(:maintainer_invite?) do
          step :ensure_target_is_not_the_owner
          step :ensure_user_is_not_yet_maintainer
          step :ensure_target_in_teamworker_allowed_groups
          step :ensure_under_maintainer_cap
        end
        only_if(:ownership_invite?) do
          step :ensure_no_pending_ownership_invite
          step :ensure_target_in_create_allowed_groups
          step :ensure_ownership_transfer_within_teamworker_cap
        end
        step :persist_invite
      end
    end
    # Post-transaction: only after the invite row commits. Controller-side idempotency
    # (the live pending row is returned before this service runs) means a service
    # success is always a fresh invite — every run notifies, no context flag needed.
    # A self-takeover notifies nobody (docs/05 §2.7): the invitee IS the inviter, so a
    # "you have been invited" would only tell them what they just did.
    only_if(:regular_invite?) { step :enqueue_invitation_notification }
    # Post-transaction (docs/10): the bypass is a staff ownership change that has
    # already landed — there is no accept coming to log it at, so it is logged here.
    # A regular staff-initiated invite stays unlogged until its invitee accepts.
    only_if(:staff_self_takeover?) { step :record_owner_change_if_staff_initiated }

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def fetch_invitee(params:)
      User.find_by(id: params.user_id)
    end

    def build_invite(params:, collection:, invitee:, guardian:)
      CollectionInvite.new(
        collection_id: collection.id,
        inviter_user_id: guardian.user.id,
        invitee_user_id: invitee.id,
        action_type: params.action_type,
      )
    end

    # The rule lives on the policy because the controller asks it too, ahead of its
    # idempotent early return (docs/05 §2.1) — one definition, so the two cannot drift.
    def can_create_invite(collection:, guardian:, params:)
      CollectionPolicy.for(collection:, user: guardian.user).can_create_invite?(params.action_type)
    end

    def maintainer_invite?(params:)
      params.action_type == CollectionInvite::ACTION_TYPE_MAINTAINER
    end

    def ownership_invite?(params:)
      params.action_type == CollectionInvite::ACTION_TYPE_OWNER
    end

    # The one self-invite that is not refused (docs/05 §2.7): a staff member with the
    # collection management role — admin always, moderator only when the site setting is
    # on — asking to become the owner of a collection they do not own yet. Issue and
    # accept are the same act here, so the whole flow branches on this.
    def staff_self_takeover?(invite:, collection:, guardian:)
      invite.invitee_user_id == invite.inviter_user_id &&
        invite.action_type == CollectionInvite::ACTION_TYPE_OWNER &&
        CollectionPolicy.for(collection:, user: guardian.user).can_manage_collection?
    end

    def regular_invite?(invite:, collection:, guardian:)
      !staff_self_takeover?(invite:, collection:, guardian:)
    end

    # Every self-invite the bypass above does not cover is refused here: an owner
    # transferring to themselves (nothing to transfer) and a non-staff user inviting
    # themselves (no bypass for anyone else, docs/05 §2.7).
    def ensure_user_is_not_the_inviter(invite:)
      if invite.invitee_user_id == invite.inviter_user_id
        fail!(I18n.t("discourse_collection.errors.invite_self_not_allowed"))
      end
    end

    # docs/05 §2.7 check 1: there is no takeover left when the inviter already holds this
    # collection's owner row — this is also what stops an admin who owns the collection
    # from re-taking it over.
    def ensure_inviter_is_not_the_owner(collection:, invite:)
      is_owner =
        CollectionTeamworker
          .where(
            collection_id: collection.id,
            user_id: invite.inviter_user_id,
            is_owner: true,
          )
          .exists?
      fail!(I18n.t("discourse_collection.errors.already_the_owner")) if is_owner
    end

    # docs/05 §2.7 生效: the transfer lands here and now (same steps as a type=1 accept), and
    # the invite row is written already accepted — it is the trail of a staff takeover,
    # never a pending question, so it holds no spot and can never be answered or revoked.
    def take_over_as_owner(collection:, invite:)
      switch_owner(collection:, invite:)
      invite.accept = true
      invite.save!
    end

    def ensure_target_is_not_the_owner(collection:, invite:)
      is_owner =
        CollectionTeamworker
          .where(
            collection_id: collection.id,
            user_id: invite.invitee_user_id,
            is_owner: true,
          )
          .exists?
      if is_owner
        fail!(I18n.t("discourse_collection.errors.owner_membership_change_not_allowed"))
      end
    end

    def ensure_user_is_not_yet_maintainer(collection:, invite:)
      already_maintainer =
        CollectionTeamworker
          .where(
            collection_id: collection.id,
            user_id: invite.invitee_user_id,
            is_owner: false,
          )
          .exists?
      if already_maintainer
        fail!(I18n.t("discourse_collection.errors.already_a_maintainer"))
      end
    end

    # Admission gate at issue time (docs/05 §2.1): the type=0 target (the invitee,
    # fetched above — an unknown user 404s before any of this) must be in
    # collection_teamworker_allowed_groups right now. Checked ahead of the cap, so an
    # exempt operator still cannot invite someone the site settings forbid.
    def ensure_target_in_teamworker_allowed_groups(invitee:)
      unless CollectionPolicy.allowed_to_become_teamworker?(invitee)
        fail!(I18n.t("discourse_collection.errors.invitee_not_in_teamworker_allowed_groups"))
      end
    end

    # Admission gate at issue time (docs/05 §2.1): the type=1 target (the invitee) is
    # about to own this collection, so they must be in collection_create_allowed_groups
    # now — including when promoting an existing co-maintainer (their row flips is_owner true).
    def ensure_target_in_create_allowed_groups(invitee:)
      unless CollectionPolicy.allowed_to_create_collections?(invitee)
        fail!(I18n.t("discourse_collection.errors.invitee_not_in_create_allowed_groups"))
      end
    end

    def ensure_under_maintainer_cap(collection:, invite:, guardian:)
      return if CollectionPolicy.exempt_from_teamworker_cap?(guardian.user)

      max = SiteSetting.collection_max_teamworkers_per_collection
      co_maintainer_count =
        CollectionTeamworker.where(collection_id: collection.id, is_owner: false).count
      # The quota is held at issue time: live type=0 pending invites reserve spots too.
      pending =
        CollectionInvite.valid_pending.where(
          collection_id: collection.id,
          action_type: CollectionInvite::ACTION_TYPE_MAINTAINER,
        ).count
      if co_maintainer_count + pending >= max
        fail!(I18n.t("discourse_collection.errors.teamworker_limit_reached", max:))
      end
    end

    def ensure_no_pending_ownership_invite(collection:)
      pending_ownership =
        CollectionInvite.valid_pending.where(
          collection_id: collection.id,
          action_type: CollectionInvite::ACTION_TYPE_OWNER,
        ).exists?
      if pending_ownership
        fail!(I18n.t("discourse_collection.errors.ownership_invite_already_pending"))
      end
    end

    # Cap guard for a type=1 issue (docs/05 §2.1): a plain transfer demotes the
    # current owner on accept, growing the co-maintainer count by one. That growth is
    # allowed only up to cap+1 — refuse when co-maintainers already exceed the cap
    # (count >= cap+1), which would push a further transfer to cap+2. Three cases
    # never grow the count on accept and always pass: exempt roles (operator), an
    # ownerless collection (no one to demote), and promoting an existing co-maintainer
    # (their row flips is_owner true while the demoted owner joins — net flat).
    def ensure_ownership_transfer_within_teamworker_cap(collection:, invite:, guardian:)
      return if CollectionPolicy.exempt_from_teamworker_cap?(guardian.user)

      has_owner =
        CollectionTeamworker.where(collection_id: collection.id, is_owner: true).exists?
      return unless has_owner

      invitee_is_co_maintainer =
        CollectionTeamworker
          .where(
            collection_id: collection.id,
            user_id: invite.invitee_user_id,
            is_owner: false,
          )
          .exists?
      return if invitee_is_co_maintainer

      max = SiteSetting.collection_max_teamworkers_per_collection
      co_maintainer_count =
        CollectionTeamworker.where(collection_id: collection.id, is_owner: false).count
      if co_maintainer_count >= max + 1
        fail!(
          I18n.t(
            "discourse_collection.errors.ownership_transfer_teamworker_limit_reached",
            max:,
          ),
        )
      end
    end

    def persist_invite(invite:)
      invite.save!
    end

    # 21076 collection_invitation (docs/09 §1): the invitee is told an invite awaits
    # them in the inbox; action_type (0/1) rides in the payload for the copy.
    def enqueue_invitation_notification(invite:)
      ::Jobs.enqueue(::Jobs::DiscourseCollection::NotifyInvitation, invite_id: invite.id)
    end
  end
end
