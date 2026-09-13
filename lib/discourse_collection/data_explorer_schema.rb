# frozen_string_literal: true

module DiscourseCollection
  # Data Explorer (core's /admin/plugins/discourse-data-explorer) computes its column
  # metadata in Ruby and ships it to the admin UI as JSON; the UI merely paints what it
  # is handed. Two of those derivations are naming heuristics that only understand
  # core's own conventions, so our tables come out wrong there:
  #
  #   primary key  — recognized by `column_name == "id"` alone, which the four
  #                  composite-key join tables (hard rule 1) do not have, so their key
  #                  shows as none at all;
  #   foreign key  — guessed from the column name (its default table list covers
  #                  user_id/topic_id/post_id/etc, a regex covers `*_user_id`) plus a
  #                  core-only special-case hash, none of which knows `collection_id`.
  #
  # Data Explorer can afford to guess because core almost never declares a real foreign
  # key (about 29 of 1600+ `*_id` columns), which is precisely why it never consults
  # pg_constraint. We deliberately deviate from that convention (hard rule 2: every
  # relation is an inline REFERENCES), so for our tables the catalog is exact — read it
  # rather than mirror the schema into a hardcoded list that nothing keeps in sync.
  module DataExplorerSchema
    TABLES = %w[
      collection_invites
      collection_subscribers
      collection_teamworkers
      collection_topic_selected_replies
      collection_topics
      collections
    ].freeze

    # Values Data Explorer cannot know: they live in application code, not in the
    # database (docs/05 §2). Already in its value => name direction, the one it
    # derives from model enums.
    ENUMS = {
      "collection_invites.action_type" => {
        CollectionInvite::ACTION_TYPE_MAINTAINER => :maintainer,
        CollectionInvite::ACTION_TYPE_OWNER => :owner,
      },
    }.freeze

    # Prepended onto DataExplorer's singleton class, so our annotations ride along with
    # the schema hash it already builds and memoizes. A failure here must not take the
    # schema endpoint down with it, hence the containment — wrapped around our own step
    # only, so a genuine Data Explorer error still surfaces.
    module Patch
      def schema
        result = super
        begin
          DiscourseCollection::DataExplorerSchema.decorate!(result)
        rescue StandardError => e
          Discourse.warn_exception(
            e,
            message: "discourse-collection: could not annotate the Data Explorer schema",
          )
        end
        result
      end
    end

    # Fills in only what the heuristics missed, in place: a column that already carries
    # the attribute keeps whatever Data Explorer worked out (user_id, topic_id and
    # post_id all resolve correctly there today). Idempotent — the schema hash is
    # memoized per process and handed to every caller, so this runs again on each call.
    def self.decorate!(schema)
      return schema if schema.blank?

      primary_columns, foreign_keys = catalog

      schema.each do |table, columns|
        next unless TABLES.include?(table)

        primary = primary_columns[table]

        columns.each do |column|
          name = column["column_name"]

          if primary&.include?(name) && !column["primary"]
            column["primary"] = true
          end

          foreign_key = foreign_keys["#{table}.#{name}"]
          if foreign_key && !column["fkey_info"]
            column["fkey_info"] = foreign_key
          end

          enum = ENUMS["#{table}.#{name}"]
          column["enum"] = enum if enum && !column["enum"]
        end
      end

      schema
    end

    # The real primary key and foreign key constraints of our tables, straight from the
    # catalog. Memoized per process: a migration needs a server restart for Data
    # Explorer's own schema hash to refresh anyway, so this may as well match it.
    def self.catalog
      return @catalog if defined?(@catalog)

      primary_columns = {}
      foreign_keys = {}

      DB.query_hash(<<~SQL).each do |row|
        SELECT t.relname AS table_name,
               a.attname AS column_name,
               c.contype AS contype,
               f.relname AS foreign_table
        FROM pg_constraint c
        INNER JOIN pg_class t ON t.oid = c.conrelid
        INNER JOIN pg_namespace n ON n.oid = t.relnamespace
        INNER JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        LEFT JOIN pg_class f ON f.oid = c.confrelid
        WHERE n.nspname = 'public' AND c.contype IN ('p', 'f')
      SQL
        table = row["table_name"]
        next unless TABLES.include?(table)

        column = row["column_name"]
        if row["contype"] == "p"
          (primary_columns[table] ||= []) << column
        else
          foreign_keys["#{table}.#{column}"] = row["foreign_table"].to_sym
        end
      end

      @catalog = [primary_columns, foreign_keys]
    end
  end
end
