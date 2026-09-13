# frozen_string_literal: true

module DiscourseCollection
  class CollectionTopic < ActiveRecord::Base
    self.table_name = "collection_topics"

    belongs_to :collection, class_name: "DiscourseCollection::Collection"
    belongs_to :topic

    # Fixed cap on `note` — set by the DB VARCHAR(100) column, not a site setting
    # (docs/11 §2). Shared by every note-writing path (docs/04 §3 add, docs/04 §4 PATCH,
    # docs/06 §1 staff rewrite) so the limit lives in exactly one place.
    NOTE_MAX_LENGTH = 100

    # Returns an error message when +note+ would exceed the DB column width (nil when
    # blank or within the limit). Contracts add it to :base so the DB never raises a
    # 500 on an over-long note. The note is measured as the text that gets stored: the
    # untyped contracts (docs/04 §4 / docs/06 §1) can hand over a non-String (a JSON number / boolean),
    # which is stringified here so the length check never raises on it.
    def self.note_length_error(note)
      text = note.to_s
      return nil if text.blank? || text.length <= NOTE_MAX_LENGTH

      I18n.t("discourse_collection.errors.note_too_long", max: NOTE_MAX_LENGTH)
    end

    # Topic-page reverse lookup, topic level (docs/07): the collections that collect
    # +topic_id+, each just { id:, name: } — this array doubles as the name table the
    # post-level `selected_by_collection_ids` resolves against (featured ⊂ collected,
    # so every featured collection id is present here). Visitor-independent: reaching
    # /t/:id already proves the topic is visible and collections are public, so no Guardian
    # filtering. One indexed (topic_id, collection_id) hit, ordered by id for stable
    # output. Collections are hard-deleted (memberships cascade), so no deleted_at filter.
    def self.collecting_collections_for_topic(topic_id)
      joins(:collection)
        .where(topic_id:)
        .order("collection_topics.collection_id ASC")
        .pluck("collection_topics.collection_id", "collections.name")
        .map { |id, name| { id:, name: } }
    end
  end
end

# == Schema Information
#
# Table name: collection_topics
#
#  has_selected_reply :boolean          default(FALSE), not null
#  note               :string(100)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  collection_id      :integer          not null, primary key
#  topic_id           :integer          not null, primary key
#
# Indexes
#
#  index_collection_topics_on_collection_id_and_created_at  (collection_id,created_at)
#  index_collection_topics_on_topic_id_and_collection_id    (topic_id,collection_id)
#
# Foreign Keys
#
#  collection_topics_collection_id_fkey  (collection_id => collections.id) ON DELETE => cascade
#  collection_topics_topic_id_fkey       (topic_id => topics.id) ON DELETE => cascade
#