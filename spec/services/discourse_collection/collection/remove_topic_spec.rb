# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::RemoveTopic do
  fab!(:owner, :user)
  fab!(:worker, :user)
  fab!(:stranger, :user)
  fab!(:topic) { Fabricate(:topic) }

  def add_owned_collection(owner)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    end
  end

  def register_batch(topic: self.topic)
    DiscourseCollection::TopicAddedNotificationBatch.register!(
      collection:,
      actor_user_id: owner.id,
      topic:,
    )
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1, topic_id: 2 } }

    context "with id and topic_id" do
      it { is_expected.to be_valid }
    end

    context "without an id" do
      let(:params) { { topic_id: 2 } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:id]).to be_present
      end
    end

    context "without a topic_id" do
      let(:params) { { id: 1 } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:topic_id]).to be_present
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) do
      add_owned_collection(owner).tap do |collection|
        Fabricate(:collection_topic, collection:, topic:)
        collection.update!(topic_count: 1, last_topic_added_at: Time.zone.now)
      end
    end
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id, topic_id: topic.id } }

    context "when the contract fails" do
      let(:params) { { id: collection.id } }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999, topic_id: topic.id } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the actor is not the owner nor a co-maintainer" do
      let(:actor) { stranger }

      it { is_expected.to fail_a_policy(:can_write_topics) }
    end

    context "when the topic is not in the collection" do
      let(:params) { { id: collection.id, topic_id: Fabricate(:topic).id } }

      it { is_expected.to fail_a_step(:ensure_topic_is_included) }

      it "keeps the pending 21075 run — the failed remove changed nothing" do
        stamp = register_batch

        result

        expect(
          DiscourseCollection::TopicAddedNotificationBatch.current?(collection.id, stamp),
        ).to eq(true)
      end
    end

    context "when a co-maintainer removes a topic" do
      let(:actor) { worker }

      before { Fabricate(:collection_teamworker, collection:, user: worker, is_owner: false) }

      it { is_expected.to run_successfully }
    end

    context "when the owner removes the collected topic" do
      it { is_expected.to run_successfully }

      it "deletes the membership row and its selected-reply rows" do
        post = Fabricate(:post, topic:)
        Fabricate(:collection_topic_selected_reply, collection:, topic:, post:)

        expect { result }.to change {
          DiscourseCollection::CollectionTopic.where(collection_id: collection.id).count
        }.by(-1)

        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
          ).count,
        ).to eq(0)
      end

      it "decrements topic_count and touches updated_at" do
        collection.update!(updated_at: 1.day.ago)

        result

        expect(collection.reload.topic_count).to eq(0)
        expect(collection.reload.updated_at).to be_within(1.second).of(Time.zone.now)
      end

      # A remove touches no notification state. It tells a pending run to stand down
      # only by changing which membership row is the newest — so un-collecting the topic
      # that opened the run silences it, while un-collecting anything older does not
      # (docs/09 §2).
      it "stands down the pending 21075 run opened by the removed topic" do
        stamp = register_batch

        result

        expect(
          DiscourseCollection::TopicAddedNotificationBatch.current?(collection.id, stamp),
        ).to eq(false)
      end

      it "keeps the run alive when a different, older topic is the one removed" do
        older_topic = Fabricate(:topic)
        Fabricate(:collection_topic, collection:, topic: older_topic, created_at: 2.days.ago)
        stamp = register_batch

        described_class.call(params: { id: collection.id, topic_id: older_topic.id }, guardian:)

        expect(
          DiscourseCollection::TopicAddedNotificationBatch.current?(collection.id, stamp),
        ).to eq(true)
      end

      it "recomputes last_topic_added_at to the newest remaining collect, NULL when empty" do
        older_topic = Fabricate(:topic)
        older_row =
          Fabricate(:collection_topic, collection:, topic: older_topic, created_at: 2.days.ago)
        collection.update!(
          topic_count: 2,
          last_topic_added_at: Time.zone.now,
          updated_at: 1.day.ago,
        )

        result

        expect(collection.reload.topic_count).to eq(1)
        expect(collection.reload.last_topic_added_at.to_i).to eq(older_row.created_at.to_i)
        expect(collection.reload.updated_at).to be_within(1.second).of(Time.zone.now)
      end
    end
  end
end
