# frozen_string_literal: true

module DiscourseCollection
  class Collection < ActiveRecord::Base
    self.table_name = "collections"

    belongs_to :avatar_upload, class_name: "::Upload", optional: true
    belongs_to :background_upload, class_name: "::Upload", optional: true
    has_many :upload_references, as: :target, dependent: :delete_all

    after_save :sync_appearance_uploads,
               if: -> { saved_change_to_avatar_upload_id? || saved_change_to_background_upload_id? }

    def sync_appearance_uploads
      UploadReference.ensure_exist!(
        upload_ids: [avatar_upload_id, background_upload_id],
        target: self,
      )
    end

    # Owner is a teamworker row flagged is_owner=true (at most one per collection,
    # enforced by a partial unique index). No owner row => ownerless collection.
    has_many :collection_topics, class_name: "DiscourseCollection::CollectionTopic"
    has_many :teamworkers, class_name: "DiscourseCollection::CollectionTeamworker"
    has_many :subscribers, class_name: "DiscourseCollection::CollectionSubscriber"
    has_many :selected_replies,
             class_name: "DiscourseCollection::CollectionTopicSelectedReply"
    has_one :owner_teamworker,
            -> { where(is_owner: true) },
            class_name: "DiscourseCollection::CollectionTeamworker"
    has_one :owner, through: :owner_teamworker, source: :user

    # --- Bulk aggregates (one query per facet, shared by list/detail serializers) ---

    # Collection id => number of co-maintainers (is_owner=false rows; owner is not one).
    def self.co_worker_count_by_collection(ids)
      CollectionTeamworker.where(collection_id: ids, is_owner: false).group(:collection_id).count
    end

    # Collection id => owner User (nil key when the collection is ownerless).
    def self.owner_user_by_collection(ids)
      CollectionTeamworker
        .where(collection_id: ids, is_owner: true)
        .includes(:user)
        .each_with_object({}) { |teamworker, map| map[teamworker.collection_id] = teamworker.user }
    end

    # Collection id => array of co-maintainer Users (is_owner=false rows).
    def self.co_worker_users_by_collection(ids)
      CollectionTeamworker
        .where(collection_id: ids, is_owner: false)
        .includes(:user)
        .group_by(&:collection_id)
        .transform_values { |teamworkers| teamworkers.map(&:user) }
    end

    # Collection ids where `user` holds an is_owner=false teamworker row (visitor is co-maintainer).
    def self.teamworker_collection_ids_for(user, ids, is_owner: false)
      CollectionTeamworker.where(user_id: user.id, collection_id: ids, is_owner:).pluck(:collection_id)
    end

    # Collection ids where `user` has a subscriber row.
    def self.subscribed_collection_ids_for(user, ids)
      CollectionSubscriber.where(user_id: user.id, collection_id: ids).pluck(:collection_id)
    end

    # The user's other collections (docs/03 §4), as rows carrying only id and name:
    # the ones they own first, then the ones they co-maintain, each group ordered by
    # most recently added topic (NULL = never collected, sorts last). Collections.id
    # breaks ties so the cap always cuts the same way.
    #
    # is_owner leads the ordering so one LIMIT fills the owner group before the
    # co-maintainer group. The join runs over collection_teamworkers' real composite
    # key and is pinned to a single user, so an inner join cannot multiply rows.
    def self.other_collections_for_user(user_id, exclude_id:, limit:)
      joins(:teamworkers)
        .where(collection_teamworkers: { user_id: user_id })
        .where.not(id: exclude_id)
        .order(
          Arel.sql(
            "collection_teamworkers.is_owner DESC, " \
              "collections.last_topic_added_at DESC NULLS LAST, collections.id ASC",
          ),
        )
        .limit(limit)
        .select(:id, :name)
    end

    # --- topic_count / last_topic_added_at maintenance (docs/08) ---
    #
    # Single implementation point for the counters that the topic write paths (docs/04 §3
    # add, docs/04 §5 remove) must keep in sync — never hand-tuned per endpoint. Both bump
    # the stored count with an atomic UPDATE (no lost increment), recompute/stamp
    # last_topic_added_at and touch updated_at, then mirror the values onto the
    # caller's +collection+ so the in-memory object stays in sync for responses.
    # Callers run these inside their own transaction.

    # docs/04 §3 add: +1 topic_count, stamp last_topic_added_at = now, updated_at = now.
    def self.bump_topic_count_and_activity!(collection)
      now = Time.zone.now
      Collection.where(id: collection.id).update_all("topic_count = topic_count + 1")
      Collection
        .where(id: collection.id)
        .update_all(last_topic_added_at: now, updated_at: now)

      collection.topic_count += 1
      collection.last_topic_added_at = now
      collection.updated_at = now
    end

    # docs/04 §5 remove: after the membership row is deleted, -1 topic_count (floor 0) and
    # recompute last_topic_added_at = newest remaining created_at (NULL when the collection
    # becomes empty, docs/01 §8 / docs/04 §5); touch updated_at.
    def self.recompute_topic_count_and_activity!(collection)
      now = Time.zone.now
      newest = CollectionTopic.where(collection_id: collection.id).maximum(:created_at)
      Collection
        .where(id: collection.id)
        .update_all("topic_count = GREATEST(topic_count - 1, 0)")
      Collection
        .where(id: collection.id)
        .update_all(last_topic_added_at: newest, updated_at: now)

      collection.topic_count = [collection.topic_count - 1, 0].max
      collection.last_topic_added_at = newest
      collection.updated_at = now
    end

    # --- subscribers_count storage (docs/08 §1) ---

    # Subscriber rows that count towards the stored `subscribers_count` and towards
    # the public subscriber list: every subscription row except the current owner's
    # own (the owner auto-subscribes but is the only person who is subscribed yet not
    # counted). An owner without a subscription row subtracts nothing.
    #
    # collection_teamworkers has a composite primary key (no id column), so the
    # "unmatched by the LEFT JOIN" test must use a column that exists there. Any of
    # collection_id/user_id/is_owner is NULL on an unmatched row.
    def self.counted_subscriber_rows(collection_id)
      CollectionSubscriber
        .joins(<<~SQL)
          LEFT JOIN collection_teamworkers AS teamworkers
            ON teamworkers.collection_id = collection_subscribers.collection_id
           AND teamworkers.user_id = collection_subscribers.user_id
           AND teamworkers.is_owner
        SQL
        .where(collection_subscribers: { collection_id: })
        .where("teamworkers.collection_id IS NULL")
    end

    def self.counted_subscribers(collection_id)
      counted_subscriber_rows(collection_id).count
    end

    # Recomputed subscribers_count, mirroring the same value onto +collection+ so the
    # caller's object stays in sync. Call after any write that changes who owns the
    # collection (docs/03 §2 create, docs/05 §2 change owner) — the count is derived, not hand-tuned.
    def self.recompute_subscribers_count!(collection)
      collection.update!(subscribers_count: counted_subscribers(collection.id))
    end

    # Hand-tuned ±1 for a plain (non-owner) subscribe/unsubscribe (docs/08): the row
    # count only changes for rows that count. Uses a single atomic UPDATE so two
    # concurrent writes cannot lose an increment, then mirrors the value onto
    # +collection+ (already persisted) for the caller's in-memory object.
    def self.increment_subscribers_count!(collection)
      Collection
        .where(id: collection.id)
        .update_all("subscribers_count = subscribers_count + 1")
      collection.subscribers_count += 1
    end

    def self.decrement_subscribers_count!(collection)
      Collection
        .where(id: collection.id)
        .update_all("subscribers_count = GREATEST(subscribers_count - 1, 0)")
      collection.subscribers_count = [collection.subscribers_count - 1, 0].max
    end

    # --- Daily drift reconciliation (driven by the scheduled job) ---

    # Whole-table, idempotent recompute of every denormalized column that is otherwise
    # business-layer maintained (CLAUDE hard rule 4): collections.topic_count /
    # last_topic_added_at / subscribers_count and collection_topics.has_selected_reply.
    #
    # This pass only repairs drift — it is not collection activity, so it never touches
    # updated_at (every write below is raw SQL that bypasses AR's auto timestamp) and only
    # rows whose stored value actually differs are rewritten (no write churn on a healthy
    # table). It takes a statement-level snapshot and runs once a day, so a concurrent
    # write racing a run self-heals on the next pass (the same weak-concurrency tolerance
    # as the write paths).
    #
    # Per-column semantics (unchanged from the write paths except where noted):
    #   - topic_count: memberships whose topic is NOT soft-deleted. The one column whose
    #     recompute can materially shrink a value — add (docs/04 §3) never re-checks the topic,
    #     so a topic core soft-deleted afterwards keeps counting here until this pass
    #     lowers it to match the reading page (which already joins topics.deleted_at IS
    #     NULL, docs/04 §1). Hard-deleted topics already cascaded their membership away.
    #   - last_topic_added_at: existing remove-time semantic — newest
    #     collection_topics.created_at over ALL memberships, NULL when none. Topic
    #     deletion is a request-time concern for it, so deleted memberships still rank.
    #   - subscribers_count: unchanged — subscription rows minus the owner's own row
    #     (docs/08 §1), i.e. Collection.counted_subscriber_rows at collection scope.
    #   - has_selected_reply: mirrors whether a selected-reply row exists for the
    #     (collection, topic); whether a selected post is deleted is only checked at
    #     request time (docs/04 §1), so existence is all this recomputes.
    def self.reconcile_denormalized_state!
      transaction do
        connection.exec_update(<<~SQL, "reconcile topic_count + last_topic_added_at")
          UPDATE collections AS c
          SET topic_count         = COALESCE(live.cnt, 0),
              last_topic_added_at = newest.last_added_at
          FROM collections AS all_c
          LEFT JOIN (
            SELECT ct.collection_id, COUNT(*) AS cnt
            FROM collection_topics ct
            INNER JOIN topics t ON t.id = ct.topic_id AND t.deleted_at IS NULL
            GROUP BY ct.collection_id
          ) live ON live.collection_id = all_c.id
          LEFT JOIN (
            SELECT ct.collection_id, MAX(ct.created_at) AS last_added_at
            FROM collection_topics ct
            GROUP BY ct.collection_id
          ) newest ON newest.collection_id = all_c.id
          WHERE c.id = all_c.id
            AND (c.topic_count <> COALESCE(live.cnt, 0)
                 OR c.last_topic_added_at IS DISTINCT FROM newest.last_added_at)
        SQL

        connection.exec_update(<<~SQL, "reconcile subscribers_count")
          UPDATE collections AS c
          SET subscribers_count = COALESCE(counted.cnt, 0)
          FROM collections AS all_c
          LEFT JOIN (
            SELECT cs.collection_id, COUNT(*) AS cnt
            FROM collection_subscribers cs
            LEFT JOIN collection_teamworkers tw
                   ON tw.collection_id = cs.collection_id
                  AND tw.user_id = cs.user_id
                  AND tw.is_owner
            WHERE tw.collection_id IS NULL
            GROUP BY cs.collection_id
          ) counted ON counted.collection_id = all_c.id
          WHERE c.id = all_c.id
            AND c.subscribers_count <> COALESCE(counted.cnt, 0)
        SQL

        connection.exec_update(<<~SQL, "raise has_selected_reply")
          UPDATE collection_topics ct
          SET has_selected_reply = TRUE
          WHERE ct.has_selected_reply = FALSE
            AND EXISTS (
              SELECT 1 FROM collection_topic_selected_replies sr
              WHERE sr.collection_id = ct.collection_id
                AND sr.topic_id = ct.topic_id
            )
        SQL

        connection.exec_update(<<~SQL, "lower has_selected_reply")
          UPDATE collection_topics ct
          SET has_selected_reply = FALSE
          WHERE ct.has_selected_reply = TRUE
            AND NOT EXISTS (
              SELECT 1 FROM collection_topic_selected_replies sr
              WHERE sr.collection_id = ct.collection_id
                AND sr.topic_id = ct.topic_id
            )
        SQL
      end
    end
  end
end

# == Schema Information
#
# Table name: collections
#
#  id                  :integer          not null, primary key
#  description         :string(1000)     not null
#  last_topic_added_at :datetime
#  name                :string(100)      not null
#  subscribers_count   :integer          default(0), not null
#  topic_count         :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
