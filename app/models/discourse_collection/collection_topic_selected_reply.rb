# frozen_string_literal: true

module DiscourseCollection
  class CollectionTopicSelectedReply < ActiveRecord::Base
    self.table_name = "collection_topic_selected_replies"

    belongs_to :collection, class_name: "DiscourseCollection::Collection"
    belongs_to :topic
    belongs_to :post

    # topic_id => [[post_id, created_at], …] (post_id ASC), at most limit+1 per topic —
    # the inline reading-page window (docs/04 §1). docs/04 §2 allows a per-topic "take
    # N+1 and merge" over a single partitioned ROW_NUMBER query; each probe is an
    # indexed (collection_id, topic_id) hit capped at limit+1, so a page's flagged
    # topics (≤ page_size) cost at most that many tiny queries and never rewind the
    # full list. The extra row beyond `limit` only decides `has_more_selected_replies`
    # and is never returned by the caller. created_at is the selected-reply row's own
    # creation time (= the moment it was selected).
    def self.windowed_post_ids_by_topic(collection_id, topic_ids, limit:)
      return {} if topic_ids.empty?

      topic_ids.each_with_object({}) do |topic_id, map|
        pairs =
          where(collection_id:, topic_id:)
            .order("post_id ASC")
            .limit(limit + 1)
            .pluck(:post_id, :created_at)
        map[topic_id] = pairs unless pairs.empty?
      end
    end

    # Topic-page reverse lookup, post level (docs/07): post_id => [collection_ids]
    # for every post of +topic_id+ featured by at least one collection. Scoped to the
    # +collection_ids+ that collect the topic: one indexed (collection_id, topic_id)
    # probe per collecting collection, and every id that comes back is one the
    # topic-level list also reports, so the frontend can always resolve its name. Rows
    # for deleted/hidden posts are harmless: the injector only fires on posts the
    # serializer actually serializes. Ordered by collection id so each post's id array
    # is stable.
    def self.selected_collection_ids_by_post(topic_id, collection_ids:)
      return {} if collection_ids.empty?

      where(collection_id: collection_ids, topic_id:)
        .order("collection_id ASC")
        .pluck(:post_id, :collection_id)
        .each_with_object({}) do |(post_id, collection_id), map|
          (map[post_id] ||= []) << collection_id
        end
    end
  end
end

# == Schema Information
#
# Table name: collection_topic_selected_replies
#
#  created_at    :datetime         not null
#  collection_id :integer          not null, primary key
#  post_id       :integer          not null, primary key
#  topic_id      :integer          not null
#
# Indexes
#
#  index_collection_topic_selected_replies_on_collection_id_and_to  (collection_id,topic_id)
#
# Foreign Keys
#
#  collection_topic_selected_replies_collection_id_fkey  (collection_id => collections.id) ON DELETE => cascade
#  collection_topic_selected_replies_post_id_fkey        (post_id => posts.id) ON DELETE => cascade
#  collection_topic_selected_replies_topic_id_fkey       (topic_id => topics.id) ON DELETE => cascade
#