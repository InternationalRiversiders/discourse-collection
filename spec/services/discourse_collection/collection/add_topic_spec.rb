# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::AddTopic do
  fab!(:owner, :user)
  fab!(:worker, :user)
  fab!(:stranger, :user)
  fab!(:topic) { Fabricate(:topic) }

  def add_owned_collection(owner)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    end
  end

  def membership
    DiscourseCollection::CollectionTopic.find_by(
      collection_id: collection.id,
      topic_id: topic.id,
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

    context "with a note over the 100-character cap" do
      let(:params) { { id: 1, topic_id: 2, note: "a" * 101 } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:base]).to include(
          I18n.t("discourse_collection.errors.note_too_long", max: 100),
        )
      end
    end

    context "with a note of exactly 100 characters" do
      let(:params) { { id: 1, topic_id: 2, note: "a" * 100 } }

      it { is_expected.to be_valid }
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) { add_owned_collection(owner) }
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

    context "when the topic does not exist" do
      let(:params) { { id: collection.id, topic_id: -999 } }

      it { is_expected.to fail_to_find_a_model(:topic) }
    end

    context "when the topic is not visible to the actor (soft-deleted)" do
      before { topic.trash! }

      it "treats it as a 404 (model not found), no existence leak" do
        expect(result).to fail_to_find_a_model(:topic)
      end
    end

    context "when the topic is a private message the actor can see" do
      # The owner is the PM's recipient, so guardian.can_see_topic? lets it through to
      # the business-rule step: PMs are never collectable, even when visible
      # (docs/04 §3) — a 422, not the invisible-topic 404.
      let(:pm) { Fabricate(:private_message_topic, recipient: owner) }
      let(:params) { { id: collection.id, topic_id: pm.id } }

      it { is_expected.to fail_a_step(:ensure_topic_is_not_a_private_message) }

      it "writes no membership row" do
        result

        expect(DiscourseCollection::CollectionTopic.where(collection_id: collection.id).count).to eq(0)
      end
    end

    context "when the topic is a private message the actor cannot see" do
      let(:pm) { Fabricate(:private_message_topic, recipient: owner) }
      let(:params) { { id: collection.id, topic_id: pm.id } }
      let(:actor) { stranger }

      it "treats it as a 404 (model not found), no existence leak" do
        expect(result).to fail_to_find_a_model(:topic)
      end
    end

    context "when the actor is not the owner nor a co-maintainer" do
      let(:actor) { stranger }

      it { is_expected.to fail_a_policy(:can_write_topics) }
    end

    context "when a co-maintainer collects a topic" do
      let(:actor) { worker }

      before { Fabricate(:collection_teamworker, collection:, user: worker, is_owner: false) }

      it { is_expected.to run_successfully }
    end

    context "when the owner collects a fresh topic" do
      it { is_expected.to run_successfully }

      it "inserts the membership row and bumps the collection counters" do
        collection # materialize before the change matchers snapshot

        expect { result }.to change {
          DiscourseCollection::CollectionTopic.where(collection_id: collection.id).count
        }.by(1)

        expect(membership).to be_present
        expect(collection.reload.topic_count).to eq(1)
        expect(collection.reload.last_topic_added_at).to be_within(1.second).of(Time.zone.now)
        expect(collection.reload.updated_at).to be_within(1.second).of(Time.zone.now)
      end

      it "keeps has_selected_reply false on the fresh row" do
        result

        expect(membership.has_selected_reply).to eq(false)
      end

      it "stores the note" do
        params[:note] = "Worth re-reading"

        result

        expect(membership.note).to eq("Worth re-reading")
      end

      it "stores a blank note as NULL" do
        params[:note] = "   "

        result

        expect(membership.note).to be_nil
      end

      # The collect no longer notifies directly — it stamps the pending batch with
      # the row it inserted and schedules the flush (docs/09 §2).
      it "stamps the pending 21075 batch and schedules its flush" do
        expect { result }.to change(
          Jobs::DiscourseCollection::NotifyTopicAdded.jobs,
          :size,
        ).by(1)

        args = Jobs::DiscourseCollection::NotifyTopicAdded.jobs.last["args"].first

        expect(args["actor_user_id"]).to eq(actor.id)
        expect(args["topic_author_id"]).to eq(topic.user_id)
        expect(
          DiscourseCollection::TopicAddedNotificationBatch.current?(collection.id, args["stamp"]),
        ).to eq(true)
      end
    end

    context "when the topic is already collected" do
      before { Fabricate(:collection_topic, collection:, topic:) }

      it { is_expected.to run_successfully }

      it "is an idempotent no-op (no recount, no timestamp bump)" do
        collection.update!(topic_count: 1, last_topic_added_at: 1.day.ago, updated_at: 1.day.ago)

        expect { result }.not_to change {
          DiscourseCollection::CollectionTopic.where(collection_id: collection.id).count
        }

        expect(collection.reload.topic_count).to eq(1)
        expect(collection.reload.last_topic_added_at).to be_within(1.second).of(1.day.ago)
      end

      it "leaves the pending 21075 batch alone on an idempotent re-collect" do
        stamp =
          DiscourseCollection::TopicAddedNotificationBatch.register!(
            collection:,
            actor_user_id: actor.id,
            topic:,
          )

        expect { result }.not_to change(Jobs::DiscourseCollection::NotifyTopicAdded.jobs, :size)

        # The batch is neither restamped nor superseded: its original run stays the one
        # that will fire.
        expect(
          DiscourseCollection::TopicAddedNotificationBatch.current?(collection.id, stamp),
        ).to eq(true)
      end
    end

    context "when the collection is at the topic cap" do
      before do
        SiteSetting.collection_max_topics_per_collection = 1
        Fabricate(:collection_topic, collection:, topic: Fabricate(:topic))
      end

      it { is_expected.to fail_a_step(:add_topic) }
    end
  end
end
