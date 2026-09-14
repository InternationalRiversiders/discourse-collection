# frozen_string_literal: true

RSpec.describe DiscourseCollection::DataExplorerRelations do
  describe ".register!" do
    it "records how Data Explorer should look a collection up" do
      explorer = Class.new do
        def self.extra_data_pluck_fields
          @extra_data_pluck_fields ||= {}
        end
      end

      described_class.register!(explorer)

      expect(explorer.extra_data_pluck_fields[:collection]).to eq(
        class: DiscourseCollection::Collection,
        fields: %i[id name],
        only: %i[id name],
      )
    end
  end

  # A stand-in for Data Explorer's own dispatch, including the `html$` prefix it reads
  # off the column before consulting the regexes.
  describe "DataExplorerRelations::Patch" do
    let(:builder) do
      Class.new do
        def self.relation_for(col)
          return :html if col.start_with?("html$")

          { "topic_id" => :topic, "user_id" => :user }[col]
        end
      end
    end

    before { builder.singleton_class.prepend(described_class::Patch) }

    it "claims the collection_id column" do
      expect(builder.relation_for("collection_id")).to eq(:collection)
    end

    it "leaves every other column to Data Explorer" do
      expect(builder.relation_for("topic_id")).to eq(:topic)
      expect(builder.relation_for("user_id")).to eq(:user)
      expect(builder.relation_for("collection_topics.id")).to be_nil
    end

    it "does not claim a column the $ prefix already claimed" do
      expect(builder.relation_for("html$collection_id")).to eq(:html)
    end
  end

  # The wiring the two blocks above stand in for: at boot the plugin registers itself on
  # the real Data Explorer, so a query naming the column needs nothing else from the
  # admin to get the names back.
  it "resolves the collection behind every collection_id value of a result" do
    collection = Fabricate(:collection, name: "Reading list")
    query = Fabricate(:query, sql: "SELECT #{collection.id} AS collection_id")
    pg_result = DiscourseDataExplorer::DataExplorer.run_query(query)[:pg_result]

    relations, colrender =
      DiscourseDataExplorer::DataExplorer.add_extra_data(pg_result, guardian: nil)

    expect(colrender).to eq({ 0 => :collection })
    expect(relations[:collection].as_json).to contain_exactly(
      { "id" => collection.id, "name" => "Reading list" },
    )
  end
end
