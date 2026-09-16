# frozen_string_literal: true

module DiscourseCollection
  # docs/05 §2.5 POST /collections/invites/:invite_id/reject.json — reject an invitation.
  #
  # Common gate (with AcceptInvite): the invite must exist and belong to the caller
  # (404) and be a live pending row (422). Rejecting produces no membership or owner
  # write: it only records accept=false, which releases the spot held at issue time
  # (the row stops being "pending" and no longer blocks a re-invite).
  class Collection::RejectInvite
    include Service::Base

    params do
      attribute :invite_id, :integer

      validates :invite_id, presence: true
    end

    model :invite, :fetch_invite

    transaction do
      step :ensure_pending
      step :reject_invite
      step :purge_invite_notification
    end
    # Post-transaction: the invitee's notification is gone only once the reject commits.
    step :publish_notifications_state
    # Post-transaction: only after the invite commits as rejected. Rejecting is a
    # terminal state change, so a result notification to the inviter is always due.
    step :enqueue_result_notification

    private

    def fetch_invite(params:, guardian:)
      # Scoping on invitee_user_id makes someone else's invite invisible (404).
      CollectionInvite.find_by(id: params.invite_id, invitee_user_id: guardian.user.id)
    end

    def ensure_pending(invite:)
      fail!(I18n.t("discourse_collection.errors.invite_not_pending")) unless invite.pending?
    end

    def reject_invite(invite:)
      invite.update!(accept: false)
    end

    # 21076 (docs/09 §1) is a question waiting to be answered, and this one has been — the
    # notification would still be pointing at a request the invitee just turned down.
    # Located by invite_id rather than by collection_id: the invitee may be holding another
    # pending invitation for the same collection, and that one's notification is still owed.
    # Scoped on the invitee — the only user it was ever written for, which keeps this off a
    # scan of the whole core notifications table. The id is kept in the context for the
    # post-transaction push.
    def purge_invite_notification(invite:)
      context[:notified_user_ids] = [invite.invitee_user_id].compact

      ::Notification
        .where(
          user_id: invite.invitee_user_id,
          notification_type: ::Notification.types[:collection_invitation],
        )
        .where("data::jsonb ->> 'invite_id' = ?", invite.id.to_s)
        .delete_all
    end

    # delete_all bypasses the AR callbacks, and the live notification state is published
    # from one of them (Notification#refresh_notification_count, after_commit) — so the
    # users whose rows are gone are pushed here instead. Loaded fresh: the counts
    # publish_notifications_state reads are memoized per instance.
    def publish_notifications_state(notified_user_ids:)
      ::User.where(id: notified_user_ids).find_each(&:publish_notifications_state)
    end

    # 21078 collection_invitation_declined (docs/09 §1): the inviter learns their
    # invite was declined. The job picks 21077 vs 21078 from accept, so only the id is
    # passed (shared with AcceptInvite's enqueue).
    def enqueue_result_notification(invite:)
      ::Jobs.enqueue(::Jobs::DiscourseCollection::NotifyInvitationResult, invite_id: invite.id)
    end
  end
end
