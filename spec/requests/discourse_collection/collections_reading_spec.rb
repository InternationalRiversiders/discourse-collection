# frozen_string_literal: true

RSpec.describe DiscourseCollection::CollectionsController do
  fab!(:user)
  fab!(:other_user) { Fabricate(:user) }
  fab!(:admin, :admin)

  def build_collection(owner:)
    collection = Fabricate(:collection)
    Fabricate(:collection_teamworker, collection: collection, user: owner, is_owner: true)
    collection
  end

  def collect(collection, topic, has_selected_reply: false, created_at: nil, note: nil)
    row = Fabricate(:collection_topic, collection: collection, topic:, has_selected_reply:, note:)
    row.update_column(:created_at, created_at) if created_at
    row
  end

  def select_reply(collection, post, topic: post.topic)
    Fabricate(:collection_topic_selected_reply, collection: collection, topic:, post:)
  end

  # A topic with `count` reply posts (post_number 1..count) belonging to one collection.
  def reply_topic(collection, count:, author: user)
    topic = Fabricate(:topic)
    posts = (1..count).map { |i| Fabricate(:post, topic:, user: author, post_number: i) }
    [topic, posts]
  end

  describe "#topics" do
    let(:collection) { build_collection(owner: other_user) }

    before { sign_in(user) }

    it "is disabled when collection_enabled is off" do
      SiteSetting.collection_enabled = false

      get "/collections/#{collection.id}/topics.json"

      expect(response.status).to eq(404)
    end

    context "when anonymous access is disabled" do
      before { SiteSetting.collection_allow_anonymous = false }
      before { delete "/session/#{user.encoded_username}" }

      it "rejects anonymous visitors with a 404" do
        get "/collections/#{collection.id}/topics.json"

        expect(response.status).to eq(404)
      end
    end

    context "when anonymous access is enabled" do
      before { SiteSetting.collection_allow_anonymous = true }
      before { delete "/session/#{user.encoded_username}" }

      it "lets anonymous visitors read the page" do
        topic = Fabricate(:topic)
        collect(collection, topic, note: "hello")

        get "/collections/#{collection.id}/topics.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["topics"].length).to eq(1)
      end
    end

    it "returns 404 for a missing collection" do
      get "/collections/999999/topics.json"

      expect(response.status).to eq(404)
    end

    it "rejects an invalid order with 400" do
      get "/collections/#{collection.id}/topics.json", params: { order: "sideways" }

      expect(response.status).to eq(400)
    end

    it "returns collected topics newest-first by default with note and topic card" do
      older = Fabricate(:topic)
      newer = Fabricate(:topic)
      newer.update_column(:excerpt, "Lead of the new topic")
      collect(collection, older, note: "old note", created_at: 2.hours.ago)
      collect(collection, newer, note: "new note", created_at: 1.hour.ago)

      get "/collections/#{collection.id}/topics.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["topics"].map { |row| row["topic"]["id"] }).to eq([newer.id, older.id])
      expect(payload["topics"].first["note"]).to eq("new note")

      card = payload["topics"].first["topic"]
      expect(card["id"]).to eq(newer.id)
      expect(card["excerpt"]).to eq("Lead of the new topic")
      expect(card["user_id"]).to eq(newer.user_id)
      expect(card).to have_key("fancy_title")
      expect(card).to have_key("slug")
      expect(card).to have_key("category_id")
      expect(card).to have_key("created_at")
      expect(card).to have_key("bumped_at")
      expect(card).to have_key("posts_count")
      expect(card).not_to have_key("selected_replies")

      # The page carries the authors its rows reference, keyed by user id (docs/04 §1).
      users = payload["users"]
      expect(users.keys.map(&:to_i)).to contain_exactly(newer.user_id, older.user_id)
      expect(users[newer.user_id.to_s]).to include(
        "id" => newer.user_id,
        "username" => newer.user.username,
        "name" => newer.user.name,
        "avatar_template" => newer.user.avatar_template,
      )
    end

    it "sends the topic excerpt as plain text, not core's escaped HTML" do
      # topics.excerpt holds escaped text: the truncation marker reaches us as the
      # entity `&hellip;`, which the frontend would otherwise print verbatim.
      topic = Fabricate(:topic)
      topic.update_column(:excerpt, "Rivers &amp; lakes&hellip;")
      collect(collection, topic)

      get "/collections/#{collection.id}/topics.json"

      expect(response.parsed_body["topics"].first["topic"]["excerpt"]).to eq(
        "Rivers & lakes…",
      )
    end

    it "sends a reply excerpt as plain text, with its links stripped" do
      topic, posts = reply_topic(collection, count: 2)
      reply = posts.last
      reply.update_columns(
        cooked: '<p>Look at <a href="https://example.com/rivers">this &amp; that</a></p>',
      )
      collect(collection, topic, has_selected_reply: true)
      select_reply(collection, reply, topic:)

      get "/collections/#{collection.id}/topics.json"

      selected = response.parsed_body["topics"].first["selected_replies"].first
      expect(selected["post_id"]).to eq(reply.id)
      expect(selected["excerpt"]).to eq("Look at this & that")
    end

    it "supports order=asc" do
      older = Fabricate(:topic)
      newer = Fabricate(:topic)
      collect(collection, older, created_at: 2.hours.ago)
      collect(collection, newer, created_at: 1.hour.ago)

      get "/collections/#{collection.id}/topics.json", params: { order: "asc", sort: "added_at" }

      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq(
        [older.id, newer.id],
      )
    end

    # The fixtures are deliberately contradictory — the topic collected last is the one
    # created first — so the expected order can only come from the topics column.
    it "sorts by the topic's own creation time" do
      collected_first = Fabricate(:topic, created_at: 1.day.ago)
      collected_last = Fabricate(:topic, created_at: 5.days.ago)
      collect(collection, collected_first, created_at: 2.hours.ago)
      collect(collection, collected_last, created_at: 1.hour.ago)

      get "/collections/#{collection.id}/topics.json", params: { sort: "topic_created_at" }

      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq(
        [collected_first.id, collected_last.id],
      )
    end

    it "sorts by the topic's latest activity" do
      active_topic = Fabricate(:topic, bumped_at: 1.hour.ago)
      idle_topic = Fabricate(:topic, bumped_at: 3.days.ago)
      collect(collection, active_topic, created_at: 2.hours.ago)
      collect(collection, idle_topic, created_at: 1.hour.ago)

      get "/collections/#{collection.id}/topics.json", params: { sort: "topic_bumped_at" }

      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq(
        [active_topic.id, idle_topic.id],
      )
    end

    it "breaks ties on topic_id, in the direction the order asked for" do
      first_topic = Fabricate(:topic, created_at: 2.days.ago)
      second_topic = Fabricate(:topic, created_at: 2.days.ago)
      lower, higher = [first_topic, second_topic].sort_by(&:id)
      collect(collection, first_topic)
      collect(collection, second_topic)

      get "/collections/#{collection.id}/topics.json", params: { sort: "topic_created_at" }
      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq(
        [higher.id, lower.id],
      )

      get "/collections/#{collection.id}/topics.json",
          params: { sort: "topic_created_at", order: "asc" }
      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq(
        [lower.id, higher.id],
      )
    end

    it "rejects an unknown sort key" do
      get "/collections/#{collection.id}/topics.json", params: { sort: "sideways" }

      expect(response.status).to eq(400)
    end

    it "paginates with meta" do
      3.times.map { Fabricate(:topic) }.each { |topic| collect(collection, topic) }

      get "/collections/#{collection.id}/topics.json", params: { page_size: 2 }

      payload = response.parsed_body
      expect(payload["topics"].length).to eq(2)
      expect(payload["meta"]).to eq(
        { "page" => 0, "page_size" => 2, "more" => true, "total" => 3 },
      )
    end

    it "omits collected topics whose topic is gone" do
      gone = Fabricate(:topic)
      collect(collection, gone)
      gone.update_column(:deleted_at, Time.zone.now)
      alive = Fabricate(:topic)
      collect(collection, alive)

      get "/collections/#{collection.id}/topics.json"

      topics = response.parsed_body["topics"].map { |row| row["topic"]["id"] }
      expect(topics).to eq([alive.id])
      expect(response.parsed_body["meta"]["total"]).to eq(1)
    end

    it "pages over the collected topics the visitor can see (restricted categories excluded before the window)" do
      group = Fabricate(:group)
      restricted = Fabricate(:private_category, group:)
      hidden_a = Fabricate(:topic, category: restricted)
      vis_b = Fabricate(:topic)
      hidden_c = Fabricate(:topic, category: restricted)
      vis_d = Fabricate(:topic)
      vis_e = Fabricate(:topic)

      # Membership order asc: hidden_a < vis_b < hidden_c < vis_d < vis_e.
      collect(collection, hidden_a, created_at: 5.minutes.ago)
      collect(collection, vis_b, created_at: 4.minutes.ago)
      collect(collection, hidden_c, created_at: 3.minutes.ago)
      collect(collection, vis_d, created_at: 2.minutes.ago)
      collect(collection, vis_e, created_at: 1.minute.ago)

      # Visible asc = [vis_b, vis_d, vis_e]: page 0 is a full, contiguous window that
      # skips the two restricted rows. Pre-fix the raw window [hidden_a, vis_b] would
      # have shrunk to just vis_b (a hole), with vis_d sliding onto page 1.
      get "/collections/#{collection.id}/topics.json", params: { order: "asc", page_size: 2 }

      payload = response.parsed_body
      expect(payload["topics"].map { |row| row["topic"]["id"] }).to eq([vis_b.id, vis_d.id])
      # meta.total counts the full collected set (restricted rows included), so the
      # restricted visitor sees fewer rows than the meta states.
      expect(payload["meta"]["total"]).to eq(5)

      get "/collections/#{collection.id}/topics.json",
          params: { order: "asc", page: 1, page_size: 2 }

      payload = response.parsed_body
      expect(payload["topics"].map { |row| row["topic"]["id"] }).to eq([vis_e.id])
      expect(payload["meta"]["total"]).to eq(5)

      # Staff sees the restricted rows too (category access is a visitor filter, not a
      # hard exclusion), so the SQL narrowing never over-filters for privileged users.
      sign_in(admin)
      get "/collections/#{collection.id}/topics.json", params: { order: "asc" }

      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq(
        [hidden_a.id, vis_b.id, hidden_c.id, vis_d.id, vis_e.id],
      )
    end

    it "hides unlisted topics from visitors who cannot list them, and marks them for staff" do
      unlisted = Fabricate(:topic)
      unlisted.update_column(:visible, false)
      public_topic = Fabricate(:topic)
      collect(collection, unlisted, created_at: 1.hour.ago)
      collect(collection, public_topic, created_at: 2.hours.ago)

      get "/collections/#{collection.id}/topics.json"

      # Unlisted is a listing rule, not a read rule: the ordinary visitor simply does not
      # get the row (meta.total still counts the full collected set).
      payload = response.parsed_body
      expect(payload["topics"].map { |row| row["topic"]["id"] }).to eq([public_topic.id])
      expect(payload["topics"].first["topic"]).not_to have_key("unlisted")
      expect(payload["meta"]["total"]).to eq(2)

      sign_in(admin)
      get "/collections/#{collection.id}/topics.json"

      payload = response.parsed_body
      expect(payload["topics"].map { |row| row["topic"]["id"] }).to eq(
        [unlisted.id, public_topic.id],
      )
      expect(payload["topics"].first["topic"]["unlisted"]).to eq(true)
      # The key is conditional: a public topic carries none.
      expect(payload["topics"].second["topic"]).not_to have_key("unlisted")
    end

    it "lists unlisted topics for TL4 only — not for the collection owner either" do
      unlisted = Fabricate(:topic)
      unlisted.update_column(:visible, false)
      collect(collection, unlisted)

      sign_in(other_user) # the collection owner, a plain user
      get "/collections/#{collection.id}/topics.json"

      expect(response.parsed_body["topics"]).to be_empty

      sign_in(Fabricate(:user, trust_level: TrustLevel[4]))
      get "/collections/#{collection.id}/topics.json"

      expect(response.parsed_body["topics"].map { |row| row["topic"]["id"] }).to eq([unlisted.id])
    end

    it "inlines selected replies (capped, post_id asc) and only then the has_more key" do
      topic, posts = reply_topic(collection, count: 4)
      collect(collection, topic, has_selected_reply: true, note: "deep")
      posts.each { |post| select_reply(collection, post, topic:) }

      get "/collections/#{collection.id}/topics.json"

      row = response.parsed_body["topics"].first
      ids = row["selected_replies"].map { |reply| reply["post_id"] }
      expect(ids).to eq(posts.first(3).map(&:id)) # post_id ASC, capped at the default 3
      expect(row["has_more_selected_replies"]).to eq(true)
      expect(row["note"]).to eq("deep")
    end

    it "keeps selected_replies for flagged topics and omits the key for un-flagged ones" do
      flagged_topic, posts = reply_topic(collection, count: 1)
      plain_topic = Fabricate(:topic)
      collect(collection, flagged_topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic: flagged_topic) }
      collect(collection, plain_topic)

      get "/collections/#{collection.id}/topics.json"

      rows = response.parsed_body["topics"]
      expect(rows.length).to eq(2)
      flagged = rows.find { |row| row["topic"]["id"] == flagged_topic.id }
      plain = rows.find { |row| row["topic"]["id"] == plain_topic.id }
      expect(flagged["selected_replies"].length).to eq(1)
      expect(flagged).not_to have_key("has_more_selected_replies")
      expect(plain).not_to have_key("selected_replies")
    end

    it "does not report has_more_selected_replies within the cap" do
      topic, posts = reply_topic(collection, count: 3)
      collect(collection, topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic:) }

      get "/collections/#{collection.id}/topics.json"

      row = response.parsed_body["topics"].first
      expect(row["selected_replies"].length).to eq(3)
      expect(row).not_to have_key("has_more_selected_replies")
    end

    it "filters a soft-deleted selected reply out (row kept)" do
      topic, posts = reply_topic(collection, count: 3)
      collect(collection, topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic:) }
      posts.last.update_column(:deleted_at, Time.zone.now)

      get "/collections/#{collection.id}/topics.json"

      row = response.parsed_body["topics"].first
      expect(row["selected_replies"].map { |reply| reply["post_id"] }).to eq(
        posts.first(2).map(&:id),
      )
    end

    it "filters hidden selected replies for non-staff but shows them to staff" do
      topic, posts = reply_topic(collection, count: 2, author: other_user)
      collect(collection, topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic:) }
      posts.second.update_column(:hidden, true)

      get "/collections/#{collection.id}/topics.json"

      expect(response.parsed_body["topics"].first["selected_replies"].length).to eq(1)

      sign_in(admin)
      get "/collections/#{collection.id}/topics.json"

      expect(response.parsed_body["topics"].first["selected_replies"].length).to eq(2)
    end
  end

  describe "#selected_replies" do
    let(:collection) { build_collection(owner: other_user) }

    before { sign_in(user) }

    it "still serves an unlisted topic's selected replies by link (unlisted is not a read rule)" do
      topic, posts = reply_topic(collection, count: 2)
      topic.update_column(:visible, false)
      collect(collection, topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic:) }

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["selected_replies"].length).to eq(2)
    end

    it "returns 404 when the topic is not collected in the collection" do
      alien_topic = Fabricate(:topic)
      get "/collections/#{collection.id}/topics/#{alien_topic.id}/selected_replies.json"

      expect(response.status).to eq(404)
    end

    it "returns every selected reply, fixed post_id asc and paginated without the cap" do
      topic, posts = reply_topic(collection, count: 5)
      collect(collection, topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic:) }

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies.json",
          params: { page_size: 2 }

      payload = response.parsed_body
      expect(payload["selected_replies"].map { |reply| reply["post_id"] }).to eq(
        posts.first(2).map(&:id),
      )
      expect(payload["meta"]).to eq(
        { "page" => 0, "page_size" => 2, "more" => true, "total" => 5 },
      )

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies.json",
          params: { page: 2, page_size: 2 }

      page = response.parsed_body
      expect(page["selected_replies"].map { |reply| reply["post_id"] }).to eq(
        [posts[4].id],
      )
      expect(page["meta"]["more"]).to eq(false)
    end

    it "shapes each reply like the inline entries (post_id/post_number/user_id/created_at/excerpt)" do
      topic, posts = reply_topic(collection, count: 1)
      post = posts.first
      post.user = other_user
      post.save!
      collect(collection, topic, has_selected_reply: true)
      selected = select_reply(collection, post, topic:)

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies.json"

      payload = response.parsed_body
      reply = payload["selected_replies"].first
      expect(reply["post_id"]).to eq(post.id)
      expect(reply["post_number"]).to eq(post.post_number)
      expect(reply["user_id"]).to eq(other_user.id)
      # The author travels as an id: the name and avatar live in the response's
      # `users` map, never inline in the entry (docs/04 §1).
      expect(reply).not_to have_key("username")
      expect(payload["users"][other_user.id.to_s]).to include(
        "id" => other_user.id,
        "username" => other_user.username,
      )
      # created_at is the selected-reply row's own creation time (when it was
      # selected), not the post's.
      expect(Time.zone.parse(reply["created_at"]).to_i).to eq(selected.created_at.to_i)
      expect(reply).to have_key("excerpt")
    end
  end

  describe "#selected_replies_count" do
    let(:collection) { build_collection(owner: other_user) }

    before { sign_in(user) }

    it "counts every row, including one the visitor cannot see" do
      topic, posts = reply_topic(collection, count: 3)
      collect(collection, topic, has_selected_reply: true)
      posts.each { |post| select_reply(collection, post, topic:) }
      posts.first.update_column(:deleted_at, Time.zone.now)

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies.json"
      expect(response.parsed_body["selected_replies"].length).to eq(2)

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies/count.json"

      expect(response.status).to eq(200)
      # The count is what the removal would cascade away, so it stays a total rather
      # than the visible number above (docs/04 §7).
      expect(response.parsed_body).to eq({ "selected_reply_count" => 3 })
    end

    it "returns zero for a collected topic without selected replies" do
      topic = Fabricate(:topic)
      collect(collection, topic)

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies/count.json"

      expect(response.parsed_body).to eq({ "selected_reply_count" => 0 })
    end

    it "returns 404 when the topic is not collected in the collection" do
      alien_topic = Fabricate(:topic)

      get "/collections/#{collection.id}/topics/#{alien_topic.id}/selected_replies/count.json"

      expect(response.status).to eq(404)
    end

    it "returns 404 for a topic the visitor cannot see" do
      topic = Fabricate(:private_message_topic)
      collect(collection, topic)

      get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies/count.json"

      expect(response.status).to eq(404)
    end

    context "when anonymous access is disabled" do
      before { SiteSetting.collection_allow_anonymous = false }
      before { delete "/session/#{user.encoded_username}" }

      it "rejects anonymous visitors with a 404" do
        topic = Fabricate(:topic)
        collect(collection, topic, has_selected_reply: true)

        get "/collections/#{collection.id}/topics/#{topic.id}/selected_replies/count.json"

        expect(response.status).to eq(404)
      end
    end
  end
end
