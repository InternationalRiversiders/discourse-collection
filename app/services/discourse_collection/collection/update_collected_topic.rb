# frozen_string_literal: true

module DiscourseCollection
  # docs/04 §4 PATCH /collections/:id/topics/:topic_id.json — edit one collected topic
  # (its note and/or its featured replies) in a single partial write (docs/04 §4).
  #
  # The body is partial: only the fields the caller wants to change are sent.
  # `note` is tri-state — a value replaces the note, null clears it, an absent key
  # leaves it alone. Because an untyped contract attribute passes both null and a
  # real string through untouched, the frozen NOTE_NOT_GIVEN sentinel tells "absent"
  # apart from "explicit null/empty". `selected_replies.add` / `.remove` are
  # idempotent incremental lists (never echoed back in full); a post_id may not
  # appear in both lists (422). The two lists are guarded differently (docs/04 §4):
  # an **add** post must exist and belong to the collected topic (else 404 — no
  # existence leak, same as AddTopic's invisible-topic 404); a **remove** only deletes
  # whatever featured-reply rows already exist for this (collection, topic) and never
  # re-checks that the post is still alive — so a reply whose post was soft-deleted
  # can still be unfeatured, and a remove with no matching row is a plain no-op.
  # Only regular human replies can be featured (docs/04 §4): the topic's first post
  # (post_number 1, the OP) and any non-regular post (post_type != regular — the
  # system/moderator small-action event rows, whispers, legacy moderator posts)
  # are rejected as business-rule 422s, unlike the belongs-to-topic 404.
  # Both are kept as plain untyped attributes so the lists survive with whatever key
  # style the request carried (string keys from real JSON, symbol keys from direct
  # spec hashes).
  #
  # One transaction: the membership must already exist (else 404 via the model),
  # the actor must be owner or co-maintainer, then the note is replaced, the
  # selected-reply rows are inserted/deleted, has_selected_reply is recomputed to
  # whether any row remains, and collection.updated_at is bumped — never
  # last_topic_added_at / topic_count (docs/08). An empty body {} is a pure
  # no-op: nothing is written and updated_at is not bumped; the current row is
  # returned as-is.
  class Collection::UpdateCollectedTopic
    include Service::Base

    # Absent-`note` marker: distinct from any real value AND from an explicit null.
    NOTE_NOT_GIVEN = Object.new.freeze

    params do
      attribute :id, :integer
      attribute :topic_id, :integer
      attribute :note, default: NOTE_NOT_GIVEN
      attribute :selected_replies, default: -> { {} }

      validates :id, :topic_id, presence: true

      validate :note_is_within_limit
      validate :selected_replies_do_not_overlap

      private

      def note_is_within_limit
        return if note.equal?(NOTE_NOT_GIVEN)

        error = DiscourseCollection::CollectionTopic.note_length_error(note)
        errors.add(:base, error) if error
      end

      # A post cannot be featured and unfeatured in the same request (docs/04 §4).
      def selected_replies_do_not_overlap
        add_ids = selected_reply_ids_for(:add)
        remove_ids = selected_reply_ids_for(:remove)
        return if (add_ids & remove_ids).empty?

        errors.add(
          :base,
          I18n.t("discourse_collection.errors.selected_replies_add_remove_overlap"),
        )
      end

      def selected_reply_ids_for(key)
        list = selected_reply_list(selected_replies, key)
        # to_s first: a JSON null / object element must not raise on a bare to_i.
        list.map { |id| id.to_s.to_i }.uniq
      end

      def selected_reply_list(value, key)
        return [] unless value.is_a?(Hash)

        list = value[key] || value[key.to_s]
        list.is_a?(Array) ? list : []
      end
    end

    model :collection
    model :membership, :fetch_membership
    policy :can_write_topics

    transaction do
      step :ensure_added_replies_belong_to_topic
      step :ensure_added_replies_are_featureable
      step :write_note
      step :edit_selected_replies
      step :touch_activity
    end

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    # The collected-topic row itself; a missing one is a 404 (docs/04 §4: "该 topic
    # 已收录…否则 404"), not the 422 that RemoveTopic uses for its non-idempotent delete.
    def fetch_membership(collection:, params:)
      CollectionTopic.find_by(collection_id: collection.id, topic_id: params.topic_id)
    end

    def can_write_topics(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).can_write_topics?
    end

    def selected_reply_ids(params, key)
      # to_s first keeps a JSON null / object element from raising on to_i; anything
      # non-numeric collapses to 0 — as an add it fails the belongs-to-topic 404 check,
      # as a remove it is an idempotent no-op (no featured row can carry post_id 0).
      selected_reply_list(params.selected_replies, key).map { |id| id.to_s.to_i }.uniq
    end

    def selected_reply_list(value, key)
      return [] unless value.is_a?(Hash)

      list = value[key] || value[key.to_s]
      list.is_a?(Array) ? list : []
    end

    # Only the posts being ADDED must exist (Post.where drops soft-deleted rows via
    # the Trashable default scope) and belong to this topic; anything else is treated
    # as not-found (404), so a client can never probe which posts belong elsewhere.
    # Remove ids are NOT validated here: they only name featured-reply rows to delete,
    # and a soft-deleted post's featured row must stay removable (docs/04 §4).
    def ensure_added_replies_belong_to_topic(membership:, params:)
      ids = selected_reply_ids(params, :add)
      return if ids.empty?

      posts = Post.where(id: ids).pluck(:id, :topic_id).to_h
      return if ids.all? { |id| posts[id] == membership.topic_id }

      fail!("post_does_not_belong_to_topic")
    end

    # A featured "reply" must be a real human reply, never topic scaffolding or a
    # staff-only row (docs/04 §4): the first post (post_number 1, the OP) and any
    # non-regular post cannot be featured. Non-regular rows are the posts table's
    # event/small-action entries (system or moderator actions — closed / pinned /
    # visible.disabled etc., created by Topic#add_small_action with an empty raw and
    # an action_code; post_type 3), whispers (post_type 4, invisible to non-staff)
    # and legacy moderator posts (post_type 2). Unlike the 404 for a post that is
    # missing or belongs elsewhere (handled by the step above, which runs first),
    # these posts exist and belong to the topic, so they are business-rule 422s.
    def ensure_added_replies_are_featureable(membership:, params:)
      ids = selected_reply_ids(params, :add)
      return if ids.empty?

      offender =
        Post
          .where(id: ids, topic_id: membership.topic_id)
          .pluck(:id, :post_number, :post_type)
          .find do |_id, post_number, post_type|
            post_number == 1 || post_type != Post.types[:regular]
          end
      return if offender.blank?

      error_key =
        if offender[1] == 1
          "discourse_collection.errors.selected_reply_cannot_be_first_post"
        else
          "discourse_collection.errors.selected_reply_must_be_a_regular_post"
        end
      fail!(I18n.t(error_key))
    end

    def write_note(membership:, params:)
      return if params.note.equal?(NOTE_NOT_GIVEN)

      # A value replaces the note; null / blank clears it (same .presence rule as docs/04 §3).
      # Non-String values are stored as text (a JSON-number note keeps its digits),
      # mirroring the cast the typed path (docs/04 §3) would have applied.
      membership.update!(note: params.note.presence&.to_s)
    end

    # Idempotent incremental featured-reply edits: add inserts only the post_ids
    # without an existing row (PK is (collection_id, post_id), so re-adding the same
    # reply is a no-op), remove deletes whatever rows exist for the listed post_ids
    # (missing targets are a no-op). Remove never consults the post row itself — a
    # reply is unfeatured by deleting its featured-reply row, so a post soft-deleted
    # after being featured can still be removed (docs/04 §4). The final flag mirrors
    # whether any row remains.
    def edit_selected_replies(collection:, membership:, params:)
      add_ids = selected_reply_ids(params, :add)
      remove_ids = selected_reply_ids(params, :remove)
      return if add_ids.empty? && remove_ids.empty?

      if add_ids.any?
        existing =
          CollectionTopicSelectedReply
            .where(
              collection_id: collection.id,
              topic_id: membership.topic_id,
              post_id: add_ids,
            )
            .pluck(:post_id)
        (add_ids - existing).each do |post_id|
          CollectionTopicSelectedReply.create!(
            collection_id: collection.id,
            topic_id: membership.topic_id,
            post_id:,
          )
        end
      end

      if remove_ids.any?
        CollectionTopicSelectedReply
          .where(
            collection_id: collection.id,
            topic_id: membership.topic_id,
            post_id: remove_ids,
          )
          .delete_all
      end

      membership.update!(
        has_selected_reply:
          CollectionTopicSelectedReply.exists?(
            collection_id: collection.id,
            topic_id: membership.topic_id,
          ),
      )
    end

    # Activity intent (a note to set/clear or a non-empty featured-reply edit) bumps
    # collection.updated_at; a pure no-op body {} leaves every timestamp alone.
    def touch_activity(collection:, params:)
      intent =
        !params.note.equal?(NOTE_NOT_GIVEN) || selected_reply_ids(params, :add).any? ||
          selected_reply_ids(params, :remove).any?
      return unless intent

      collection.update!(updated_at: Time.zone.now)
    end
  end
end
