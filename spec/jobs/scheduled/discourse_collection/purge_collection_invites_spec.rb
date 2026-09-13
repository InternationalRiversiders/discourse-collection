# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::PurgeCollectionInvites do
  fab!(:collection) { Fabricate(:collection) }
  fab!(:inviter, :user)
  fab!(:invitee, :user)

  # created_at is stamped by ActiveRecord at insert; rewind it afterwards to place
  # the row relative to the history window (validity default 10 / history 30 days).
  def fabricate_invite!(age:, accept: nil)
    Fabricate(
      :collection_invite,
      collection:,
      inviter:,
      invitee:,
      action_type: DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER,
      accept:,
    ).tap { |invite| invite.update_column(:created_at, age.ago) }
  end

  subject(:run_job) { described_class.new.execute({}) }

  it "purges rows older than the history window across every status" do
    stale_pending = fabricate_invite!(age: 60.days, accept: nil) # long-expired, still unanswered
    stale_accepted = fabricate_invite!(age: 45.days, accept: true)
    stale_rejected = fabricate_invite!(age: 45.days, accept: false)

    expect { run_job }.to change {
      DiscourseCollection::CollectionInvite.count
    }.by(-3)

    expect(DiscourseCollection::CollectionInvite.exists?(stale_pending.id)).to eq(false)
    expect(DiscourseCollection::CollectionInvite.exists?(stale_accepted.id)).to eq(false)
    expect(DiscourseCollection::CollectionInvite.exists?(stale_rejected.id)).to eq(false)
  end

  it "keeps rows still inside the history window" do
    fabricate_invite!(age: 3.days) # pending, well within both windows
    fabricate_invite!(age: 20.days) # expired (past validity) yet < history: kept
    fabricate_invite!(age: 20.days, accept: true) # answered, kept until history lapses

    expect { run_job }.not_to change { DiscourseCollection::CollectionInvite.count }
  end

  context "when collection_invite_history_days is 0 (keep forever)" do
    before { SiteSetting.collection_invite_history_days = 0 }

    it "keeps rows regardless of how old they are" do
      ancient_pending = fabricate_invite!(age: 120.days)
      ancient_answered = fabricate_invite!(age: 120.days, accept: true)

      expect { run_job }.not_to change { DiscourseCollection::CollectionInvite.count }
      expect(DiscourseCollection::CollectionInvite.exists?(ancient_pending.id)).to eq(true)
      expect(DiscourseCollection::CollectionInvite.exists?(ancient_answered.id)).to eq(true)
    end
  end

  context "when the plugin is disabled" do
    before { SiteSetting.collection_enabled = false }

    it "leaves even stale rows untouched" do
      stale_pending = fabricate_invite!(age: 60.days)

      expect { run_job }.not_to change { DiscourseCollection::CollectionInvite.count }
      expect(DiscourseCollection::CollectionInvite.exists?(stale_pending.id)).to eq(true)
    end
  end
end
