# frozen_string_literal: true

module DiscourseCollection
  # The identity behind the 21075 collect notification (docs/09 §2).
  #
  # A fresh docs/04 §3 collect does not notify immediately: it schedules NotifyTopicAdded to fire
  # one silence window later, carrying a stamp — the created_at of the membership row that
  # collect just inserted. A further collect schedules another run stamped with the row it
  # inserts, so a burst keeps pushing the deadline out and only its last run can send.
  #
  # A run sends only while its stamp is still the created_at of the collection's newest
  # membership row, re-read when it fires. That single comparison covers every way a run
  # can be overtaken, so nothing has to be tracked or cleared:
  #   - a later collect added a newer row — that collect's run is the one that sends;
  #   - the topic that opened the run was un-collected (docs/04 §5), leaving an older row newest —
  #     the run stands down. Undoing a collect undoes the notification it would have sent,
  #     which is the intent: a collect taken straight back is a misclick;
  #   - some older topic was un-collected instead — the newest row is untouched, so the run
  #     stands and sends. Un-collecting a topic the collector did not just add is no reason
  #     to keep the rest of the burst quiet.
  #
  # The only other state is one PluginStore row per collection, holding the last stamp sent;
  # it exists solely to keep a Sidekiq retry — this job re-queued after a crash mid-send —
  # from notifying everybody twice.
  class TopicAddedNotificationBatch
    # How long after the last collect of a burst the batch is flushed.
    SILENCE_WINDOW = 1.minute

    class << self
      # Schedules the flush of a fresh collect (docs/09 §2). Called only for a collect that
      # actually inserted a row — an idempotent re-collect neither opens a batch nor
      # restarts the window. Returns the stamp the scheduled run is checked against, or nil
      # when the row is already gone (a concurrent remove undid the collect).
      def register!(collection:, actor_user_id:, topic:)
        stamp = stamp_of(collection.id, topic.id)
        return if stamp.nil?

        ::Jobs.enqueue_in(
          SILENCE_WINDOW,
          ::Jobs::DiscourseCollection::NotifyTopicAdded,
          collection_id: collection.id,
          stamp: stamp,
          actor_user_id: actor_user_id,
          topic_author_id: topic.user_id,
        )

        stamp
      end

      # Whether the stamp still belongs to the collection's newest membership row. Read live
      # when the run fires, so the recipients are resolved against the collection as it
      # stands then rather than as it stood when the collect happened.
      def current?(collection_id, stamp)
        stamp.present? && stamp == newest_stamp(collection_id)
      end

      # Records that the batch stamped +stamp+ has been sent: true for the first run to
      # claim it, false for a re-delivered one.
      def claim!(collection_id, stamp)
        return false if store.get(key(collection_id)) == stamp

        store.set(key(collection_id), stamp)
        true
      end

      private

      # Stamps are compared as strings, rounded to the microsecond the timestamp column is
      # stored with, so that values read back at different moments are comparable verbatim.
      def stamp_of(collection_id, topic_id)
        CollectionTopic.find_by(collection_id:, topic_id:)&.created_at&.utc&.iso8601(6)
      end

      def newest_stamp(collection_id)
        CollectionTopic.where(collection_id:).maximum(:created_at)&.utc&.iso8601(6)
      end

      def store
        PluginStore.new(::DiscourseCollection::PLUGIN_NAME)
      end

      def key(collection_id)
        "topic_added_notification/#{collection_id}"
      end
    end
  end
end
