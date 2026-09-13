# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::RejectInvite do
  fab!(:owner, :user)
  fab!(:candidate, :user)
  fab!(:outsider, :user)

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  let(:collection) { add_owned_collection(owner) }
  let(:invite) do
    Fabricate(:collection_invite, collection:, inviter: owner, invitee: candidate)
  end
  let(:guardian) { Guardian.new(actor) }
  let(:dependencies) { { guardian: } }
  let(:actor) { candidate }
  let(:params) { { invite_id: invite.id } }

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { invite_id: 1 } }

    context "with an invite_id" do
      it { is_expected.to be_valid }
    end

    context "without an invite_id" do
      let(:params) { {} }

      it { is_expected.not_to be_valid }
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    context "when the invite does not exist or belongs to someone else" do
      let(:actor) { outsider }

      it { is_expected.to fail_to_find_a_model(:invite) }
    end

    context "when the invite is no longer pending" do
      before { invite.update!(accept: true) }

      it { is_expected.to fail_a_step(:ensure_pending) }
    end

    context "when the candidate rejects their pending invite" do
      it { is_expected.to run_successfully }

      it "records accept=false and writes no membership row" do
        expect { result }.not_to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count
        }

        expect(invite.reload.accept).to eq(false)
      end

      it "enqueues the 21078 declined job for the inviter" do
        expect { result }.to change(
          Jobs::DiscourseCollection::NotifyInvitationResult.jobs,
          :size,
        ).by(1)
      end
    end
  end
end
