# frozen_string_literal: true

module DiscourseCollection
  # Fields and aggregate lookups shared by the two collection shapes (docs/03 §1).
  # owner / counts / membership are pre-loaded once per request by the controller and
  # passed through the serializer options hash (see BaseController#collection_serializer_options).
  class CollectionBaseSerializer < ::ApplicationSerializer
    attributes :id,
               :name,
               :description,
               :topic_count,
               :created_at,
               :updated_at,
               :last_topic_added_at,
               :owner,
               :subscriber_count,
               :is_subscribed,
               :avatar_upload,
               :background_upload

    def avatar_upload
      appearance_upload(object.avatar_upload_id)
    end

    def background_upload
      appearance_upload(object.background_upload_id)
    end

    def appearance_upload(id)
      upload = @options.fetch(:appearance_uploads, {})[id]
      return if upload.nil? || upload.secure?

      {
        id: upload.id,
        url: Discourse.store.cdn_url(upload.url),
        width: upload.width,
        height: upload.height,
      }
    end

    def owner
      user = @options.fetch(:owner_users, {})[object.id]
      user && ::BasicUserSerializer.new(user, scope:, root: false).as_json
    end

    def subscriber_count
      # Stored column (docs/08 §1): = subscription rows minus the current owner's
      # own row (owner auto-subscribes but never counts). No aggregate needed.
      object.subscribers_count
    end

    def is_subscribed
      @options.fetch(:subscribed_ids, []).include?(object.id)
    end
  end
end
