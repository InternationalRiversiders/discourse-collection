# frozen_string_literal: true

class CreateDiscourseCollectionTables < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE TABLE collections (
        id SERIAL PRIMARY KEY,
        name CHARACTER VARYING(100) NOT NULL,
        description CHARACTER VARYING(1000) NOT NULL,
        topic_count INTEGER NOT NULL DEFAULT 0,
        subscribers_count INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        last_topic_added_at TIMESTAMP
      )
    SQL

    # The list endpoints (docs/03 §3 / docs/04 §6) sort the whole table by one of the four API sort
    # keys, so each key needs its own path; asc and desc share one index through a
    # forward / backward scan. last_topic_added_at is nullable and the controller
    # orders it DESC NULLS LAST / ASC NULLS FIRST — pathkeys have to match exactly, so
    # the direction and the null placement are declared here: a plain btree (ASC NULLS
    # LAST) matches neither branch and would leave the default sort unindexed.
    execute <<~SQL
      CREATE INDEX index_collections_on_created_at
        ON collections USING btree (created_at)
    SQL

    execute <<~SQL
      CREATE INDEX index_collections_on_last_topic_added_at
        ON collections USING btree (last_topic_added_at DESC NULLS LAST)
    SQL

    execute <<~SQL
      CREATE INDEX index_collections_on_topic_count
        ON collections USING btree (topic_count)
    SQL

    execute <<~SQL
      CREATE INDEX index_collections_on_subscribers_count
        ON collections USING btree (subscribers_count)
    SQL

    execute <<~SQL
      CREATE TABLE collection_topics (
        collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
        note CHARACTER VARYING(100),
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        has_selected_reply BOOLEAN NOT NULL DEFAULT false,
        PRIMARY KEY (collection_id, topic_id)
      )
    SQL

    execute <<~SQL
      CREATE INDEX index_collection_topics_on_topic_id_and_collection_id
        ON collection_topics USING btree (topic_id, collection_id)
    SQL

    # The reading page (docs/04 §1) orders by collection_topics.created_at, topic_id, both
    # descending by default. Carrying topic_id in the key makes that order exact in
    # both directions (forward = asc, backward = desc) and keeps paging stable when
    # two memberships share a created_at.
    execute <<~SQL
      CREATE INDEX index_collection_topics_on_collection_id_and_created_at
        ON collection_topics USING btree (collection_id, created_at, topic_id)
    SQL

    execute <<~SQL
      CREATE TABLE collection_teamworkers (
        collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        is_owner BOOLEAN NOT NULL DEFAULT false,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (collection_id, user_id)
      )
    SQL

    execute <<~SQL
      CREATE UNIQUE INDEX uq_collection_teamworkers_on_single_owner
        ON collection_teamworkers USING btree (collection_id)
        WHERE is_owner
    SQL

    # The partial unique index above only answers "the owner row"; the co-maintainer
    # direction (list aggregates, quota counts, team card) filters is_owner = false and
    # cannot use it. A plain index on collection_id serves both roles at once — the
    # owner rows a partial index would leave out are one per collection — plus the
    # collection cascade. The user direction serves the ?username= / mine lookups, the
    # per-user quota counts and the user cascade.
    execute <<~SQL
      CREATE INDEX index_collection_teamworkers_on_collection_id
        ON collection_teamworkers USING btree (collection_id)
    SQL

    execute <<~SQL
      CREATE INDEX index_collection_teamworkers_on_user_id_and_collection_id
        ON collection_teamworkers USING btree (user_id, collection_id)
    SQL

    execute <<~SQL
      CREATE TABLE collection_topic_selected_replies (
        collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
        post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (collection_id, post_id)
      )
    SQL

    # Name shortened by hand: the default index_<table>_on_<columns> form exceeds the
    # PostgreSQL 63-character identifier limit and would be silently truncated. The
    # trailing post_id makes the inline window (docs/04 §1) — WHERE collection_id, topic_id
    # ORDER BY post_id — a plain index scan instead of a scan plus a sort.
    execute <<~SQL
      CREATE INDEX index_collection_selected_replies_on_collection_topic_post
        ON collection_topic_selected_replies USING btree (collection_id, topic_id, post_id)
    SQL

    # Both referencing columns of the FKs that no other index leads with: a hard-deleted
    # topic or post cascades by topic_id / post_id, and the composite primary key
    # (collection_id, post_id) leads with the collection, so neither is covered.
    execute <<~SQL
      CREATE INDEX index_collection_topic_selected_replies_on_topic_id
        ON collection_topic_selected_replies USING btree (topic_id)
    SQL

    execute <<~SQL
      CREATE INDEX index_collection_topic_selected_replies_on_post_id
        ON collection_topic_selected_replies USING btree (post_id)
    SQL

    execute <<~SQL
      CREATE TABLE collection_subscribers (
        collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (collection_id, user_id)
      )
    SQL

    execute <<~SQL
      CREATE INDEX index_collection_subscribers_on_user_id_and_collection_id
        ON collection_subscribers USING btree (user_id, collection_id)
    SQL

    # The subscriber list (1) pages the counted rows by created_at, which the primary
    # key (collection_id, user_id) cannot order by.
    execute <<~SQL
      CREATE INDEX index_collection_subscribers_on_collection_id_and_created_at
        ON collection_subscribers USING btree (collection_id, created_at)
    SQL

    # Invitation flow table (docs/05 §2): a PROCESS table with its own
    # surrogate key (id SERIAL), not a join table — CLAUDE hard rule 1 does not apply.
    # action_type 0 = invite as co-maintainer, 1 = invite as new owner; accept is
    # NULL (pending) | true | false. Both user FKs are SET NULL (a deleted inviter /
    # invitee leaves the history row intact). The two indexes serve the per-collection
    # record + quota lookups (collection_id, created_at) and the invitee inbox
    # (invitee_user_id, created_at); both are filtered by the history window.
    execute <<~SQL
      CREATE TABLE collection_invites (
        id SERIAL PRIMARY KEY,
        collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
        inviter_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        invitee_user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        action_type INTEGER NOT NULL,
        accept BOOLEAN,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    SQL

    execute <<~SQL
      CREATE INDEX index_collection_invites_on_collection_id_and_created_at
        ON collection_invites USING btree (collection_id, created_at)
    SQL

    execute <<~SQL
      CREATE INDEX index_collection_invites_on_invitee_user_id_and_created_at
        ON collection_invites USING btree (invitee_user_id, created_at)
    SQL

    # The inviter direction is never queried, but its SET NULL cascade updates the
    # column on every user deletion, so it needs a path of its own.
    execute <<~SQL
      CREATE INDEX index_collection_invites_on_inviter_user_id
        ON collection_invites USING btree (inviter_user_id)
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS collection_invites"
    execute "DROP TABLE IF EXISTS collection_subscribers"
    execute "DROP TABLE IF EXISTS collection_topic_selected_replies"
    execute "DROP TABLE IF EXISTS collection_teamworkers"
    execute "DROP TABLE IF EXISTS collection_topics"
    execute "DROP TABLE IF EXISTS collections"
  end
end
