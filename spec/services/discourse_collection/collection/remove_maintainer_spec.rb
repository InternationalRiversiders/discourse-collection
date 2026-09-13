# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::RemoveMaintainer do
  fab!(:owner, :user)
  fab!(:candidate, :user)
  fab!(:outsider, :user)
  fab!(:admin, :admin)

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  def membership(user)
    DiscourseCollection::CollectionTeamworker.find_by(
      collection_id: collection.id,
      user_id: user.id,
    )
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1, user_id: 1 } }

    context "with an id and user_id" do
      it { is_expected.to be_valid }
    end

    context "without a user_id" do
      let(:params) { { id: 1 } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:user_id]).to be_present
      end
    end

    context "without an id" do
      let(:params) { { user_id: 1 } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:id]).to be_present
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) do
      add_owned_collection(owner).tap do |collection|
        Fabricate(:collection_teamworker, collection: collection, user: candidate, is_owner: false)
      end
    end
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id, user_id: candidate.id } }

    context "when the contract fails" do
      let(:params) { { id: collection.id } }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999, user_id: candidate.id } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the target user does not exist" do
      let(:params) { { id: collection.id, user_id: -999 } }

      it { is_expected.to fail_to_find_a_model(:target_user) }
    end

    context "when the acting user is not the owner" do
      let(:actor) { outsider }

      it { is_expected.to fail_a_policy(:can_manage_maintainers) }

      it "does not remove the membership row" do
        expect { result }.not_to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count
        }
      end
    end

    context "when the acting user is staff but not the owner" do
      let(:actor) { admin }

      it "does not let staff remove a co-maintainer from someone else's collection" do
        is_expected.to fail_a_policy(:can_manage_maintainers)
      end
    end

    context "when the target is the collection owner" do
      let(:params) { { id: collection.id, user_id: owner.id } }

      it { is_expected.to fail_a_step(:ensure_user_is_not_the_owner) }
    end

    context "when the target is not a co-maintainer" do
      let(:collection) { add_owned_collection(owner) }

      it { is_expected.to fail_a_step(:ensure_user_is_a_maintainer) }
    end

    context "when the owner removes a co-maintainer" do
      it { is_expected.to run_successfully }

      it "deletes the membership row" do
        expect { result }.to change { membership(candidate) }.to(nil)
      end

      it "bumps the collection updated_at" do
        collection.update!(updated_at: 1.day.ago)

        result

        expect(collection.reload.updated_at).to be > 1.day.ago
      end
    end

    context "when the co-maintainer removes themself (self-leave)" do
      let(:actor) { candidate }
      let(:params) { { id: collection.id, user_id: candidate.id } }

      it { is_expected.to run_successfully }

      it "deletes their own membership row" do
        expect { result }.to change { membership(candidate) }.to(nil)
      end

      it "leaves the owner row untouched" do
        result

        expect(membership(owner)).to be_present
        expect(membership(owner).is_owner).to eq(true)
      end

      it "bumps the collection updated_at" do
        collection.update!(updated_at: 1.day.ago)

        result

        expect(collection.reload.updated_at).to be > 1.day.ago
      end
    end

    context "when a co-maintainer tries to remove a teammate" do
      let(:collection) do
        add_owned_collection(owner).tap do |collection|
          Fabricate(:collection_teamworker, collection: collection, user: candidate, is_owner: false)
          Fabricate(:collection_teamworker, collection: collection, user: outsider, is_owner: false)
        end
      end
      let(:actor) { candidate }
      let(:params) { { id: collection.id, user_id: outsider.id } }

      it { is_expected.to fail_a_policy(:can_manage_maintainers) }

      it "does not remove the teammate's membership row" do
        expect { result }.not_to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count
        }
      end
    end
  end
end
