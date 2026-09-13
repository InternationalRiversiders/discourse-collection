# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::UpdateCollectedTopic do
  fab!(:owner, :user)
  fab!(:worker, :user)
  fab!(:stranger, :user)

  def add_owned_collection(owner)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    end
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1, topic_id: 2 } }

    context "with an id and topic_id" do
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

    context "with an explicit null note" do
      let(:params) { { id: 1, topic_id: 2, note: nil } }

      it { is_expected.to be_valid }
    end

    context "with the same reply both added and removed" do
      let(:params) { { id: 1, topic_id: 2, selected_replies: { add: [3], remove: [3] } } }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:base]).to include(
          I18n.t("discourse_collection.errors.selected_replies_add_remove_overlap"),
        )
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:topic) { Fabricate(:topic) }
    # A regular reply, never the OP: on an empty topic a bare Fabricate(:post) would
    # auto-number to post_number 1 (PostCreator.before_create_tasks). The first post
    # and any non-regular post are rejected as unfeatureable (see the contexts below).
    let(:post) { Fabricate(:post, topic:, post_number: 2) }
    let(:collection) { add_owned_collection(owner) }
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id, topic_id: topic.id } }

    before { Fabricate(:collection_topic, collection:, topic:) }

    context "when the contract fails" do
      let(:params) { { id: collection.id } }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999, topic_id: topic.id } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the topic is not collected in the collection" do
      let(:params) { { id: collection.id, topic_id: Fabricate(:topic).id } }

      it { is_expected.to fail_to_find_a_model(:membership) }
    end

    context "when the actor is not the owner nor a co-maintainer" do
      let(:actor) { stranger }

      it { is_expected.to fail_a_policy(:can_write_topics) }
    end

    context "when a co-maintainer edits a topic" do
      let(:actor) { worker }

      before { Fabricate(:collection_teamworker, collection:, user: worker, is_owner: false) }

      it { is_expected.to run_successfully }
    end

    context "when an added reply belongs to another topic" do
      let(:alien_post) { Fabricate(:post, topic: Fabricate(:topic)) }

      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [alien_post.id] } }
      end

      it "treats it as a 404 (no existence leak)" do
        expect(result).to fail_a_step(:ensure_added_replies_belong_to_topic)
      end
    end

    context "when an added post is the topic's first post (the OP)" do
      let(:op_post) { Fabricate(:post, topic:, post_number: 1) }

      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [op_post.id] } }
      end

      it "rejects it as unfeatureable (422)" do
        expect(result).to fail_a_step(:ensure_added_replies_are_featureable)
      end
    end

    context "when an added post is a system/action entry (small_action)" do
      let(:event_post) do
        Fabricate(:small_action, topic:, post_number: 2, action_code: "visible.disabled")
      end

      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [event_post.id] } }
      end

      it "rejects it as unfeatureable (422)" do
        expect(result).to fail_a_step(:ensure_added_replies_are_featureable)
      end
    end

    context "when an added post is a whisper (non-regular, staff-only)" do
      let(:whisper_post) { Fabricate(:whisper, topic:, post_number: 2) }

      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [whisper_post.id] } }
      end

      it "rejects it as unfeatureable (422)" do
        expect(result).to fail_a_step(:ensure_added_replies_are_featureable)
      end
    end

    context "when a featured-reply list element is null (raw-hash caller)" do
      # Rails strips array nils from HTTP JSON (deep_munge), so a null element can only
      # reach the service through an in-process call that passes a raw params hash.
      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [nil] } }
      end

      it "collapses to an unresolvable post and 404s instead of raising" do
        expect(result).to fail_a_step(:ensure_added_replies_belong_to_topic)
      end
    end

    context "when the owner replaces the note" do
      before { collection.update!(last_topic_added_at: 1.day.ago, updated_at: 2.days.ago) }
      let(:params) { { id: collection.id, topic_id: topic.id, note: "Updated reason" } }

      it { is_expected.to run_successfully }

      it "writes the note and bumps updated_at only" do
        result

        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.note).to eq("Updated reason")
        expect(collection.reload.updated_at).to be_within(1.second).of(Time.zone.now)
        expect(collection.reload.last_topic_added_at).to be_within(1.second).of(1.day.ago)
        expect(collection.reload.topic_count).to eq(0)
      end
    end

    context "when the owner clears the note with null" do
      let(:params) { { id: collection.id, topic_id: topic.id, note: nil } }

      before do
        DiscourseCollection::CollectionTopic
          .find_by(collection_id: collection.id, topic_id: topic.id)
          .update!(note: "old")
      end

      it "clears it" do
        result

        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.note).to be_nil
      end
    end

    context "with an empty body {} (no note, no reply edits)" do
      before { collection.update!(updated_at: 1.day.ago) }

      it "is an idempotent no-op and does not bump updated_at" do
        result

        expect(collection.reload.updated_at).to be_within(1.second).of(1.day.ago)
      end
    end

    context "when the owner features a reply" do
      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [post.id] } }
      end

      it "inserts the row and raises has_selected_reply" do
        result

        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
            post_id: post.id,
          ).count,
        ).to eq(1)
        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.reload.has_selected_reply).to eq(true)
      end
    end

    context "when a reply is featured twice" do
      before do
        Fabricate(:collection_topic_selected_reply, collection:, topic:, post:)
      end
      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { add: [post.id] } }
      end

      it "is an idempotent no-op (one row only)" do
        result

        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
            post_id: post.id,
          ).count,
        ).to eq(1)
      end
    end

    context "when the owner removes the last featured reply" do
      before do
        Fabricate(:collection_topic_selected_reply, collection:, topic:, post:)
        DiscourseCollection::CollectionTopic
          .find_by(collection_id: collection.id, topic_id: topic.id)
          .update!(has_selected_reply: true)
      end
      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { remove: [post.id] } }
      end

      it "deletes the row and lowers has_selected_reply" do
        result

        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
          ).count,
        ).to eq(0)
        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.reload.has_selected_reply).to eq(false)
      end
    end

    context "when the owner removes a featured reply whose post was soft-deleted afterwards" do
      before do
        Fabricate(:collection_topic_selected_reply, collection:, topic:, post:)
        DiscourseCollection::CollectionTopic
          .find_by(collection_id: collection.id, topic_id: topic.id)
          .update!(has_selected_reply: true)
        post.trash!
      end
      let(:params) do
        { id: collection.id, topic_id: topic.id, selected_replies: { remove: [post.id] } }
      end

      it "unfeatures it anyway (remove only deletes the featured-reply row)" do
        result

        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
          ).count,
        ).to eq(0)
        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.reload.has_selected_reply).to eq(false)
      end
    end

    context "when a remove names posts with no featured row here" do
      # A remove never re-validates the post against the topic: an already-unfeatured
      # post of this topic, and a post belonging to a foreign topic, are both plain
      # idempotent no-ops (no 404), because remove only deletes rows that exist.
      let(:already_unfeatured) { Fabricate(:post, topic:) }
      let(:alien_post) { Fabricate(:post, topic: Fabricate(:topic)) }
      let(:params) do
        {
          id: collection.id,
          topic_id: topic.id,
          selected_replies: { remove: [already_unfeatured.id, alien_post.id] },
        }
      end

      it "is an idempotent no-op that succeeds" do
        result

        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
          ).count,
        ).to eq(0)
        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.reload.has_selected_reply).to eq(false)
      end
    end

    context "when note and featured-reply edits arrive together" do
      let(:params) do
        {
          id: collection.id,
          topic_id: topic.id,
          note: "note too",
          selected_replies: { add: [post.id] },
        }
      end

      it "applies both" do
        result

        membership =
          DiscourseCollection::CollectionTopic.find_by(collection_id: collection.id, topic_id: topic.id)
        expect(membership.note).to eq("note too")
        expect(membership.reload.has_selected_reply).to eq(true)
      end
    end
  end
end
