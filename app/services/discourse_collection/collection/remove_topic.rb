# frozen_string_literal: true

module DiscourseCollection
  # docs/04 §5 DELETE /collections/:id/topics/:topic_id.json — remove a topic from a collection.
  #
  # One transaction: the collection must exist and the actor must be its owner or a
  # co-maintainer; the (collection, topic) membership must exist (else 422, non-idempotent
  # — there is nothing to remove). Removing deletes the membership row AND every
  # featured-reply row for that (collection, topic), then maintains the collection counters:
  # topic_count -1 (floor 0), last_topic_added_at recomputed to the newest remaining
  # created_at (NULL when the collection becomes empty) and updated_at = now (docs/08).
  # The remove sends nothing and touches no notification state (docs/04 §5, docs/09 §2):
  # each 21075 run is judged against the collect that opened it, so un-collecting a topic
  # neither silences nor clears the notification that collect produced.
  class Collection::RemoveTopic
    include Service::Base

    params do
      attribute :id, :integer
      attribute :topic_id, :integer

      validates :id, :topic_id, presence: true
    end

    model :collection
    policy :can_write_topics

    transaction do
      step :ensure_topic_is_included
      step :destroy_topic_membership
    end

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def can_write_topics(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).can_write_topics?
    end

    def ensure_topic_is_included(collection:, params:)
      unless CollectionTopic.exists?(collection_id: collection.id, topic_id: params.topic_id)
        fail!(I18n.t("discourse_collection.errors.topic_not_in_collection"))
      end
    end

    def destroy_topic_membership(collection:, params:)
      CollectionTopic.find_by!(collection_id: collection.id, topic_id: params.topic_id).destroy!

      # A topic being removed takes its featured-reply records with it. There is no
      # DB-level cascade from collection_topics to collection_topic_selected_replies,
      # so the rows are deleted here in the same transaction (docs/04 §5/docs/08).
      CollectionTopicSelectedReply
        .where(collection_id: collection.id, topic_id: params.topic_id)
        .delete_all

      Collection.recompute_topic_count_and_activity!(collection)
    end
  end
end
