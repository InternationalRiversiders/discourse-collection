# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # 21077/21078 — tell the inviter how their invitation was answered (docs/09 §1):
    # 21077 collection_invitation_accepted on accept, 21078
    # collection_invitation_declined on reject. Queued by AcceptInvite / RejectInvite;
    # one job serves both types because the recipient (the inviter), the payload shape
    # and the target (the collection) are identical — only the terminal accept value picks
    # the type. On a type=1 accept the inviter is demoted by then yet still notified
    # (docs/09 §1). Runs async and re-checks the row: an invite that vanished (collection
    # deletion cascades the row away) or is still pending (not yet decided) gets
    # nothing, and a deleted inviter account is not notified.
    class NotifyInvitationResult < ::Jobs::Base
      def execute(args = {})
        invite =
          ::DiscourseCollection::CollectionInvite.includes(:collection, :invitee).find_by(
            id: args[:invite_id],
          )
        return if invite.nil?
        return if invite.inviter_user_id.blank?
        return if invite.accept.nil?
        return if invite.collection.nil?
        return if invite.invitee_user_id.blank? || invite.invitee.nil?

        type =
          if invite.accept
            :collection_invitation_accepted
          else
            :collection_invitation_declined
          end

        ::Notification.create!(
          notification_type: ::Notification.types[type],
          user_id: invite.inviter_user_id,
          data: {
            display_username: invite.invitee.username,
            action_type: invite.action_type,
            collection_id: invite.collection.id,
            collection_name: invite.collection.name,
          }.to_json,
        )
      end
    end
  end
end
