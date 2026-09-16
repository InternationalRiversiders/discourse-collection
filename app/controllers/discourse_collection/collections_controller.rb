# frozen_string_literal: true

module DiscourseCollection
  class CollectionsController < BaseController
    # Read access gate only for the public read actions. `mine` always requires a
    # logged-in user (it is scoped to "me"), so it checks that inside the action.
    before_action :ensure_read_access,
                  only: %i[index show subscribers topics selected_replies selected_replies_count]
    # Write endpoints always require login; the owner/staff permission matrix is then
    # enforced per action by the service policies.
    before_action :ensure_write_access,
                  only: %i[
                    create update destroy remove_maintainer subscribe unsubscribe
                    read_notifications create_invite revoke_invite accept_invite reject_invite
                    add_topic remove_topic update_collected_topic rewrite_topic_note
                  ]

    # docs/03 §3 GET /collections.json — collection list, optionally filtered to the collections a
    # user created or maintains.
    def index
      scope =
        if (username = params[:username].presence)
          user = User.find_by(username_lower: username.delete_prefix("@").downcase)
          user ? user_collections_scope(user) : Collection.none
        else
          Collection.all
        end

      render_collection_list(scope)
    end

    # docs/03 §4 GET /collections/:id.json — full collection shape (owner may be null), plus
    # the owner's other collections. Those two extra keys belong to this endpoint alone, so
    # they are merged here rather than in collection_full_json (shared with the write paths).
    def show
      collection = find_collection(params[:id])
      payload = collection_full_json(collection)
      # The owner sits on the partial unique index over (collection_id) WHERE is_owner, so
      # this is one indexed lookup and loads no User.
      owner_id = CollectionTeamworker.find_by(collection_id: collection.id, is_owner: true)&.user_id

      if owner_id
        cap = SiteSetting.collection_max_owner_collections_per_detail
        # One extra row is the probe: rows.size > cap means "there is more" (docs/03 §4).
        rows = Collection.other_collections_for_user(owner_id, exclude_id: collection.id, limit: cap + 1)
        if rows.any?
          payload[:owner_collections] = rows.first(cap).map { |row| { id: row.id, name: row.name } }
        end
        payload[:has_more_owner_collections] = true if rows.size > cap
      end

      render json: payload
    end

    # docs/04 §6 GET /collections/mine.json — collections where the current user is owner or
    # co-maintainer (list shape, same ordering/pagination as docs/03 §3).
    def mine
      raise Discourse::NotLoggedIn if current_user.blank?

      render_collection_list(Collection.where(id: my_membership_scope.select(:collection_id)))
    end

    # docs/04 §6 GET /collections/subscribed.json — collections the current user subscribes to
    # (list shape; is_subscribed is always true here). Same four sort keys and default
    # as docs/03 §3 / mine (default last_topic_added_at desc): sorting is uniform across the
    # three list endpoints.
    def subscribed
      raise Discourse::NotLoggedIn if current_user.blank?

      scope =
        Collection.where(
          id: CollectionSubscriber.where(user_id: current_user.id).select(:collection_id),
        )
      render_collection_list(scope)
    end

    # docs/03 §2 POST /collections.json — create a collection owned by the acting user.
    def create
      Collection::Create.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_failed_step(:ensure_under_collection_limit) { |step| render_error_response(step.error) }
        on_failed_policy(:can_create_collection) { raise Discourse::InvalidAccess }
      end
    end

    # docs/05 §1 PUT /collections/:id.json — rename / change description (owner or staff).
    def update
      Collection::Update.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_failed_policy(:can_manage_metadata) { raise Discourse::InvalidAccess }
      end
    end

    # docs/05 §2.1 POST /collections/:id/invites.json — issue an invitation (maintainer
    # type=0 / ownership type=1, docs/05 §2). Idempotent: a live pending row for the
    # same collection + target + type is returned as-is with 200; a fresh one is 201.
    # The one request that answers differently is a staff self-takeover (docs/05 §2.7): it
    # lands the ownership inside the request, so it answers 200 with the accepted invite
    # and the collection's new shape — the inviter/invitee pair being the same user is
    # what marks it (a regular invite can never be self-addressed).
    def create_invite
      collection = find_collection(params[:id])

      existing =
        CollectionInvite.valid_pending.find_by(
          collection_id: collection.id,
          invitee_user_id: params[:user_id],
          action_type: params[:action_type],
        )
      if existing
        render_invite(existing)
        return
      end

      Collection::CreateInvite.call(service_params) do
        on_success do |invite:, collection:|
          if invite.inviter_user_id == invite.invitee_user_id
            render json: {
                     invite: invite_json(invite),
                     collection: collection_full_json(collection),
                   }
          else
            render_invite(invite, status: 201)
          end
        end
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_model_not_found(:invitee) { raise Discourse::NotFound }
        on_failed_policy(:can_create_invite) { raise Discourse::InvalidAccess }
        on_failed_step(:ensure_user_is_not_the_inviter) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_inviter_is_not_the_owner) { |step| render_error_response(step.error) }
        on_failed_step(:ensure_new_owner_in_create_allowed_groups) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_new_owner_within_collection_cap) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_target_is_not_the_owner) { |step| render_error_response(step.error) }
        on_failed_step(:ensure_user_is_not_yet_maintainer) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_under_maintainer_cap) { |step| render_error_response(step.error) }
        on_failed_step(:ensure_target_in_teamworker_allowed_groups) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_target_in_create_allowed_groups) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_no_pending_ownership_invite) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_ownership_transfer_within_teamworker_cap) do |step|
          render_error_response(step.error)
        end
      end
    end

    # docs/05 §2.3 GET /collections/:id/invites.json — this collection's invitation record
    # (owner of that collection, or staff via the management op).
    def collection_invites
      collection = find_collection(params[:id])
      policy = CollectionPolicy.for(collection:, user: current_user)
      raise Discourse::InvalidAccess unless policy.owner? || policy.can_manage_collection?

      page, page_size = pagination_params
      scope = CollectionInvite.within_history.where(collection_id: collection.id)
      total = scope.count
      invites = load_invite_page(scope, page, page_size)

      render json: { invites:, meta: pagination_meta(page, page_size, total) }
    end

    # docs/05 §2.4 GET /collections/invites.json — my inbox (always the logged-in user;
    # anonymous 403, same as mine — not opened by collection_allow_anonymous).
    def invites_inbox
      raise Discourse::NotLoggedIn if current_user.blank?

      page, page_size = pagination_params
      scope = CollectionInvite.within_history.where(invitee_user_id: current_user.id)
      total = scope.count
      invites = load_invite_page(scope, page, page_size, inbox: true)

      render json: {
               invites:,
               meta: { page:, page_size:, more: (page + 1) * page_size < total },
             }
    end

    # docs/05 §2.2 DELETE /collections/:id/invites/:invite_id.json — revoke a pending
    # invitation: one's own, or any of the collection's when the caller is staff
    # holding the management role (physical row delete; the freed spot is
    # immediately reusable).
    def revoke_invite
      Collection::RevokeInvite.call(service_params) do
        on_success { render json: success_json }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_model_not_found(:invite) { raise Discourse::NotFound }
        on_failed_policy(:can_revoke) { raise Discourse::InvalidAccess }
        on_failed_step(:ensure_pending) { |step| render_error_response(step.error) }
      end
    end

    # docs/05 §2.5 POST /collections/invites/:invite_id/accept.json — accept; the
    # membership row is written / the owner switched per action_type.
    def accept_invite
      Collection::AcceptInvite.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:invite) { raise Discourse::NotFound }
        on_failed_step(:ensure_pending) { |step| render_error_response(step.error) }
        on_failed_step(:ensure_new_owner_in_create_allowed_groups) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_new_owner_within_collection_cap) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:ensure_joiner_in_teamworker_allowed_groups) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:join_as_maintainer_on_accept) do |step|
          render_error_response(step.error)
        end
      end
    end

    # docs/05 §2.5 POST /collections/invites/:invite_id/reject.json — reject; no
    # membership/owner write happens, only accept=false.
    def reject_invite
      Collection::RejectInvite.call(service_params) do
        on_success { render json: success_json }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:invite) { raise Discourse::NotFound }
        on_failed_step(:ensure_pending) { |step| render_error_response(step.error) }
      end
    end

    # DELETE /collections/:id/teamworkers/:user_id.json — remove a co-maintainer (owner only).
    def remove_maintainer
      Collection::RemoveMaintainer.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_model_not_found(:target_user) { raise Discourse::NotFound }
        on_failed_policy(:can_manage_maintainers) { raise Discourse::InvalidAccess }
        on_failed_step(:ensure_user_is_not_the_owner) { |step| render_error_response(step.error) }
        on_failed_step(:ensure_user_is_a_maintainer) { |step| render_error_response(step.error) }
      end
    end

    # POST /collections/:id/subscription.json — subscribe (idempotent). Any signed-in
    # user may subscribe to any collection (docs/06 §2); owner auto-subscribes on
    # creation/promotion and may re-subscribe after unsubscribing (never counts).
    def subscribe
      Collection::Subscribe.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
      end
    end

    # DELETE /collections/:id/subscription.json — unsubscribe (idempotent no-op 200).
    def unsubscribe
      Collection::Unsubscribe.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
      end
    end

    # PUT /collections/:id/read_notifications.json — mark the caller's unread notifications
    # about this collection as read. Sent fire-and-forget by the collection page behind a
    # client-side gate (per type, not per collection), so a no-op is an ordinary outcome and
    # still answers 200. Only the caller's own rows are touched: no owner/maintainer gate.
    def read_notifications
      Collection::MarkNotificationsRead.call(service_params) do
        on_success { render json: success_json }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
      end
    end

    # GET /collections/:id/subscribers.json — public subscriber list (docs/02 §5):
    # counted subscription rows only (current owner never appears), pageable, oldest
    # subscription first (the subscribers table carries no updated_at).
    def subscribers
      collection = find_collection(params[:id])
      page, page_size = pagination_params

      rows = Collection.counted_subscriber_rows(collection.id).includes(:user)
      total = rows.count
      users =
        rows
          .order("collection_subscribers.created_at ASC")
          .offset(page * page_size)
          .limit(page_size)
          .map { |row| ::BasicUserSerializer.new(row.user, scope: guardian, root: false).as_json }

      render json: { subscribers: users, meta: pagination_meta(page, page_size, total) }
    end

    # DELETE /collections/:id.json — delete a collection (owner only, not staff).
    def destroy
      Collection::Delete.call(service_params) do
        on_success { render json: success_json }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_failed_policy(:can_delete_collection) { raise Discourse::InvalidAccess }
      end
    end

    # docs/04 §3 POST /collections/:id/topics.json — collect a topic (owner/teamworker).
    # Fresh collect and idempotent re-collect both return the collection's full shape
    # (its topic_count / last_topic_added_at / updated_at reflect the write).
    def add_topic
      Collection::AddTopic.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_model_not_found(:topic) { raise Discourse::NotFound }
        on_failed_policy(:can_write_topics) { raise Discourse::InvalidAccess }
        on_failed_step(:ensure_topic_is_not_a_private_message) do |step|
          render_error_response(step.error)
        end
        on_failed_step(:add_topic) { |step| render_error_response(step.error) }
      end
    end

    # docs/04 §4 PATCH /collections/:id/topics/:topic_id.json — partial edit of one
    # collected topic (owner/teamworker): change its note and/or feature/unfeature
    # replies (docs/04 §4). Responds with the updated reading-page row.
    def update_collected_topic
      Collection::UpdateCollectedTopic.call(service_params) do
        on_success { |collection:| render_collected_topic_row(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_model_not_found(:membership) { raise Discourse::NotFound }
        on_failed_policy(:can_write_topics) { raise Discourse::InvalidAccess }
        on_failed_step(:ensure_added_replies_belong_to_topic) { raise Discourse::NotFound }
        on_failed_step(:ensure_added_replies_are_featureable) do |step|
          render_error_response(step.error)
        end
      end
    end

    # docs/06 §1 PUT /collections/:id/topics/:topic_id/note.json — staff rewrite of a note
    # on any collection (including someone else's / ownerless). Only the note is replaced
    # (admin + moderator always allowed, no setting gate). Same row response as docs/04 §4.
    def rewrite_topic_note
      Collection::RewriteTopicNote.call(service_params) do
        on_success { |collection:| render_collected_topic_row(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_model_not_found(:membership) { raise Discourse::NotFound }
        on_model_not_found(:topic) { raise Discourse::NotFound }
        on_failed_policy(:staff) { raise Discourse::InvalidAccess }
      end
    end

    # docs/04 §5 DELETE /collections/:id/topics/:topic_id.json — remove a collected topic
    # (owner/teamworker). Returns the collection's full shape after the counters are
    # recomputed (docs/04 §5).
    def remove_topic
      Collection::RemoveTopic.call(service_params) do
        on_success { |collection:| render_collection_full(collection) }
        on_failed_contract { |contract| render_error_response(contract.errors.full_messages) }
        on_model_not_found(:collection) { raise Discourse::NotFound }
        on_failed_policy(:can_write_topics) { raise Discourse::InvalidAccess }
        on_failed_step(:ensure_topic_is_included) { |step| render_error_response(step.error) }
      end
    end

    # docs/04 §1 GET /collections/:id/topics.json — the collection reading page (core read
    # endpoint). Paginates the collected topics ordered by one of three keys (whitelist
    # below, default added_at desc): the collection time, the topic's own creation time or
    # its latest activity — the latter two live on the joined topics row. Every key carries
    # collection_topics.topic_id as a same-direction tie-breaker, so paging stays stable
    # when two rows share a value. The paging window is narrowed in SQL to the topics the
    # visitor may *list* (visible_topics_scope: category read-access + core's rule for unlisted
    # topics) *before* offset/limit, so rows the visitor may not list never occupy window
    # slots and paging yields contiguous visible rows (no holes / empty mid pages).
    # meta.total still counts the full collected set, so a restricted visitor may see
    # fewer rows than the meta states and trailing pages can be sparse (docs/04 §1).
    # Rows on the page are then guardian-filtered row by row
    # (deleted or still-invisible dropped) as the final gate. It also inlines, for topics
    # flagged has_selected_reply=true, the collection's selected replies for that topic —
    # at most collection_max_selected_replies_per_topic, post_id ASC, with a probe
    # deciding the conditional has_more_selected_replies key. Everything topic/post that
    # leaves here has passed the visitor Guardian (CLAUDE hard rule 7).
    def topics
      collection = find_collection(params[:id])
      page, page_size = pagination_params

      sort, order = sort_and_order(allowed: TOPIC_SORT_COLUMNS, default: TOPIC_SORT_DEFAULT)
      scope =
        CollectionTopic
          .where(collection_id: collection.id)
          .joins(
            "INNER JOIN topics ON topics.id = collection_topics.topic_id AND topics.deleted_at IS NULL",
          )

      total = scope.count
      memberships =
        apply_topic_order(scope.where(topic_id: visible_topics_scope.select(:id)), sort, order)
          .offset(page * page_size)
          .limit(page_size)
          .to_a

      topics_by_id = Topic.where(id: memberships.map(&:topic_id)).index_by(&:id)
      visible = memberships.filter_map do |membership|
        topic = topics_by_id[membership.topic_id]
        [membership, topic] if topic && guardian.can_see_topic?(topic)
      end

      inline_by_topic = load_inline_selected_replies(collection.id, visible)

      rows =
        visible.map do |membership, topic|
          collection_topic_row(membership, topic, inline_by_topic[membership.topic_id])
        end

      render json: {
        topics: rows,
        users: users_json(rows.flat_map { |row| row_user_ids(row) }),
        meta: pagination_meta(page, page_size, total),
      }
    end

    # docs/04 §2 pagination endpoint GET /collections/:id/topics/:topic_id/selected_replies.json —
    # full selected-reply list for one collected topic (the overflow when a topic's
    # inline window reports has_more_selected_replies). Fixed post_id ASC (same order as
    # the inline window), not capped by collection_max_selected_replies_per_topic,
    # filtered per post by the visitor Guardian exactly like the inline window.
    def selected_replies
      collection = find_collection(params[:id])
      membership =
        CollectionTopic.find_by(collection_id: collection.id, topic_id: params[:topic_id])
      raise Discourse::NotFound if membership.blank?

      topic = Topic.find_by(id: membership.topic_id)
      raise Discourse::NotFound if topic.blank? || !guardian.can_see_topic?(topic)

      page, page_size = pagination_params
      pairs =
        CollectionTopicSelectedReply
          .where(collection_id: collection.id, topic_id: topic.id)
          .order("post_id ASC")
          .pluck(:post_id, :created_at)

      posts_by_id = Post.where(id: pairs.map(&:first)).includes(:user).index_by(&:id)
      visible =
        pairs.filter_map do |post_id, selected_at|
          post = posts_by_id[post_id]
          [post, selected_at] if post && guardian.can_see_post?(post)
        end

      total = visible.size
      entries =
        visible
          .drop(page * page_size)
          .first(page_size)
          .map { |post, selected_at| selected_reply_json(post, created_at: selected_at) }

      render json: {
        selected_replies: entries,
        users: users_json(entries.map { |entry| entry[:user_id] }),
        meta: pagination_meta(page, page_size, total),
      }
    end

    # docs/04 §7 GET /collections/:id/topics/:topic_id/selected_replies/count.json — the row
    # count behind the removal warning. Every row of the pair is counted, a soft-deleted
    # post's row included: what this answers is "how many rows the removal would cascade
    # away", which is a total and not what the visitor may see — the same stance as
    # topic_count. One COUNT, served by the (collection_id, topic_id, post_id) index.
    def selected_replies_count
      collection = find_collection(params[:id])
      membership =
        CollectionTopic.find_by(collection_id: collection.id, topic_id: params[:topic_id])
      raise Discourse::NotFound if membership.blank?

      topic = Topic.find_by(id: membership.topic_id)
      raise Discourse::NotFound if topic.blank? || !guardian.can_see_topic?(topic)

      count =
        CollectionTopicSelectedReply.where(collection_id: collection.id, topic_id: topic.id).count

      render json: { selected_reply_count: count }
    end

    private

    # Sortable columns for every list endpoint (docs/03 §3 and docs/04 §6 mine /
    # subscribed); default order is last_topic_added_at desc.
    COLLECTION_SORT_COLUMNS = %w[created_at last_topic_added_at topic_count subscriber_count].freeze

    # API sort key (as accepted in the query) mapped to the real column it orders by
    # on `collections`. Keys match their column except subscriber_count: the API exposes
    # that singular sort key while the stored column is plural `subscribers_count`
    # (docs/08 §1, docs/03 §3) — so ordering interpolates the mapped column, never the
    # raw sort key.
    SORT_KEY_TO_COLUMN = {
      "created_at" => "collections.created_at",
      "last_topic_added_at" => "collections.last_topic_added_at",
      "topic_count" => "collections.topic_count",
      "subscriber_count" => "collections.subscribers_count",
    }.freeze

    # Sortable keys for the reading page (docs/04 §1). All three columns are NOT NULL, so
    # unlike the list endpoints there is no null placement to decide.
    TOPIC_SORT_COLUMNS = %w[added_at topic_created_at topic_bumped_at].freeze

    TOPIC_SORT_DEFAULT = "added_at"

    # API sort key mapped to the column it orders by: the membership's own created_at, or
    # a topics column reached through the join #topics always makes. `bumped_at` is core's
    # latest-activity timestamp (the column core's own topic lists order by); the order
    # fragment below interpolates the mapped column, never the raw sort key.
    TOPIC_SORT_KEY_TO_COLUMN = {
      "added_at" => "collection_topics.created_at",
      "topic_created_at" => "topics.created_at",
      "topic_bumped_at" => "topics.bumped_at",
    }.freeze

    # Collections in which `user` holds any teamworker row (is_owner rows count too), i.e.
    # created-by OR maintained-by (docs/03 §3 / docs/04 §6).
    def user_collections_scope(user)
      Collection.where(id: CollectionTeamworker.where(user_id: user.id).select(:collection_id))
    end

    def my_membership_scope
      CollectionTeamworker.where(user_id: current_user.id)
    end

    # Shared list rendering for docs/03 §3 and docs/04 §6 (mine / subscribed): sort -> filter count
    # -> page -> one batched load of aggregates, then serialize each row as the list
    # shape. All three endpoints share the same sortable columns and default order.
    def render_collection_list(scope, allowed: COLLECTION_SORT_COLUMNS, default: "last_topic_added_at")
      sort, order = sort_and_order(allowed:, default:)
      ordered = apply_collection_order(scope, sort, order)

      total = ordered.count
      page, page_size = pagination_params
      collections = ordered.offset(page * page_size).limit(page_size).to_a
      ids = collections.map(&:id)
      options = collection_serializer_options(ids)

      rows =
        collections.map do |collection|
          CollectionSummarySerializer.new(collection, scope: guardian, root: false, **options).as_json
        end

      render json: { collections: rows, meta: pagination_meta(page, page_size, total) }
    end

    # sort is whitelisted upstream; the mapping above resolves it to an ordering
    # column, so the fragment is a constant from SORT_KEY_TO_COLUMN, never user input.
    def apply_collection_order(scope, sort, order)
      direction = order == "desc" ? "DESC" : "ASC"
      nulls = order == "desc" ? "NULLS LAST" : "NULLS FIRST"
      column = SORT_KEY_TO_COLUMN.fetch(sort)
      ordered =
        if sort == "last_topic_added_at"
          # NULL (never had a topic) sorts as oldest (docs/01 §8).
          scope.order(Arel.sql("#{column} #{direction} #{nulls}"))
        else
          scope.order(Arel.sql("#{column} #{direction}"))
        end

      ordered.order(id: :asc)
    end

    # Full collection shape (docs/03 §1) used by show, create, update and the invitation
    # accept response: pre-loads owner / co-maintainers / counts for the one collection
    # and renders it bare (no wrapper key).
    def render_collection_full(collection)
      render json: collection_full_json(collection)
    end

    def collection_full_json(collection)
      options = collection_serializer_options([collection.id])
      CollectionSerializer.new(collection, scope: guardian, root: false, **options).as_json
    end

    # One invite in the management shape (docs/05 §2.1 / §2.3): create (201) and
    # record (200) both render this object.
    def render_invite(invite, status: 200)
      render json: invite_json(invite), status:
    end

    def invite_json(invite)
      CollectionInviteSerializer.new(invite, scope: guardian, root: false).as_json
    end

    # Batch-loads one invite page. The management shape carries the invitee; the
    # inbox shape (docs/05 §2.4) omits it but adds an owner snapshot per collection so the
    # invitee can judge the collection (esp. a type=1 "become the owner" invite) without a
    # second call (docs/03 §4). Owner snapshots are pre-loaded in one grouped query (no N+1).
    def load_invite_page(scope, page, page_size, inbox: false)
      rows =
        scope
          .includes(:collection, :inviter, :invitee)
          .order("collection_invites.created_at DESC, collection_invites.id DESC")
          .offset(page * page_size)
          .limit(page_size)
          .to_a

      serializer = inbox ? CollectionInviteInboxSerializer : CollectionInviteSerializer
      options = { owner_users: Collection.owner_user_by_collection(rows.map(&:collection_id)) }
      rows.map { |row| serializer.new(row, scope: guardian, root: false, **options).as_json }
    end

    # docs/04 §1 reading-page order: `sort` picks the key (whitelisted upstream), `order`
    # the direction (default desc = newest first). topic_id is appended in the same
    # direction — unique within the collection, it gives rows sharing a sort value a total
    # order, so paging can neither repeat nor skip one. The mapping resolves the key to a
    # column, so the fragment is a constant, never user input.
    def apply_topic_order(scope, sort, order)
      direction = order == "desc" ? "DESC" : "ASC"
      column = TOPIC_SORT_KEY_TO_COLUMN.fetch(sort)

      scope.order(Arel.sql("#{column} #{direction}, collection_topics.topic_id #{direction}"))
    end

    # Topics the visitor may *list* on the reading page (docs/04 §1): category
    # read-access (Topic.secured), plus core's rule for unlisted topics — `visible=false`
    # is listed for staff and TL4 only (guardian.can_see_unlisted_topics?, the same
    # expression core's topic lists use) and is deliberately NOT re-granted to the
    # collection's own owner / co-maintainers. This is a listing rule, not a read rule:
    # the per-row can_see_topic? gate in #topics still serves an unlisted topic — and its
    # selected replies — to anyone holding the URL, exactly like core's /t/:id.
    def visible_topics_scope
      scope = Topic.secured(guardian)
      scope = scope.visible unless guardian.can_see_unlisted_topics?
      scope
    end

    # Core's excerpts are HTML-escaped text, not plain text: a truncated one ends in
    # the entity `&hellip;` instead of an ellipsis, and a reply excerpt keeps the `<a>`
    # tags of the links it quotes. Every excerpt on the wire is plain text
    # (docs/04 §1), so both the topic card and each reply decode theirs first — the
    # same call core's own Topic#plain_text_excerpt makes.
    def plain_text_excerpt(escaped)
      ExcerptParser.to_plain_text(escaped).to_s
    end

    # topic card columns for a reading-page row (docs/04 §1). All are plain Topic
    # columns read off the preloaded row; the excerpt is the OP excerpt core already
    # denormalized into topics.excerpt (topic_excerpt_maxlength), not computed here.
    # `unlisted` is a conditional key: emitted only for a topic that is currently
    # unlisted (visible=false), so public topics carry no key at all. On the reading
    # page only staff/TL4 ever receive such a row; the docs/04 §4 / docs/06 §1 single-row responses
    # share this shape and can also hand it to a maintainer who reached the topic by URL.
    def collection_topic_json(topic)
      json = {
        id: topic.id,
        fancy_title: topic.fancy_title,
        slug: topic.slug,
        category_id: topic.category_id,
        user_id: topic.user_id,
        excerpt: plain_text_excerpt(topic.excerpt),
        created_at: topic.created_at,
        bumped_at: topic.bumped_at,
        posts_count: topic.posts_count,
      }
      json[:unlisted] = true unless topic.visible
      json
    end

    # The docs/04 §1 reading-page row shape for one (collection, topic) membership — also
    # the single-row response of the PATCH (docs/04 §4) and the staff note rewrite (docs/06 §1).
    # inline is the load_inline_selected_replies entry for this topic (nil when the
    # topic is not flagged, so the key is omitted); the empty array is meaningful
    # when the flag row exists but every selected reply is hidden/deleted.
    def collection_topic_row(membership, topic, inline)
      row = {
        added_at: membership.created_at,
        note: membership.note,
        topic: collection_topic_json(topic),
      }
      if inline
        row[:selected_replies] = inline[:entries]
        row[:has_more_selected_replies] = true if inline[:has_more]
      end
      row
    end

    # Renders one collected-topic row after a write (docs/04 §4 / docs/06 §1 responses), re-reading
    # the membership from the DB so the response reflects the committed state. The
    # topic must still exist and be visible to the actor, else 404 (same rule as the
    # reading page). The row carries its own `users` map next to the row fields, so a
    # replaced row keeps resolving its avatars without a page reload.
    def render_collected_topic_row(collection)
      membership =
        CollectionTopic.find_by(collection_id: collection.id, topic_id: params[:topic_id])
      raise Discourse::NotFound if membership.blank?

      topic = Topic.find_by(id: membership.topic_id)
      raise Discourse::NotFound if topic.blank? || !guardian.can_see_topic?(topic)

      inline = load_inline_selected_replies(collection.id, [[membership, topic]])[membership.topic_id]
      row = collection_topic_row(membership, topic, inline)
      render json: row.merge(users: users_json(row_user_ids(row)))
    end

    # One inline reply entry (identical shape on the paged selected_replies endpoint).
    # created_at is the selected-reply row's own creation time (the moment the reply was
    # selected into the collection) — never borrowed from the post, whose own created_at
    # belongs to the post object. The list is fixed post_id ASC regardless. The author
    # travels as user_id only; the username and avatar come from the response's `users`
    # map, and post_number is what the frontend builds the link from (topic + post
    # number, the same target core's own permalinks use).
    def selected_reply_json(post, created_at:)
      {
        post_id: post.id,
        post_number: post.post_number,
        user_id: post.user_id,
        created_at:,
        excerpt: plain_text_excerpt(post.excerpt),
      }
    end

    # The response-level `users` map (uid -> core BasicUser shape) that every avatar
    # and username on this page is read from. Ids come off the rows already built, so
    # only referenced users are loaded — and an author whose account is gone simply
    # has no entry, which the frontend renders as no user at all.
    def users_json(ids)
      ids = ids.compact.uniq
      return {} if ids.empty?

      User.where(id: ids).to_h do |user|
        [user.id, ::BasicUserSerializer.new(user, scope: guardian, root: false).as_json]
      end
    end

    # The user ids one reading-page row references: its topic's author, plus the
    # author of each inline selected reply. Rows are already-built JSON, so the walk
    # costs no extra object graph.
    def row_user_ids(row)
      [row[:topic][:user_id], *(row[:selected_replies] || []).map { |reply| reply[:user_id] }]
    end

    # For the page's flagged (has_selected_reply=true) topics, one windowed query
    # returns up to cap+1 rows per topic ([post_id, created_at], post_id ASC). Posts
    # are preloaded once; each is then filtered by the visitor Guardian (soft-deleted
    # posts never come back from Post.where at all). has_more reflects the visible
    # count only — a hidden/whisper post inside the probe window can under-report on
    # the trailing edge: when it does, the paged overflow endpoint is NOT reachable
    # (its entry requires has_more_selected_replies=true). Declared known limitation
    # in docs/04 §1; no follow-up fetch is attempted here.
    def load_inline_selected_replies(collection_id, visible)
      flagged = visible.select { |membership, _topic| membership.has_selected_reply }
      return {} if flagged.empty?

      cap = SiteSetting.collection_max_selected_replies_per_topic
      window =
        CollectionTopicSelectedReply.windowed_post_ids_by_topic(
          collection_id,
          flagged.map { |membership, _topic| membership.topic_id },
          limit: cap,
        )
      post_ids = window.values.flat_map { |pairs| pairs.map(&:first) }.uniq
      posts_by_id = Post.where(id: post_ids).includes(:user).index_by(&:id)

      flagged.each_with_object({}) do |(membership, _topic), map|
        topic_id = membership.topic_id
        visible_replies =
          window[topic_id].to_a.sort_by { |post_id, _at| post_id }.filter_map do |post_id, selected_at|
            post = posts_by_id[post_id]
            [post, selected_at] if post && guardian.can_see_post?(post)
          end

        map[topic_id] = {
          entries:
            visible_replies.first(cap).map { |post, selected_at| selected_reply_json(post, created_at: selected_at) },
          has_more: visible_replies.size > cap,
        }
      end
    end
  end
end
