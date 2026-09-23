# frozen_string_literal: true

RSpec.describe DiscourseCollection::CollectionsController do
  fab!(:owner, :user)
  fab!(:maintainer, :user)
  fab!(:stranger, :user)
  fab!(:collection)

  before do
    SiteSetting.collection_enabled = true
    Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    Fabricate(:collection_teamworker, collection:, user: maintainer, is_owner: false)
  end

  it "lets a maintainer save the reading order without acquiring metadata permissions" do
    sign_in(maintainer)
    put "/collections/#{collection.id}/reading_defaults.json",
        params: { default_topic_sort: "topic_created_at", default_topic_order: "asc", name: "Ignored" }
    expect(response.status).to eq(200)
    expect(response.parsed_body["default_topic_sort"]).to eq("topic_created_at")
    expect(response.parsed_body["default_topic_order"]).to eq("asc")
    expect(collection.reload.name).not_to eq("Ignored")
    put "/collections/#{collection.id}.json", params: { name: "Forbidden" }
    expect(response.status).to eq(403)
  end

  it "rejects visitors and invalid combinations without changing either default" do
    sign_in(stranger)
    put "/collections/#{collection.id}/reading_defaults.json",
        params: { default_topic_sort: "added_at", default_topic_order: "asc" }
    expect(response.status).to eq(403)
    sign_in(owner)
    put "/collections/#{collection.id}/reading_defaults.json",
        params: { default_topic_sort: "unknown", default_topic_order: "asc" }
    expect(response.status).to eq(422)
    expect(collection.reload.default_topic_sort).to eq("added_at")
    expect(collection.default_topic_order).to eq("desc")
  end

  it "uses the saved default for pagination and accepts a reader override" do
    sign_in(stranger)
    older = Fabricate(:topic, created_at: 2.days.ago)
    newer = Fabricate(:topic, created_at: 1.day.ago)
    [older, newer].each { |topic| Fabricate(:collection_topic, collection:, topic:) }
    collection.update!(default_topic_sort: "topic_created_at", default_topic_order: "asc")
    get "/collections/#{collection.id}/topics.json", params: { page_size: 1 }
    expect(response.parsed_body["topics"].first.dig("topic", "id")).to eq(older.id)
    expect(response.parsed_body["meta"]["more"]).to eq(true)
    get "/collections/#{collection.id}/topics.json", params: { page_size: 1, page: 1 }
    expect(response.parsed_body["topics"].first.dig("topic", "id")).to eq(newer.id)
    get "/collections/#{collection.id}/topics.json", params: { order: "desc" }
    expect(response.parsed_body["topics"].map { |row| row.dig("topic", "id") }).to eq([newer.id, older.id])
    expect(collection.reload.default_topic_order).to eq("asc")
  end
end
