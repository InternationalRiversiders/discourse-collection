# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::RewriteTopicNote do
  fab!(:admin, :admin)
  fab!(:moderator, :moderator)
  fab!(:owner, :user)
  fab!(:stranger, :user)

  def add_owned_collection(owner)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    end
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1, topic_id: 2, note: "fixed" } }

    context "with an id, topic_id and note" do
      it { is_expected.to be_valid }
    end

    context "without an id" do
      let(:params) { { topic_id: 2, note: "fixed" } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:id]).to be_present
      end
    end

    context "without a topic_id" do
      let(:params) { { id: 1, note: "fixed" } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:topic_id]).to be_present
      end
    end

    context "with an explicit null note" do
      let(:params) { { id: 1, topic_id: 2, note: nil } }

      it { is_expected.to be_valid }
    end

    context "with a note over the 100-character cap" do
      let(:params) { { id: 1, topic_id: 2, note: "a" * 101 } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:base]).to include(
          I18n.t("discourse_collection.errors.note_too_long", max: 100),
        )
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:topic) { Fabricate(:topic) }
    let(:collection) { add_owned_collection(owner) }
    let(:membership) { Fabricate(:collection_topic, collection:, topic:, note: "old") }
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { admin }
    let(:params) { { id: collection.id, topic_id: topic.id, note: "fixed" } }

    before { membership }

    context "when the contract fails" do
      let(:params) { { id: collection.id } }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999, topic_id: topic.id, note: "fixed" } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the topic is not collected in the collection" do
      let(:params) { { id: collection.id, topic_id: Fabricate(:topic).id, note: "fixed" } }

      it { is_expected.to fail_to_find_a_model(:membership) }
    end

    context "when the actor is not staff" do
      let(:actor) { stranger }

      it { is_expected.to fail_a_policy(:staff) }
    end

    context "when an admin overwrites a note on someone else's collection" do
      it { is_expected.to run_successfully }

      it "replaces the note and bumps updated_at only" do
        collection.update!(
          last_topic_added_at: 1.day.ago,
          topic_count: 3,
          updated_at: 2.days.ago,
        )

        result

        expect(membership.reload.note).to eq("fixed")
        expect(collection.reload.updated_at).to be_within(1.second).of(Time.zone.now)
        expect(collection.reload.last_topic_added_at).to be_within(1.second).of(1.day.ago)
        expect(collection.reload.topic_count).to eq(3)
        expect(membership.reload.has_selected_reply).to eq(false)
      end

      it "logs a collection_topic_note_change audit row" do
        result

        history = UserHistory.find_by(custom_type: "collection_topic_note_change")
        expect(history).to be_present
        expect(history.action).to eq(UserHistory.actions[:custom_staff])
        expect(history.acting_user_id).to eq(admin.id)
        expect(history.subject).to eq("Collection (#{collection.id})")
        expect(history.context).to eq("Sample collection")
        expect(history.previous_value).to eq("old")
        expect(history.new_value).to eq("fixed")
      end
    end

    context "when a moderator overwrites a note (setting off still allowed)" do
      let(:actor) { moderator }

      before { SiteSetting.collection_moderators_can_manage_collections = false }

      it { is_expected.to run_successfully }

      it "logs an audit row (moderator is staff on this endpoint)" do
        expect { result }.to change {
          UserHistory.where(custom_type: "collection_topic_note_change").count
        }.by(1)
      end
    end

    context "when an admin clears the note with null" do
      let(:params) { { id: collection.id, topic_id: topic.id, note: nil } }

      it "clears it" do
        result

        expect(membership.reload.note).to be_nil
      end

      it "logs the clear as old note -> nil (docs/10 §1)" do
        result

        history = UserHistory.find_by(custom_type: "collection_topic_note_change")
        expect(history).to be_present
        expect(history.previous_value).to eq("old")
        expect(history.new_value).to be_nil
      end
    end

    context "with no note key" do
      let(:params) { { id: collection.id, topic_id: topic.id } }

      before { collection.update!(updated_at: 1.day.ago) }

      it "is an idempotent no-op and does not bump updated_at" do
        result

        expect(membership.reload.note).to eq("old")
        expect(collection.reload.updated_at).to be_within(1.second).of(1.day.ago)
      end

      it "logs nothing for the no-op request" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_topic_note_change").count
        }
      end
    end
  end
end
