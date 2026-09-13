# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::Create do
  fab!(:owner, :user)
  fab!(:create_group) { Fabricate(:group) }

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  # The create-allowed groups setting (default @trust_level_1) would block ordinary
  # :user fabricators (trust_level 0); grant the owner membership so the cap and write
  # paths below are actually exercised.
  before do
    SiteSetting.collection_create_allowed_groups = create_group.id.to_s
    create_group.add(owner)
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { name: "Valid collection" } }

    context "with a valid in-range name" do
      it { is_expected.to be_valid }
    end

    context "when name is blank" do
      let(:params) { { name: "   " } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:base]).to include(
          I18n.t("discourse_collection.errors.name_blank"),
        )
      end
    end

    context "when name is shorter than the minimum" do
      let(:params) { { name: "ab" } }

      it "is invalid" do
        expect(contract).not_to be_valid
      end
    end

    context "when name is longer than the maximum" do
      let(:params) { { name: "a" * (SiteSetting.collection_name_max_length + 1) } }

      it "is invalid" do
        expect(contract).not_to be_valid
      end
    end

    context "when description exceeds its maximum" do
      let(:params) do
        { name: "Valid collection", description: "a" * (SiteSetting.collection_description_max_length + 1) }
      end

      it "is invalid" do
        expect(contract).not_to be_valid
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:guardian) { Guardian.new(owner) }
    let(:dependencies) { { guardian: } }

    context "when the contract fails" do
      let(:params) { { name: "ab" } }

      it { is_expected.to fail_a_contract }
    end

    context "when the acting user is at the collection cap" do
      let(:params) { { name: "New collection" } }

      before do
        SiteSetting.collection_max_collections_per_user = 1
        add_owned_collection(owner)
      end

      it { is_expected.to fail_a_step(:ensure_under_collection_limit) }

      it "does not create a collection" do
        expect { result }.not_to change { DiscourseCollection::Collection.count }
      end
    end

    context "when the acting user is not in the create-allowed groups" do
      fab!(:restricted_group) { Fabricate(:group) }
      let(:params) { { name: "New collection" } }

      before { SiteSetting.collection_create_allowed_groups = restricted_group.id.to_s }

      it { is_expected.to fail_a_policy(:can_create_collection) }

      it "does not create a collection" do
        expect { result }.not_to change { DiscourseCollection::Collection.count }
      end
    end

    context "when the acting user is in the create-disallowed groups" do
      fab!(:denied_group) { Fabricate(:group) }
      let(:params) { { name: "New collection" } }

      before do
        denied_group.add(owner)
        SiteSetting.collection_create_disallowed_groups = denied_group.id.to_s
      end

      it { is_expected.to fail_a_policy(:can_create_collection) }

      it "does not create a collection" do
        expect { result }.not_to change { DiscourseCollection::Collection.count }
      end
    end

    context "when the create-allowed group list is empty (disabled for everyone)" do
      let(:params) { { name: "New collection" } }

      before { SiteSetting.collection_create_allowed_groups = "" }

      it { is_expected.to fail_a_policy(:can_create_collection) }
    end

    context "when the acting user is exempt from the cap" do
      fab!(:owner, :admin)
      let(:params) { { name: "New collection" } }

      before do
        SiteSetting.collection_max_collections_per_user = 1
        SiteSetting.collection_unlimited_collections_role = "admin"
        add_owned_collection(owner)
      end

      it { is_expected.to run_successfully }
    end

    context "when the user is under the cap" do
      let(:params) { { name: "  Trimmed name  " } }

      it { is_expected.to run_successfully }

      it "creates a collection with a trimmed name and empty description" do
        expect { result }.to change { DiscourseCollection::Collection.count }.by(1)

        collection = result.collection
        expect(collection.name).to eq("Trimmed name")
        expect(collection.description).to eq("")
        expect(collection.topic_count).to eq(0)
        expect(collection.last_topic_added_at).to be_nil
      end

      it "records the owner membership row in the same write" do
        expect { result }.to change {
          DiscourseCollection::CollectionTeamworker.where(is_owner: true).count
        }.by(1)

        membership = result.collection.owner_teamworker
        expect(membership.user_id).to eq(owner.id)
      end

      it "auto-subscribes the owner, who never counts towards subscribers_count" do
        expect { result }.to change {
          DiscourseCollection::CollectionSubscriber.where(user_id: owner.id).count
        }.by(1)

        expect(result.collection.subscribers_count).to eq(0)
        expect(
          DiscourseCollection::CollectionSubscriber.find_by(
            collection_id: result.collection.id,
            user_id: owner.id,
          ),
        ).to be_present
      end
    end
  end
end
