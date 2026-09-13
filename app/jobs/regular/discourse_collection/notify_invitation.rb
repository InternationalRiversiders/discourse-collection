# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # 21076 collection_invitation — tell the invitee they were invited to become a
    # co-maintainer (action_type=0) or the new owner (action_type=1) of a collection
    # (docs/09 §1). Queued once per fresh issue (docs/05 §2.1) (controller-side idempotency
    # returns the live pending row before this service runs, so a repeat invite never
    # re-queues). Runs async, and the row is re-checked before anything is created:
    # an invite that was revoked (physically deleted => row gone), already answered or
    # expired by the time the job runs is not notified. An initiator whose account was
    # deleted (FK ON DELETE SET NULL) gets nothing — there is nobody to credit.
    class NotifyInvitation < ::Jobs::Base
      def execute(args = {})
        invite =
          ::DiscourseCollection::CollectionInvite.includes(:collection, :inviter).find_by(
            id: args[:invite_id],
          )
        return if invite.nil?
        return if invite.inviter_user_id.blank? || invite.inviter.nil?
        return if invite.invitee_user_id.blank?
        return unless invite.pending?
        return if invite.collection.nil?

        ::Notification.create!(
          notification_type: ::Notification.types[:collection_invitation],
          user_id: invite.invitee_user_id,
          data: {
            display_username: invite.inviter.username,
            action_type: invite.action_type,
            collection_id: invite.collection.id,
            collection_name: invite.collection.name,
          }.to_json,
        )
      end
    end
  end
end
