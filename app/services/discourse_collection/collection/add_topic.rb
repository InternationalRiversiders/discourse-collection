# frozen_string_literal: true

module DiscourseCollection
  # docs/04 §3 POST /collections/:id/topics.json — collect a topic into a collection.
  #
  # One transaction: the collection must exist and the actor must be its owner or a
  # co-maintainer; the topic must exist and be visible to the actor (an invisible or
  # missing topic is a 404 — no existence leak, docs/04 §3). Private-message topics
  # (archetype=private_message) can never be collected: a PM the actor can see
  # (staff or a participant) is rejected as a business rule (422); an outsider
  # probing an invisible PM is stopped by the fetch's 404 first. An already-collected
  # topic is an idempotent no-op 200. A fresh collect inserts one collection_topics
  # row (has_selected_reply stays false), bumps topic_count / last_topic_added_at and
  # touches updated_at (docs/08). Collecting is capped by
  # collection_max_topics_per_collection; the note is length-guarded (≤100) so the DB
  # column never raises. A fresh collect stamps the 21075 batch with the row it inserted and
  # schedules its flush from a post-transaction step, so subscribers eventually learn about
  # the new topic; the idempotent re-collect neither opens a batch nor restarts the window
  # (docs/09 §2).
  class Collection::AddTopic
    include Service::Base

    params do
      attribute :id, :integer
      attribute :topic_id, :integer
      attribute :note, :string

      validates :id, :topic_id, presence: true

      validate :note_is_within_limit

      private

      def note_is_within_limit
        error = DiscourseCollection::CollectionTopic.note_length_error(note)
        errors.add(:base, error) if error
      end
    end

    model :collection
    model :topic, :fetch_visible_topic
    policy :can_write_topics

    transaction do
      step :ensure_topic_is_not_a_private_message
      step :add_topic
    end
    # Post-transaction: only runs when the transaction committed. The no-op re-collect
    # path sets no context flag, so it never reaches this step.
    step :register_topic_added_notification

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    # A topic the actor may actually see; otherwise nil => model not found => 404
    # (same wire behavior as a missing topic).
    def fetch_visible_topic(params:, guardian:)
      topic = Topic.find_by(id: params.topic_id)
      topic if topic.present? && guardian.can_see_topic?(topic)
    end

    def can_write_topics(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).can_write_topics?
    end

    # A private-message topic must never become public collection content. The actor
    # only reaches this step when they can actually see the PM (staff or a
    # participant) — the invisible-PM case already 404'd in fetch_visible_topic — so
    # this is a business-rule 422, not another 404 (docs/04 §3).
    def ensure_topic_is_not_a_private_message(topic:)
      return unless topic.private_message?

      fail!(I18n.t("discourse_collection.errors.private_message_topic_not_allowed"))
    end

    def add_topic(collection:, topic:, params:)
      # Already collected -> idempotent no-op (no recount, docs/04 §3).
      if CollectionTopic.exists?(collection_id: collection.id, topic_id: topic.id)
        return
      end

      if CollectionTopic.where(collection_id: collection.id).count >=
           SiteSetting.collection_max_topics_per_collection
        fail!(
          I18n.t(
            "discourse_collection.errors.topic_limit_reached",
            max: SiteSetting.collection_max_topics_per_collection,
          ),
        )
        return
      end

      CollectionTopic.create!(
        collection_id: collection.id,
        topic_id: topic.id,
        note: params.note.presence,
      )
      Collection.bump_topic_count_and_activity!(collection)
      context[:topic_collected] = true
    end

    # 21075 collection_topic_added (docs/09 §2): the collect schedules a flushed batch one
    # silence window out, stamped with the row it inserted — collecting again inside the
    # window schedules another run stamped later, and only the run whose stamp is still the
    # newest row sends. The batch carries locators only; who receives what (the actor
    # excluded, and the ignore rule) is resolved live by the job.
    def register_topic_added_notification(collection:, topic:, guardian:)
      return unless context[:topic_collected]

      TopicAddedNotificationBatch.register!(
        collection: collection,
        actor_user_id: guardian.user.id,
        topic: topic,
      )
    end
  end
end
