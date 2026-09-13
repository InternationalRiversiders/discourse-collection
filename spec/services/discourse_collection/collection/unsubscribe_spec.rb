# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::Unsubscribe do
  fab!(:owner, :user)
  fab!(:subscriber, :user)

  def build_collection_with_owner(owner_user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner_user, is_owner: true)
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

    let(:collection) do
      build_collection_with_owner(owner).tap { |collection| collection.update!(subscribers_count: 1) }
    end
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { subscriber }
    let(:params) { { id: collection.id } }

    before { Fabricate(:collection_subscriber, collection:, user: subscriber) }

    context "when the contract fails" do
      let(:params) { {} }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999 } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when a counted subscriber unsubscribes" do
      it { is_expected.to run_successfully }

      it "deletes their row and decrements the stored count" do
        expect { result }.to change {
          DiscourseCollection::CollectionSubscriber.where(
            collection_id: collection.id,
            user_id: subscriber.id,
          ).count
        }.by(-1)

        expect(collection.reload.subscribers_count).to eq(0)
      end

      it "does not bump the collection updated_at" do
        collection.update!(updated_at: 1.day.ago)

        result

        expect(collection.reload.updated_at).to be_within(1.second).of(1.day.ago)
      end
    end

    context "when the user is not subscribed" do
      before { DiscourseCollection::CollectionSubscriber.delete_all }

      it { is_expected.to run_successfully }

      it "leaves the count untouched" do
        expect { result }.not_to change {
          DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).count
        }
        expect(collection.reload.subscribers_count).to eq(1)
      end
    end

    context "when the acting user is the owner (owner's own row never counts)" do
      let(:actor) { owner }

      before do
        # Owner auto-subscribed on creation: an owner subscription row exists but was
        # never counted (subscribers_count stays 0).
        DiscourseCollection::CollectionSubscriber.delete_all
        collection.update!(subscribers_count: 0)
        Fabricate(:collection_subscriber, collection:, user: owner)
      end

      it { is_expected.to run_successfully }

      it "deletes the owner row without decrementing" do
        expect { result }.to change {
          DiscourseCollection::CollectionSubscriber.where(
            collection_id: collection.id,
            user_id: owner.id,
          ).count
        }.by(-1)

        expect(collection.reload.subscribers_count).to eq(0)
      end
    end
  end
end
