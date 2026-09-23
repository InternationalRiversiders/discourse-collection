# frozen_string_literal: true

module DiscourseCollection
  # All plugin JSON endpoints inherit from this controller (engine is mounted at "/",
  # so controllers must subclass core ::ApplicationController).
  #
  # Three gates per docs/01 §2:
  #   1. plugin disabled          -> 404 (whole plugin invisible)
  #   2. anonymous read access    -> 404 unless collection_allow_anonymous
  #   3. writes                   -> login + permission matrix (enforced per action
  #                                  via CollectionPolicy)
  class BaseController < ::ApplicationController
    # Request bodies are documented as top-level fields (name/description/…).
    # Core enables ActionController::ParamsWrapper for JSON (config/initializers/
    # 100-wrap_parameters.rb), which would otherwise nest JSON bodies under this
    # controller's singular key ("collection") and starve the services' contracts.
    wrap_parameters false

    before_action :ensure_plugin_enabled

    private

    def ensure_plugin_enabled
      raise Discourse::NotFound unless SiteSetting.collection_enabled
    end

    # Read endpoints: anonymous users are turned away unless the site setting opts in.
    def ensure_read_access
      raise Discourse::NotFound if current_user.blank? && !SiteSetting.collection_allow_anonymous
    end

    # Write endpoints: always require a logged-in user; the permission matrix is then
    # checked per action (owner/staff/...) in the service batches that follow.
    def ensure_write_access
      raise Discourse::NotLoggedIn if current_user.blank?
    end

    def find_collection(id)
      collection = Collection.find_by(id:)
      raise Discourse::NotFound if collection.blank?
      collection
    end

    # --- pagination (docs/01 §6): page 0-based, page_size default 30 / max 50 ---

    def pagination_params
      page = (params[:page].presence || 0).to_i
      page = 0 if page.negative?

      raw_size = params[:page_size].presence
      page_size = raw_size ? raw_size.to_i : 30
      raise Discourse::InvalidParameters.new(:page_size) if page_size < 1 || page_size > 50

      [page, page_size]
    end

    def pagination_meta(page, page_size, total)
      { page:, page_size:, more: (page + 1) * page_size < total, total: }
    end

    # --- sort/order (docs/01 §7): unknown sort or order -> 400 ---

    def sort_and_order(allowed:, default:, default_order: "desc")
      sort = params[:sort].presence || default
      raise Discourse::InvalidParameters.new(:sort) unless allowed.include?(sort)

      order = params[:order].presence || default_order
      raise Discourse::InvalidParameters.new(:order) unless %w[asc desc].include?(order)

      [sort, order]
    end

    # --- batch aggregate options shared by the collection serializers (no N+1) ---

    # Loads, in a handful of grouped queries, everything the serializers need for a
    # set of collection ids: teamworker counts, owner/co-maintainer users, and the
    # current user's membership booleans (anonymous -> empty visitor sets). The
    # subscriber_count is a stored column on each collection row, not an aggregate.
    def collection_serializer_options(ids)
      user = current_user

      {
        appearance_uploads:
          Upload
            .where(id: Collection.where(id: ids).pluck(:avatar_upload_id, :background_upload_id).flatten.compact)
            .index_by(&:id),
        teamworker_counts: Collection.co_worker_count_by_collection(ids),
        owner_users: Collection.owner_user_by_collection(ids),
        co_worker_users: Collection.co_worker_users_by_collection(ids),
        teamworker_ids:
          (user && Collection.teamworker_collection_ids_for(user, ids, is_owner: false)) || [],
        subscribed_ids: (user && Collection.subscribed_collection_ids_for(user, ids)) || [],
      }
    end

    # docs/01 §4 error body: `{ "errors": [...] }`. Services and contracts report
    # business-rule failures as message lists rendered with this helper (status 422).
    def render_error_response(errors, status: 422)
      render json: { errors: Array(errors) }, status:
    end
  end
end
