# frozen_string_literal: true

# Topic-page reverse lookup (docs/07) on the core /t/:id.json endpoint: the topic
# level injects top-level `collections` (id+name of the collections collecting the topic,
# present only when ≥1), the post level injects `selected_by_collection_ids` onto the
# posts some collection features (key omitted when a post has none).
RSpec.describe "DiscourseCollection topic page reverse lookup" do
  fab!(:user)

  def build_collection(owner: user, name: "Sample collection")
    collection = Fabricate(:collection, name:)
    if owner
      Fabricate(:collection_teamworker, collection: collection, user: owner, is_owner: true)
    end
    collection
  end

  def collect(collection, topic)
    Fabricate(:collection_topic, collection: collection, topic:, has_selected_reply: false)
  end

  def select_reply(collection, post, topic: post.topic)
    Fabricate(:collection_topic_selected_reply, collection: collection, topic:, post:)
  end

  # A topic whose posts carry explicit post_number 1..count (post 1 is the OP) —
  # same shape as the collections reading spec helper.
  def reply_topic(count:, author: user)
    topic = Fabricate(:topic)
    posts = (1..count).map { |i| Fabricate(:post, topic:, user: author, post_number: i) }
    [topic, posts]
  end

  def topic_page(topic)
    get "/t/#{topic.id}.json"
    expect(response.status).to eq(200)
    response.parsed_body
  end

  def posts_by_id(payload)
    payload.dig("post_stream", "posts").index_by { |post| post["id"] }
  end

  before { sign_in(user) }

  it "injects top-level `collections` (id+name only, id-ascending) for every collection collecting the topic" do
    topic, = reply_topic(count: 1)
    collection_a = build_collection(name: "Collection A")
    collection_b = build_collection(name: "Collection B")
    collect(collection_a, topic)
    collect(collection_b, topic)

    payload = topic_page(topic)

    expect(payload["collections"]).to eq(
      [{ "id" => collection_a.id, "name" => "Collection A" }, { "id" => collection_b.id, "name" => "Collection B" }],
    )
    expect(payload["collections"].all? { |item| item.keys.sort == %w[id name] }).to be(true)
  end

  it "injects `selected_by_collection_ids` onto each featured post individually and omits it elsewhere" do
    topic, posts = reply_topic(count: 3)
    collection_a = build_collection(name: "Collection A")
    collection_b = build_collection(name: "Collection B")
    collect(collection_a, topic)
    collect(collection_b, topic)
    select_reply(collection_a, posts[1]) # reply post_number 2
    select_reply(collection_b, posts[2]) # reply post_number 3

    payload = topic_page(topic)
    by_id = posts_by_id(payload)

    expect(by_id[posts[1].id]["selected_by_collection_ids"]).to eq([collection_a.id])
    expect(by_id[posts[2].id]["selected_by_collection_ids"]).to eq([collection_b.id])
    # OP and any post without a feature carry no key at all.
    expect(by_id[posts[0].id]).not_to have_key("selected_by_collection_ids")
    expect(by_id[posts[2].id]).to have_key("selected_by_collection_ids")
    expect(by_id.keys).to contain_exactly(*posts.map(&:id))
  end

  it "aggregates the collections that feature the same post into one id list" do
    topic, posts = reply_topic(count: 2)
    collection_a = build_collection(name: "Collection A")
    collection_b = build_collection(name: "Collection B")
    collect(collection_a, topic)
    collect(collection_b, topic)
    select_reply(collection_a, posts[1])
    select_reply(collection_b, posts[1])

    payload = topic_page(topic)

    expect(posts_by_id(payload)[posts[1].id]["selected_by_collection_ids"]).to eq(
      [collection_a.id, collection_b.id],
    )
  end

  it "omits both levels for a topic that is not collected, and stays scoped to the topic" do
    topic, = reply_topic(count: 1)

    # An unrelated topic that is collected + featured must not leak into this one.
    other_topic, other_posts = reply_topic(count: 2)
    other_collection = build_collection(name: "Other collection")
    collect(other_collection, other_topic)
    select_reply(other_collection, other_posts[1])

    payload = topic_page(topic)

    expect(payload).not_to have_key("collections")
    expect(
      payload["post_stream"]["posts"].all? do |post|
        !post.key?("selected_by_collection_ids")
      end,
    ).to be(true)
  end

  it "injects nothing while collection_enabled is off, even when rows exist" do
    topic, posts = reply_topic(count: 2)
    collection = build_collection(name: "Hidden collection")
    collect(collection, topic)
    select_reply(collection, posts[1])

    SiteSetting.collection_enabled = false
    begin
      payload = topic_page(topic)
      expect(payload).not_to have_key("collections")
      expect(
        payload["post_stream"]["posts"].all? { |post| !post.key?("selected_by_collection_ids") },
      ).to be(true)
    ensure
      SiteSetting.collection_enabled = true
    end
  end
end
