# frozen_string_literal: true

module DiscourseCollection
  # Landing a type=1 ownership transfer (docs/05 §2.5 type=1): the checks the incoming
  # owner must still pass and the row writes that actually switch the owner. Two
  # different requests arrive here and must behave identically — an invitee accepting a
  # pending invite (AcceptInvite), and a staff member taking a collection over as they
  # invite themselves (CreateInvite's docs/05 §2.7 bypass) — so the logic is shared instead of
  # copied. In both, `invite.invitee_user_id` is the incoming owner and `guardian.user`
  # is the person the change is attributed to.
  module Collection::OwnershipTransfer
    private

    # Admission gate on a transfer (docs/05 §2.5 / docs/05 §2.7): the incoming owner must be
    # in collection_create_allowed_groups right now. Refusal rolls the transaction back,
    # so nothing of the transfer is written.
    def ensure_new_owner_in_create_allowed_groups(guardian:)
      unless CollectionPolicy.allowed_to_create_collections?(guardian.user)
        fail!(I18n.t("discourse_collection.errors.new_owner_not_in_create_allowed_groups"))
      end
    end

    # Cap guard on a transfer (docs/05 §2.5 step 0 / docs/05 §2.7): the incoming owner is
    # about to own one more collection (is_owner=true rows). The path is allowed up to
    # cap+1 — refuse when they already own more than the cap (owned >= cap+1), which
    # would push a further transfer to cap+2; exempt roles pass.
    def ensure_new_owner_within_collection_cap(invite:, guardian:)
      return if CollectionPolicy.exempt_from_collection_cap?(guardian.user)

      max = SiteSetting.collection_max_collections_per_user
      owned = CollectionTeamworker.where(user_id: invite.invitee_user_id, is_owner: true).count
      if owned >= max + 1
        fail!(
          I18n.t(
            "discourse_collection.errors.ownership_accept_collection_limit_reached",
            max:,
          ),
        )
      end
    end

    # The transfer itself (docs/05 §2.5 type=1 steps 1-5): the incoming owner's row is
    # the owner row (inserted, or an existing co-maintainer row flipped), the sitting
    # owner — if any — is demoted and stays on as a co-maintainer, the new owner ends up
    # subscribed but never counted, subscribers_count is recomputed from the table, and
    # the collection's updated_at is bumped. topic_count / last_topic_added_at are
    # untouched. The displaced owner's username is left in the context for the
    # post-transaction audit step.
    def switch_owner(collection:, invite:)
      new_owner_id = invite.invitee_user_id

      # Demote the current owner first so the partial unique index (single is_owner
      # row per collection) is never violated mid-transaction. An ownerless collection has
      # nothing to demote — the incoming owner simply becomes the first owner.
      owner_row = CollectionTeamworker.find_by(collection_id: collection.id, is_owner: true)
      if owner_row && owner_row.user_id != new_owner_id
        # Snapshot the displaced owner's username for the post-transaction audit step
        # (docs/10 §2); an ownerless collection has no owner to record.
        context[:previous_owner_username] = owner_row.user&.username
        owner_row.update!(is_owner: false)
      end

      # Promote the incoming owner (existing co-maintainer row -> is_owner=true, else insert).
      existing =
        CollectionTeamworker.find_by(collection_id: collection.id, user_id: new_owner_id)
      if existing
        existing.update!(is_owner: true)
      else
        CollectionTeamworker.create!(
          collection_id: collection.id,
          user_id: new_owner_id,
          is_owner: true,
        )
      end

      # Becoming the owner auto-subscribes but never counts (docs/08 §1): keep any
      # existing subscription row (it simply stops counting) or add one. The demoted
      # ex-owner's own row (if any) is no longer the owner's and starts counting again,
      # so the count is recomputed from the table rather than hand-tuned.
      unless CollectionSubscriber.exists?(collection_id: collection.id, user_id: new_owner_id)
        CollectionSubscriber.create!(collection_id: collection.id, user_id: new_owner_id)
      end
      Collection.recompute_subscribers_count!(collection)

      collection.update!(updated_at: Time.zone.now)
    end

    # A type=1 transfer issued by staff (incl. staff naming a first owner on an
    # ownerless collection, and the docs/05 §2.7 self-takeover) is an admin action, logged
    # with the staff inviter as the acting user and the new owner in target_user_id
    # (docs/10 §2). log_custom's base_attrs carry no target_user_id, so this row is
    # written directly (the core log_access_control_list_permission_change precedent).
    # An owner-initiated transfer is routine owner management and is skipped, as is a
    # deleted inviter (inviter FK ON DELETE SET NULL — nothing to attribute).
    def record_owner_change_if_staff_initiated(invite:)
      return if invite.action_type == CollectionInvite::ACTION_TYPE_MAINTAINER

      inviter = invite.inviter
      return if inviter.blank? || !inviter.staff?

      UserHistory.create!(
        action: UserHistory.actions[:custom_staff],
        custom_type: "collection_owner_change",
        acting_user_id: inviter.id,
        target_user_id: invite.invitee_user_id,
        subject: "Collection (#{invite.collection_id})",
        context: invite.collection.name,
        previous_value: context[:previous_owner_username],
        new_value: invite.invitee&.username,
      )
    end
  end
end
