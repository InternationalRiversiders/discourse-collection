# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::NotifyInvitation do
  fab!(:collection) { Fabricate(:collection) }
  fab!(:inviter, :user)
  fab!(:invitee, :user)

  TYPE_MAINTAINER = DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER
  TYPE_OWNER = DiscourseCollection::CollectionInvite::ACTION_TYPE_OWNER

  fab!(:invite) do
    Fabricate(:collection_invite, collection:, inviter:, invitee:, action_type: TYPE_MAINTAINER)
  end
  # No `let(:action_type)`: fab! rows are pre-built in a before(:context) (TestProf
  # let_it_be), where lazy lets are off-limits — inline the constant instead.
  subject(:run_job) { described_class.new.execute(invite_id: invite.id) }

  def invitation_for(user)
    Notification.where(
      user_id: user.id,
      notification_type: Notification.types[:collection_invitation],
    )
  end

  it "notifies the invitee that they were invited" do
    expect { run_job }.to change { Notification.count }.by(1)

    notification = invitation_for(invitee).last
    expect(notification).to be_present
    expect(JSON.parse(notification.data)).to eq(
      "display_username" => inviter.username,
      "action_type" => TYPE_MAINTAINER,
      "collection_id" => collection.id,
      "collection_name" => collection.name,
    )
  end

  it "keeps action_type=1 distinct in the payload" do
    invite.update!(action_type: TYPE_OWNER)

    run_job

    expect(JSON.parse(invitation_for(invitee).last.data)["action_type"]).to eq(TYPE_OWNER)
  end

  context "when the invite was revoked (row deleted) before the job ran" do
    before { invite.destroy! }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the invite was already answered before the job ran" do
    before { invite.update!(accept: true) }

    it "creates nothing (the result is notified separately)" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the invite has expired" do
    before { invite.update_column(:created_at, 20.days.ago) }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the inviter's account was deleted (FK SET NULL)" do
    before { invite.update!(inviter_user_id: nil) }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end
end
