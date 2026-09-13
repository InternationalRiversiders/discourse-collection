# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::NotifyInvitationResult do
  fab!(:collection) { Fabricate(:collection) }
  fab!(:inviter, :user)
  fab!(:invitee, :user)

  TYPE_MAINTAINER = DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER

  fab!(:invite) do
    Fabricate(:collection_invite, collection:, inviter:, invitee:, action_type: TYPE_MAINTAINER)
  end
  subject(:run_job) { described_class.new.execute(invite_id: invite.id) }

  context "when the invite was accepted" do
    before { invite.update!(accept: true) }

    it "notifies the inviter with the accepted type" do
      expect { run_job }.to change { Notification.count }.by(1)

      notification = Notification.where(
        user_id: inviter.id,
        notification_type: Notification.types[:collection_invitation_accepted],
      ).last
      expect(notification).to be_present
      expect(JSON.parse(notification.data)).to eq(
        "display_username" => invitee.username,
        "action_type" => TYPE_MAINTAINER,
        "collection_id" => collection.id,
        "collection_name" => collection.name,
      )
    end
  end

  context "when the invite was rejected" do
    before { invite.update!(accept: false) }

    it "notifies the inviter with the declined type" do
      expect { run_job }.to change { Notification.count }.by(1)

      notification = Notification.where(
        user_id: inviter.id,
        notification_type: Notification.types[:collection_invitation_declined],
      ).last
      expect(notification).to be_present
    end
  end

  context "when the invite is still pending" do
    it "creates nothing (nothing decided yet)" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the inviter's account was deleted (FK SET NULL)" do
    before { invite.update!(accept: true, inviter_user_id: nil) }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end
end
