# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::Delete do
  fab!(:owner, :user)
  fab!(:outsider, :user)
  fab!(:admin, :admin)

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1 } }

    context "with an id" do
      it { is_expected.to be_valid }
    end

    context "without an id" do
      let(:params) { {} }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:id]).to be_present
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) { add_owned_collection(owner) }
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id } }

    context "when the collection does not exist" do
      let(:params) { { id: -999 } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the acting user is an outsider" do
      let(:actor) { outsider }

      it { is_expected.to fail_a_policy(:can_delete_collection) }
    end

    context "when the acting user is staff but not the owner" do
      let(:actor) { admin }

      it "does not let staff delete someone else's collection" do
        is_expected.to fail_a_policy(:can_delete_collection)
      end
    end

    context "when the acting user is the owner" do
      it { is_expected.to run_successfully }

      it "deletes the collection" do
        collection # materialize the lazy let before the change matcher snapshots the count

        expect { result }.to change { DiscourseCollection::Collection.count }.by(-1)
      end

      it "cascades to the membership and subscriber rows" do
        Fabricate(:collection_teamworker, collection:, user: outsider, is_owner: false)
        Fabricate(:collection_subscriber, collection:, user: outsider)

        expect { result }.to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count
        }.to(0).and change {
          DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).count
        }.to(0)
      end
    end
  end
end
