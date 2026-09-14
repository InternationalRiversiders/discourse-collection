# frozen_string_literal: true

module DiscourseCollection
  # Data Explorer renders a result cell by relation type: `relation_for` maps a column
  # name to a type, and `extra_data_pluck_fields` says how that type is looked up and
  # serialized. Both are hardcoded to core's conventions — the only automatic mapping
  # is a regex derived from the model's class name — so `collection_id` comes out as a
  # bare number. Neither offers plugins a registration point, hence the patch below.
  #
  # The derived regex is the part that would have to work, and for a namespaced model it
  # reads `/discourse_collection\/collection_id$/` — which never matches a plain
  # `collection_id` column. Claim the column outright instead — the same move the schema
  # annotations make for the composite keys it cannot recognize by name.
  #
  # Once claimed, any query returning a `collection_id` shows that collection's name,
  # and the frontend links it to the collection's page. The Markdown share reads the
  # same relation, labelling the row with the first of `name` / `title` / `username`.
  module DataExplorerRelations
    # What `add_extra_data` needs in order to fetch a collection and hand it over:
    # `:class` to query, `:fields` to select, `:only` to serialize. Without a
    # serializer the payload is exactly the two columns a cell needs, which is the
    # shape core's own `tag_group` entry takes.
    COLLECTION = { class: Collection, fields: %i[id name], only: %i[id name] }.freeze

    # Prepended onto DataExplorer's singleton class. `relation_for` is asked first and
    # its answer decides both the lookup above and the frontend component, so claiming
    # the column is all there is to it. Answering before `super` also leaves the `html$`
    # prefix — SQL's own escape hatch — winning over it, which it must: a query asking
    # for its own markup gets its own markup.
    module Patch
      def relation_for(col)
        return :collection if col == "collection_id"

        super
      end
    end

    # `extra_data_pluck_fields` is a plain memoized hash and `relation_for` a class
    # method, so both are mutated in place. The `@column_regexes` memo alongside them is
    # derived from the hash and is deliberately left alone: it is what we are routing
    # around, not something the entry has to be reflected in.
    def self.register!(explorer)
      explorer.extra_data_pluck_fields[:collection] = COLLECTION
      explorer.singleton_class.prepend(Patch)
    end
  end
end
