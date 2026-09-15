# frozen_string_literal: true

module DiscourseCollection
  # docs/06 §1 PUT /collections/:id/topics/:topic_id/note.json — staff overwrite of one
  # collected topic's note on ANY collection (someone else's, or an ownerless one), for
  # content a staff member judges non-compliant (docs/06 §1). Unlike the collection
  # management ops it is not gated by collection_moderators_can_manage_collections —
  # admin and moderator both always hold it (CollectionPolicy#staff?).
  #
  # Only `note` is replaced: a value replaces the whole note, null clears it (the
  # same NOTE_NOT_GIVEN tri-state as docs/04 §4, so an absent key is a no-op). It touches
  # collection.updated_at but never has_selected_reply / featured rows /
  # last_topic_added_at / topic_count. The membership must exist and the topic must
  # be visible to the actor (both 404), mirroring the add-topic visibility guard.
  class Collection::RewriteTopicNote
    include Service::Base

    NOTE_NOT_GIVEN = Object.new.freeze

    params do
      attribute :id, :integer
      attribute :topic_id, :integer
      attribute :note, default: NOTE_NOT_GIVEN

      validates :id, :topic_id, presence: true

      validate :note_is_within_limit

      private

      def note_is_within_limit
        return if note.equal?(NOTE_NOT_GIVEN)

        error = DiscourseCollection::CollectionTopic.note_length_error(note)
        errors.add(:base, error) if error
      end
    end

    model :collection
    model :membership, :fetch_membership
    model :topic, :fetch_visible_topic
    policy :staff

    transaction do
      step :rewrite_note
      step :touch_activity
    end
    # Post-transaction (docs/10 / docs/06 §1): an overwrite made on staff standing is logged —
    # the actor here is always staff (policy :staff), but one who owns or co-maintains the
    # collection already holds the same edit through docs/04 §4, so theirs is routine
    # management and goes unlogged. The no-key request is a pure no-op that writes nothing,
    # so nothing is logged for it.
    step :audit_note_change

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def fetch_membership(collection:, params:)
      CollectionTopic.find_by(collection_id: collection.id, topic_id: params.topic_id)
    end

    # The topic must exist and be visible to the acting staff member (docs/06 §1:
    # "该 (collection, topic) 收录必须存在且当前用户能见该 topic…否则 404"); invisible
    # => nil => model not found => 404, no existence leak.
    def fetch_visible_topic(params:, guardian:)
      topic = Topic.find_by(id: params.topic_id)
      topic if topic.present? && guardian.can_see_topic?(topic)
    end

    def staff(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).staff?
    end

    def rewrite_note(membership:, params:)
      return if params.note.equal?(NOTE_NOT_GIVEN)

      # Snapshot the note about to be replaced for the post-transaction audit step.
      context[:previous_note] = membership.note
      # Non-String values are stored as text (see CollectionTopic.note_length_error).
      membership.update!(note: params.note.presence&.to_s)
    end

    def touch_activity(collection:, params:)
      return if params.note.equal?(NOTE_NOT_GIVEN)

      collection.update!(updated_at: Time.zone.now)
    end

    # docs/10 §1: an overwrite is an admin action unless the actor already holds the note
    # edit as the collection's owner or co-maintainer (docs/04 §4) — then it is routine
    # management and is not logged. new_value mirrors the stored note — an explicit null
    # clears it to nil ("旧 → 空"), so the audit row records old note -> nil.
    def audit_note_change(collection:, membership:, params:, guardian:)
      return if params.note.equal?(NOTE_NOT_GIVEN)
      return if CollectionPolicy.for(collection:, user: guardian.user).can_write_topics?

      StaffActionLogger.new(guardian.user).log_custom(
        :collection_topic_note_change,
        subject: "Collection (#{collection.id})",
        context: collection.name,
        previous_value: context[:previous_note],
        new_value: membership.note,
      )
    end
  end
end
