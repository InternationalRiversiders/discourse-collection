# frozen_string_literal: true

# name: discourse-collection
# about: Public collections: signed-in users create topic collections, co-maintain them, feature selected replies, and subscribe to updates.
# version: 0.1.0
# authors: 0x444858

enabled_site_setting :collection_enabled

register_asset "stylesheets/collections.scss"

module ::DiscourseCollection
  PLUGIN_NAME = "discourse-collection"
end

# The four custom notification types (21075-21078) are defined in docs/09 §1.
# Core's Notification.types is a plain, unfrozen Enum<Hash, so a plugin can append
# its own entries in after_initialize and they flow to the site + frontend untouched.
after_initialize do
  Notification.types[:collection_topic_added] = 21075
  Notification.types[:collection_invitation] = 21076
  Notification.types[:collection_invitation_accepted] = 21077
  Notification.types[:collection_invitation_declined] = 21078
end

# The five staff-action audit types (docs/10) are appended to
# UserHistory.staff_actions so the admin staff-action log offers a per-action filter
# row for each (the symbol being in the array is the drop-down sub-filter switch).
# Core's staff_actions is a memoized plain array, so append the ones not yet present —
# a re-loaded process must never double-add.
after_initialize do
  audit_types = %i[
    collection_name_change
    collection_intro_change
    collection_topic_note_change
    collection_owner_change
    collection_invite_revoke
  ]
  UserHistory.staff_actions.concat(audit_types - UserHistory.staff_actions)
end

# Topic-page reverse lookup (docs/07) — two-level minimal back-reference injected
# onto the core /t/:id.json endpoint. Registered through the canonical TopicView
# preload + serializer hooks (the same shape discourse-events uses for its calendar
# cards): one TopicView construction computes both lookups exactly once into the
# preloaded store, then the topic-level serializer and every PostSerializer read the
# shared store — never a per-post query. Respects collection_enabled (queries gated
# here, injection gated again by respect_plugin_enabled on the attributes).
after_initialize do
  TopicView.on_preload do |topic_view|
    next unless SiteSetting.collection_enabled

    topic_id = topic_view.topic.id
    memberships = DiscourseCollection::CollectionTopic.collecting_collections_for_topic(topic_id)

    topic_view.set_preloaded_post_data(:discourse_collection_memberships, memberships)
    topic_view.set_preloaded_post_data(
      :discourse_collection_selected,
      if memberships.present?
        DiscourseCollection::CollectionTopicSelectedReply.selected_collection_ids_by_post(
          topic_id,
          collection_ids: memberships.map { |membership| membership[:id] },
        )
      else
        {}
      end,
    )
  end

  # Topic level: top-level `collections` (id+name only), present only when the topic
  # is collected by ≥1 collection. Doubles as the name table for the post-level ids.
  add_to_serializer(
    :topic_view,
    :collections,
    respect_plugin_enabled: true,
    include_condition: -> { object.preloaded_post_data(:discourse_collection_memberships).present? },
  ) { object.preloaded_post_data(:discourse_collection_memberships) }

  # Post level: `selected_by_collection_ids` on every post some collection features — the
  # key is omitted when a post has none (most posts). Only ever reads the shared
  # store, so outside a topic view (topic_view nil) nothing is injected; ids decode
  # against the topic-level `collections` name table.
  add_to_serializer(
    :post,
    :selected_by_collection_ids,
    respect_plugin_enabled: true,
    include_condition: -> { selected_by_collection_ids.present? },
  ) do
    @selected_by_collection_ids ||=
      begin
        preloaded = topic_view&.preloaded_post_data(:discourse_collection_selected)
        preloaded ? preloaded[object.id] || [] : []
      end
  end
end

# Data Explorer (core's /admin/plugins/discourse-data-explorer) derives its column
# metadata in Ruby with naming heuristics that only understand core's conventions, and
# offers plugins no registration point, so annotate our tables by patching its schema
# builder (lib/discourse_collection/data_explorer_schema.rb argues why the catalog,
# rather than a hardcoded list, is the source). Hooked here rather than on the
# DiscourseEvent :after_plugin_activation, which fires while config/application.rb is
# still being evaluated — before Rails sets up autoloading, and therefore before
# DiscourseDataExplorer::DataExplorer is reachable. Blocks registered below run from
# config.after_initialize, once every plugin is activated and every constant loadable.
# The plugin can also be absent, hence the defined? guard.
after_initialize do
  if defined?(DiscourseDataExplorer::DataExplorer)
    DiscourseDataExplorer::DataExplorer.singleton_class.prepend(
      DiscourseCollection::DataExplorerSchema::Patch,
    )
  end
end

require_relative "lib/discourse_collection/engine"
