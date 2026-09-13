# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::Subscribe do
  fab!(:owner, :user)
  fab!(:subscriber, :user)

  def add_owned_collection(owner)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    end
  end

  def subscription(user)
    DiscourseCollection::CollectionSubscriber.find_by(
      collection_id: collection.id,
      user_id: user.id,
    )
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
    let(:actor) { subscriber }
    let(:params) { { id: collection.id } }

    context "when the contract fails" do
      let(:params) { {} }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999 } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when a new subscriber subscribes" do
      it { is_expected.to run_successfully }

      it "creates a subscription row and bumps the stored count" do
        collection # materialize before the change matcher snapshots the count

        expect { result }.to change {
          DiscourseCollection::CollectionSubscriber.where(
            collection_id: collection.id,
            user_id: subscriber.id,
          ).count
        }.by(1)

        expect(collection.reload.subscribers_count).to eq(1)
      end

      it "does not bump the collection updated_at (subscription is not activity)" do
        collection.update!(updated_at: 1.day.ago)

        result

        expect(collection.reload.updated_at).to be_within(1.second).of(1.day.ago)
      end
    end

    context "when the user is already subscribed" do
      before { Fabricate(:collection_subscriber, collection:, user: subscriber) }

      it { is_expected.to run_successfully }

      it "leaves the single row and count untouched" do
        collection.update!(subscribers_count: 1)

        expect { result }.not_to change {
          DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).count
        }

        expect(collection.reload.subscribers_count).to eq(1)
      end
    end

    context "when the acting user is the collection owner (re-subscribing)" do
      let(:actor) { owner }

      it { is_expected.to run_successfully }

      it "creates the owner's row but never counts it" do
        expect { result }.to change {
          DiscourseCollection::CollectionSubscriber.where(
            collection_id: collection.id,
            user_id: owner.id,
          ).count
        }.by(1)

        expect(collection.reload.subscribers_count).to eq(0)
      end
    end
  end
end
