# frozen_string_literal: true

module DiscourseCollection
  # docs/05 §2.2 DELETE /collections/:id/invites/:invite_id.json — revoke a pending
  # invitation.
  #
  # Two ways in (docs/05 §2.2): the issuer's own withdrawal, or a management action
  # — a staff member holding the management role may call off ANY live pending
  # invitation of the collection, whatever its action_type and whoever issued it (a
  # departed or merely mistaken issuer would otherwise leave a placeholder nobody can
  # clear). Anyone else -> 403. An answered or expired row is not revocable -> 422.
  #
  # Success physically deletes the row (revocation representation is a row delete, so
  # the freed spot is immediately reusable and the revoked invite never blocks a
  # re-invite). Calling off someone ELSE's invitation is a management action and is
  # audited (docs/10, the 5th custom type); withdrawing one's own is not.
  class Collection::RevokeInvite
    include Service::Base

    params do
      attribute :id, :integer
      attribute :invite_id, :integer

      validates :id, :invite_id, presence: true
    end

    model :collection
    model :invite, :fetch_invite
    policy :can_revoke

    transaction do
      step :ensure_pending
      step :capture_revoke_audit
      step :purge_invite_notification
      step :destroy_invite
    end
    # Post-transaction: the invitee's notification is gone only once the revoke commits.
    step :publish_notifications_state
    # Post-transaction (docs/10 §1): only a revocation of someone else's invitation
    # is a management action worth a log row. It reads the snapshot taken inside the
    # transaction, because the row it describes is gone by now.
    step :record_invite_revoke

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def fetch_invite(params:)
      # The invite must belong to the collection in the URL (404 otherwise).
      CollectionInvite.find_by(id: params.invite_id, collection_id: params.id)
    end

    # The issuer's own call, or a staff management action. The management role is read
    # off the revoker's rights at this moment only (docs/05 §2.2 边界) — who issued
    # the invitation is no part of it.
    def can_revoke(collection:, invite:, guardian:)
      user = guardian.user
      return false if user.blank?

      invite.inviter_user_id == user.id ||
        CollectionPolicy.for(collection:, user:).can_manage_collection?
    end

    def ensure_pending(invite:)
      fail!(I18n.t("discourse_collection.errors.invite_not_pending")) unless invite.pending?
    end

    # Everything the audit row needs, read while the row still exists — the issuer's
    # id (the log's target), the collection name snapshot, and the wording of what the
    # invitation was about to do (docs/10 写入时机).
    def capture_revoke_audit(collection:, invite:, guardian:)
      context[:revoke_audit] = {
        proxy: invite.inviter_user_id != guardian.user.id,
        inviter_user_id: invite.inviter_user_id,
        collection_id: collection.id,
        collection_name: collection.name,
        details: revoke_details(collection:, invite:),
      }
    end

    def destroy_invite(invite:)
      invite.destroy!
    end

    # 21076 (docs/09 §1) is a question waiting to be answered, and a revoked invitation is
    # no longer one — the notification would still be pointing at a request that cannot be
    # granted. Located by invite_id rather than by collection_id: the invitee may be
    # holding another pending invitation for the same collection, and that one's
    # notification is still owed. Scoped on the invitee — the only user it was ever written
    # for, which keeps this off a scan of the whole core notifications table. The id is kept
    # in the context because the row that locates the notification is gone by the time the
    # push runs.
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

    # The staff-action-log row for a proxy revocation: acting user = the revoker,
    # target = whoever issued the invitation that was called off (docs/10 §1 第 5 型).
    # previous_value / new_value stay empty — the intent lives in details instead.
    def record_invite_revoke(revoke_audit:, guardian:)
      return unless revoke_audit[:proxy]

      UserHistory.create!(
        action: UserHistory.actions[:custom_staff],
        custom_type: "collection_invite_revoke",
        acting_user_id: guardian.user.id,
        target_user_id: revoke_audit[:inviter_user_id],
        subject: "Collection (#{revoke_audit[:collection_id]})",
        context: revoke_audit[:collection_name],
        details: revoke_audit[:details],
      )
    end

    # What the called-off invitation was about to do, as a language-neutral symbol
    # (docs/10 §1): a transfer reads "old owner → invitee", a co-maintainer invite
    # "issuer + invitee". Both sides are usernames, so the row needs no translation.
    def revoke_details(collection:, invite:)
      transfer = invite.action_type == CollectionInvite::ACTION_TYPE_OWNER
      left = transfer ? current_owner_username(collection) : invite.inviter&.username
      separator = transfer ? "→" : "+"

      "#{username_or_missing(left)} #{separator} #{username_or_missing(invite.invitee&.username)}"
    end

    # The owner a transfer would have replaced, as of NOW — the log records the
    # transfer that was called off, not the one that may have been proposed before it.
    def current_owner_username(collection)
      CollectionTeamworker.find_by(collection_id: collection.id, is_owner: true)&.user&.username
    end

    # A side the log cannot name: the account is gone (both user FKs are ON DELETE SET
    # NULL), or an ownerless collection has no sitting owner to replace.
    def username_or_missing(username)
      username.presence || "❌"
    end
  end
end
