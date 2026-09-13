# frozen_string_literal: true

RSpec.describe DiscourseCollection::DataExplorerSchema do
  def column(name, attributes = {})
    { "column_name" => name }.merge(attributes)
  end

  # The shape Data Explorer hands to the admin UI for our tables. Everything its own
  # heuristics already got right is spelled out here too (`primary` on an `id`, the
  # foreign keys it resolves from column names), so the spec pins what must be left
  # exactly as it found it.
  let(:schema) do
    {
      "collections" => [
        column("id", "data_type" => "serial", "primary" => true),
        column("name", "data_type" => "varchar(60)"),
      ],
      "collection_topics" => [
        column("collection_id", "data_type" => "integer"),
        column("topic_id", "data_type" => "integer", "fkey_info" => :topics),
        column("created_at", "data_type" => "timestamp"),
      ],
      "collection_teamworkers" => [
        column("collection_id", "data_type" => "integer"),
        column("user_id", "data_type" => "integer", "fkey_info" => :users),
      ],
      "collection_topic_selected_replies" => [
        column("collection_id", "data_type" => "integer"),
        column("post_id", "data_type" => "integer", "fkey_info" => :posts),
      ],
      "collection_subscribers" => [
        column("collection_id", "data_type" => "integer"),
        column("user_id", "data_type" => "integer", "fkey_info" => :users),
      ],
      "collection_invites" => [
        column("id", "data_type" => "serial", "primary" => true),
        column("collection_id", "data_type" => "integer"),
        column("action_type", "data_type" => "integer"),
        column("accept", "data_type" => "boolean"),
        column("inviter_user_id", "data_type" => "integer", "fkey_info" => :users),
        column("invitee_user_id", "data_type" => "integer", "fkey_info" => :users),
      ],
      "posts" => [
        column("id", "data_type" => "serial", "primary" => true),
        column("topic_id", "data_type" => "integer", "fkey_info" => :topics),
      ],
    }
  end

  def column_in(table, name)
    schema.fetch(table).find { |entry| entry["column_name"] == name }
  end

  before { described_class.decorate!(schema) }

  it "marks the composite primary keys Data Explorer cannot recognize by column name" do
    expect(column_in("collection_topics", "collection_id")["primary"]).to eq(true)
    expect(column_in("collection_topics", "topic_id")["primary"]).to eq(true)
    expect(column_in("collection_teamworkers", "collection_id")["primary"]).to eq(true)
    expect(column_in("collection_teamworkers", "user_id")["primary"]).to eq(true)
    expect(column_in("collection_topic_selected_replies", "post_id")["primary"]).to eq(true)
    expect(column_in("collection_subscribers", "user_id")["primary"]).to eq(true)
  end

  it "marks no column that is not part of a key" do
    expect(column_in("collections", "name")).not_to have_key("primary")
    expect(column_in("collection_topics", "created_at")).not_to have_key("primary")
    expect(column_in("collection_invites", "action_type")).not_to have_key("primary")
    expect(column_in("collection_invites", "accept")).not_to have_key("primary")
  end

  it "does not rewrite the data type of the columns it marks" do
    expect(column_in("collection_topics", "collection_id")["data_type"]).to eq("integer")
    expect(column_in("collections", "id")["data_type"]).to eq("serial")
  end

  it "fills in the collection_id foreign key on every table that has one" do
    %w[
      collection_invites
      collection_subscribers
      collection_teamworkers
      collection_topic_selected_replies
      collection_topics
    ].each { |table| expect(column_in(table, "collection_id")["fkey_info"]).to eq(:collections) }
  end

  it "keeps the foreign keys Data Explorer already resolved from column names" do
    expect(column_in("collection_topics", "topic_id")["fkey_info"]).to eq(:topics)
    expect(column_in("collection_teamworkers", "user_id")["fkey_info"]).to eq(:users)
    expect(column_in("collection_topic_selected_replies", "post_id")["fkey_info"]).to eq(:posts)
    expect(column_in("collection_invites", "inviter_user_id")["fkey_info"]).to eq(:users)
    expect(column_in("collection_invites", "invitee_user_id")["fkey_info"]).to eq(:users)
  end

  it "adds the action_type enum, taken from the model constants" do
    expect(column_in("collection_invites", "action_type")["enum"]).to eq(
      DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER => :maintainer,
      DiscourseCollection::CollectionInvite::ACTION_TYPE_OWNER => :owner,
    )
  end

  it "adds no enum elsewhere" do
    expect(column_in("collections", "name")).not_to have_key("enum")
    expect(column_in("collection_invites", "accept")).not_to have_key("enum")
  end

  it "leaves tables outside the plugin untouched" do
    expect(column_in("posts", "topic_id")).to eq(
      "column_name" => "topic_id",
      "data_type" => "integer",
      "fkey_info" => :topics,
    )
  end

  it "is idempotent, the schema hash being memoized and shared" do
    first_pass = Marshal.load(Marshal.dump(schema))

    described_class.decorate!(schema)

    expect(schema).to eq(first_pass)
  end

  it "returns the schema it was handed, and tolerates a nil one" do
    expect(described_class.decorate!(schema)).to equal(schema)
    expect(described_class.decorate!(nil)).to be_nil
  end

  describe "DataExplorerSchema::Patch" do
    it "annotates whatever schema builder it is prepended onto" do
      builder = Class.new do
        def self.schema
          { "collection_topics" => [{ "column_name" => "collection_id" }] }
        end
      end
      builder.singleton_class.prepend(described_class::Patch)

      expect(builder.schema["collection_topics"].first["fkey_info"]).to eq(:collections)
    end

    it "swallows a failure of its own step rather than taking the schema down" do
      allow(described_class).to receive(:decorate!).and_raise("boom")
      allow(Discourse).to receive(:warn_exception)
      builder = Class.new do
        def self.schema
          { "collections" => [] }
        end
      end
      builder.singleton_class.prepend(described_class::Patch)

      expect(builder.schema).to eq("collections" => [])
      expect(Discourse).to have_received(:warn_exception)
    end
  end
end
