# frozen_string_literal: true

RSpec.describe DiscourseCollection::CollectionsController do
  fab!(:user)
  fab!(:other_user) { Fabricate(:user) }
  fab!(:stranger) { Fabricate(:user) }
  fab!(:admin, :admin)
  fab!(:moderator, :moderator)

  def build_collection(owner:)
    collection = Fabricate(:collection)
    if owner
      Fabricate(:collection_teamworker, collection: collection, user: owner, is_owner: true)
    end
    collection
  end

  def collect(collection, topic, has_selected_reply: false, note: nil)
    Fabricate(:collection_topic, collection: collection, topic:, has_selected_reply:, note:)
  end

  def select_reply(collection, post, topic: post.topic)
    Fabricate(:collection_topic_selected_reply, collection: collection, topic:, post:)
  end

  def add_co_worker(collection, worker)
    Fabricate(:collection_teamworker, collection: collection, user: worker, is_owner: false)
  end

  # A topic with `count` reply posts (post_number 1..count) belonging to one collection.
  def reply_topic(collection, count:, author: user)
    topic = Fabricate(:topic)
    posts = (1..count).map { |i| Fabricate(:post, topic:, user: author, post_number: i) }
    [topic, posts]
  end

  describe "#update_collected_topic" do
    let(:collection) { build_collection(owner: user) }

    it "requires a logged-in user" do
      patch "/collections/#{collection.id}/topics/1.json", params: { note: "x" }, as: :json

      expect(response.status).to eq(403)
    end

    context "as the collection owner" do
      before { sign_in(user) }

      it "lets the owner replace the note and returns the reading-row shape" do
        topic, = reply_topic(collection, count: 1)
        collect(collection, topic, note: "initial")

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { note: "updated" },
              as: :json

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["note"]).to eq("updated")
        expect(payload["topic"]["id"]).to eq(topic.id)
        expect(payload).to have_key("added_at")
        expect(
          DiscourseCollection::CollectionTopic.find_by(
            collection_id: collection.id,
            topic_id: topic.id,
          ).note,
        ).to eq("updated")
      end

      it "clears the note with null" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "initial")

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { note: nil },
              as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to be_nil
      end

      it "features regular replies via selected_replies.add and reports them inline" do
        # post 1 is the OP and can never be featured; posts 2 and 3 are regular replies.
        topic, posts = reply_topic(collection, count: 3)
        collect(collection, topic)

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { add: [posts[2].id, posts[1].id] } },
              as: :json

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["selected_replies"].map { |reply| reply["post_id"] }).to eq(
          [posts[1].id, posts[2].id], # response order is fixed post_id ASC
        )
        expect(payload).not_to have_key("has_more_selected_replies")
        # A write response is a reading-page row, so it carries the same author source
        # the page reads avatars and usernames from (docs/04 §1).
        expect(payload["users"]).to include(
          posts[1].user_id.to_s => include("username" => posts[1].user.username),
        )
        expect(
          DiscourseCollection::CollectionTopic.find_by(
            collection_id: collection.id,
            topic_id: topic.id,
          ).has_selected_reply,
        ).to eq(true)
      end

      it "rejects featuring the topic's first post with a 422" do
        topic, posts = reply_topic(collection, count: 2)
        collect(collection, topic)

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { add: [posts.first.id] } },
              as: :json

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include(
          I18n.t("discourse_collection.errors.selected_reply_cannot_be_first_post"),
        )
      end

      it "rejects featuring a system/action entry (non-regular post) with a 422" do
        topic, = reply_topic(collection, count: 2)
        collect(collection, topic)
        event = Fabricate(:small_action, topic:, post_number: 3, action_code: "visible.disabled")

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { add: [event.id] } },
              as: :json

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include(
          I18n.t("discourse_collection.errors.selected_reply_must_be_a_regular_post"),
        )
      end

      it "unfeatures replies via selected_replies.remove and drops the inline key when none remain" do
        topic, posts = reply_topic(collection, count: 1)
        collect(collection, topic, has_selected_reply: true)
        select_reply(collection, posts.first, topic:)

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { remove: [posts.first.id] } },
              as: :json

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload).not_to have_key("selected_replies")
        expect(
          DiscourseCollection::CollectionTopic.find_by(
            collection_id: collection.id,
            topic_id: topic.id,
          ).has_selected_reply,
        ).to eq(false)
      end

      it "lets the owner unfeature a reply whose post was soft-deleted afterwards" do
        topic, posts = reply_topic(collection, count: 1)
        collect(collection, topic, has_selected_reply: true)
        select_reply(collection, posts.first, topic:)
        posts.first.trash!

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { remove: [posts.first.id] } },
              as: :json

        expect(response.status).to eq(200)
        expect(
          DiscourseCollection::CollectionTopic.find_by(
            collection_id: collection.id,
            topic_id: topic.id,
          ).has_selected_reply,
        ).to eq(false)
      end

      it "treats a remove naming posts with no featured row as an idempotent no-op" do
        topic, posts = reply_topic(collection, count: 1)
        collect(collection, topic)
        alien_post = Fabricate(:post, topic: Fabricate(:topic))

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { remove: [posts.first.id, alien_post.id] } },
              as: :json

        expect(response.status).to eq(200)
        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
          ).count,
        ).to eq(0)
      end

      it "is an idempotent no-op on an empty body" do
        topic, = reply_topic(collection, count: 1)
        collect(collection, topic, note: "initial")

        patch "/collections/#{collection.id}/topics/#{topic.id}.json", params: {}, as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to eq("initial")
      end

      it "rejects a reply featured and unfeatured at once with a 422" do
        topic, posts = reply_topic(collection, count: 1)
        collect(collection, topic)

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { add: [posts.first.id], remove: [posts.first.id] } },
              as: :json

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include(
          I18n.t("discourse_collection.errors.selected_replies_add_remove_overlap"),
        )
      end

      it "rejects an over-long note with a 422" do
        topic = Fabricate(:topic)
        collect(collection, topic)

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { note: "a" * 101 },
              as: :json

        expect(response.status).to eq(422)
      end

      it "returns 404 when the topic is not collected in the collection" do
        alien_topic = Fabricate(:topic)

        patch "/collections/#{collection.id}/topics/#{alien_topic.id}.json",
              params: { note: "x" },
              as: :json

        expect(response.status).to eq(404)
      end

      it "returns 404 when a referenced reply belongs to another topic" do
        topic = Fabricate(:topic)
        collect(collection, topic)
        alien_post = Fabricate(:post, topic: Fabricate(:topic))

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { add: [alien_post.id] } },
              as: :json

        expect(response.status).to eq(404)
      end

      it "stores a JSON-number note as text instead of raising" do
        topic = Fabricate(:topic)
        collect(collection, topic)

        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { note: 123 },
              as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to eq("123")
      end

      it "returns 404 (not a 500) for a non-numeric featured-reply element" do
        topic = Fabricate(:topic)
        collect(collection, topic)

        # A JSON null inside the array never reaches the service: Rails deep_munge
        # strips array nils while parsing the request, so add: [null] is just an
        # empty-add no-op (that branch is exercised at the service-spec layer, where a
        # raw params hash can still carry nil). A non-numeric string survives parsing
        # and collapses to post_id 0, which no post owns -> the belongs-to-topic 404.
        patch "/collections/#{collection.id}/topics/#{topic.id}.json",
              params: { selected_replies: { add: ["abc"] } },
              as: :json

        expect(response.status).to eq(404)
      end
    end

    it "lets a co-maintainer edit a topic" do
      collection = build_collection(owner: other_user)
      add_co_worker(collection, user)
      topic = Fabricate(:topic)
      collect(collection, topic)
      sign_in(user)

      patch "/collections/#{collection.id}/topics/#{topic.id}.json",
            params: { note: "by worker" },
            as: :json

      expect(response.status).to eq(200)
    end

    it "rejects an outsider with a 403" do
      topic = Fabricate(:topic)
      collect(collection, topic)
      sign_in(stranger)

      patch "/collections/#{collection.id}/topics/#{topic.id}.json",
            params: { note: "x" },
            as: :json

      expect(response.status).to eq(403)
    end

    it "does not let staff edit someone else's collection through docs/04 §4" do
      collection = build_collection(owner: other_user)
      topic = Fabricate(:topic)
      collect(collection, topic)
      sign_in(admin)

      patch "/collections/#{collection.id}/topics/#{topic.id}.json",
            params: { note: "x" },
            as: :json

      expect(response.status).to eq(403)
    end
  end

  describe "#collected_topic" do
    let(:collection) { build_collection(owner: other_user) }

    it "is disabled when collection_enabled is off" do
      SiteSetting.collection_enabled = false
      topic = Fabricate(:topic)
      collect(collection, topic)
      sign_in(user)

      get "/collections/#{collection.id}/topics/#{topic.id}.json"

      expect(response.status).to eq(404)
    end

    context "when anonymous access is disabled" do
      before { SiteSetting.collection_allow_anonymous = false }

      it "rejects anonymous visitors with a 404" do
        topic = Fabricate(:topic)
        collect(collection, topic)

        get "/collections/#{collection.id}/topics/#{topic.id}.json"

        expect(response.status).to eq(404)
      end
    end

    context "when anonymous access is enabled" do
      before { SiteSetting.collection_allow_anonymous = true }

      it "lets an anonymous visitor read the note" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "public note")

        get "/collections/#{collection.id}/topics/#{topic.id}.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to eq("public note")
      end
    end

    context "as a logged-in reader" do
      before { sign_in(stranger) }

      it "returns the reading-page row of the collected topic" do
        topic = Fabricate(:topic, user: user)
        row = collect(collection, topic, note: "a note")

        get "/collections/#{collection.id}/topics/#{topic.id}.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["note"]).to eq("a note")
        expect(Time.zone.parse(payload["added_at"]).to_i).to eq(row.created_at.to_i)
        expect(payload["topic"]["id"]).to eq(topic.id)
        expect(payload["users"].keys).to eq([user.id.to_s])
        expect(payload).not_to have_key("selected_replies")
      end

      it "inlines the selected replies of a flagged topic, like the reading page" do
        topic, posts = reply_topic(collection, count: 2)
        collect(collection, topic, has_selected_reply: true)
        select_reply(collection, posts[1])

        get "/collections/#{collection.id}/topics/#{topic.id}.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["selected_replies"].map { |reply| reply["post_id"] }).to eq(
          [posts[1].id],
        )
      end

      it "returns 404 when the topic is not collected in the collection" do
        alien_topic = Fabricate(:topic)

        get "/collections/#{collection.id}/topics/#{alien_topic.id}.json"

        expect(response.status).to eq(404)
      end

      it "returns 404 for a topic the visitor cannot see" do
        topic = Fabricate(:private_message_topic)
        collect(collection, topic)

        get "/collections/#{collection.id}/topics/#{topic.id}.json"

        expect(response.status).to eq(404)
      end

      it "returns 404 for a collection that does not exist" do
        topic = Fabricate(:topic)

        get "/collections/999999/topics/#{topic.id}.json"

        expect(response.status).to eq(404)
      end
    end
  end

  describe "#rewrite_topic_note" do
    let(:collection) { build_collection(owner: other_user) }

    it "requires a logged-in user" do
      put "/collections/#{collection.id}/topics/1/note.json", params: { note: "x" }, as: :json

      expect(response.status).to eq(403)
    end

    context "as an admin" do
      before { sign_in(admin) }

      it "rewrites a note on someone else's collection and returns the row" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "original")

        put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
            params: { note: "fixed by staff" },
            as: :json

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["note"]).to eq("fixed by staff")
        expect(payload["topic"]["id"]).to eq(topic.id)
        expect(
          DiscourseCollection::CollectionTopic.find_by(
            collection_id: collection.id,
            topic_id: topic.id,
          ).note,
        ).to eq("fixed by staff")
      end

      it "rewrites a note on an ownerless collection" do
        ownerless = build_collection(owner: nil)
        topic = Fabricate(:topic)
        collect(ownerless, topic, note: "original")

        put "/collections/#{ownerless.id}/topics/#{topic.id}/note.json",
            params: { note: "fixed" },
            as: :json

        expect(response.status).to eq(200)
      end

      it "clears the note with null" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "original")

        put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
            params: { note: nil },
            as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to be_nil
      end

      it "ignores non-note body fields (featured edits stay owner/teamworker-only)" do
        topic = Fabricate(:topic)
        collect(collection, topic, has_selected_reply: true)
        post = Fabricate(:post, topic:, post_number: 1)
        select_reply(collection, post, topic:)

        put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
            params: { note: "fixed", selected_replies: { remove: [post.id] } },
            as: :json

        expect(response.status).to eq(200)
        expect(
          DiscourseCollection::CollectionTopicSelectedReply.where(
            collection_id: collection.id,
            topic_id: topic.id,
            post_id: post.id,
          ).count,
        ).to eq(1) # untouched
        expect(
          DiscourseCollection::CollectionTopic.find_by(
            collection_id: collection.id,
            topic_id: topic.id,
          ).note,
        ).to eq("fixed")
      end

      it "rejects an over-long note with a 422" do
        topic = Fabricate(:topic)
        collect(collection, topic)

        put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
            params: { note: "a" * 101 },
            as: :json

        expect(response.status).to eq(422)
      end

      it "returns 404 when the topic is not collected in the collection" do
        alien_topic = Fabricate(:topic)

        put "/collections/#{collection.id}/topics/#{alien_topic.id}/note.json",
            params: { note: "x" },
            as: :json

        expect(response.status).to eq(404)
      end

      it "is an idempotent no-op when no note is sent" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "original")

        put "/collections/#{collection.id}/topics/#{topic.id}/note.json", params: {}, as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to eq("original")
      end
    end

    context "as a moderator with the manage-moderation setting off" do
      before do
        SiteSetting.collection_moderators_can_manage_collections = false
        sign_in(moderator)
      end

      it "can still rewrite a note on someone else's collection (note exception is not gated)" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "original")

        put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
            params: { note: "moderated" },
            as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["note"]).to eq("moderated")
      end
    end

    it "rejects a regular outsider with a 403" do
      topic = Fabricate(:topic)
      collect(collection, topic)
      sign_in(stranger)

      put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
          params: { note: "x" },
          as: :json

      expect(response.status).to eq(403)
    end

    it "rejects the collection owner (non-staff) with a 403" do
      collection = build_collection(owner: other_user)
      topic = Fabricate(:topic)
      collect(collection, topic)
      sign_in(other_user)

      put "/collections/#{collection.id}/topics/#{topic.id}/note.json",
          params: { note: "x" },
          as: :json

      expect(response.status).to eq(403)
    end
  end
end
