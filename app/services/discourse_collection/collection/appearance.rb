# frozen_string_literal: true

module DiscourseCollection
  class Collection::Appearance
    FIELDS = %w[avatar_upload_id background_upload_id].freeze
    IMAGE_EXTENSIONS = %w[jpg jpeg png gif webp].freeze

    # Only changed fields are sent: a maintainer replacing the avatar must not overwrite
    # a background another maintainer changed while the dialog was open.
    def self.update!(collection:, user:, attributes:)
      collection.with_lock do
        policy = CollectionPolicy.for(collection:, user:)
        raise Discourse::InvalidAccess unless policy.can_manage_appearance?

        changes = attributes.to_h.stringify_keys.slice(*FIELDS)
        raise Discourse::InvalidParameters.new(:appearance) if changes.empty?

        changes.transform_values! do |value|
          next nil if value.nil?
          unless value.to_s.match?(/\A[1-9]\d*\z/)
            raise Discourse::InvalidParameters.new(:upload_id)
          end
          value.to_i
        end

        changes.each do |field, id|
          next if id.nil? || collection.public_send(field) == id

          upload = Upload.find_by(id:)
          owned =
            upload &&
              (upload.user_id == user.id || UserUpload.exists?(upload_id: id, user_id: user.id))
          unless owned && !upload.secure? && IMAGE_EXTENSIONS.include?(upload.extension&.downcase) &&
                   upload.width.to_i.positive? && upload.height.to_i.positive?
            raise Discourse::InvalidParameters.new(
              I18n.t("discourse_collection.errors.invalid_appearance_upload"),
            )
          end
        end

        collection.update!(changes)
      end
      collection
    end
  end
end
