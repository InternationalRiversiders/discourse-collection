# frozen_string_literal: true

module DiscourseCollection
  # docs/05 §1 PUT /collections/:id.json — rename / change description.
  #
  # Partial update: the body carries name and/or description, at least one. Both go
  # through the same validations as create (name trimmed, [min, max] inclusive; staff
  # are NOT exempt from length). The collection's own owner may update it; staff may update
  # ANY collection (including ownerless) via CollectionPolicy#can_manage_collection?. Only
  # metadata changes: updated_at bumps, last_topic_added_at / topic_count are left alone.
  class Collection::Update
    include Service::Base

    params do
      attribute :id, :integer
      attribute :name, :string
      attribute :description, :string

      validate :at_least_one_field
      validate :name_is_valid_if_present
      validate :description_is_valid_if_present

      private

      def at_least_one_field
        if name.nil? && description.nil?
          errors.add(:base, I18n.t("discourse_collection.errors.nothing_to_update"))
        end
      end

      def name_is_valid_if_present
        return if name.nil?

        trimmed = name.strip
        if trimmed.blank?
          errors.add(:base, I18n.t("discourse_collection.errors.name_blank"))
          return
        end

        min = SiteSetting.collection_name_min_length
        max = SiteSetting.collection_name_max_length
        if trimmed.length < min || trimmed.length > max
          errors.add(
            :base,
            I18n.t("discourse_collection.errors.name_out_of_range", min:, max:),
          )
        end
      end

      def description_is_valid_if_present
        return if description.nil?

        max = SiteSetting.collection_description_max_length
        if description.length > max
          errors.add(
            :base,
            I18n.t("discourse_collection.errors.description_out_of_range", max:),
          )
        end
      end
    end

    model :collection
    policy :can_manage_metadata

    transaction do
      step :apply_metadata_changes
      step :save_metadata_changes
    end
    # Post-transaction (docs/10): a rename / intro edit made on staff standing is an admin
    # action and is logged to user_histories once the transaction commits (a rolled-back
    # run never reaches here). Edits the actor could have made as the collection's own
    # owner are routine management and are not logged.
    step :audit_metadata_changes

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def can_manage_metadata(collection:, guardian:)
      policy = CollectionPolicy.for(collection:, user: guardian.user)
      policy.owner? || policy.can_manage_collection?
    end

    def apply_metadata_changes(collection:, params:)
      # Snapshot the values about to be overwritten, so the post-transaction audit step
      # can log old -> new (docs/10).
      context[:previous_name] = collection.name if params.name
      context[:previous_description] = collection.description if params.description

      collection.name = params.name.strip if params.name
      collection.description = params.description if params.description
      # updated_at always bumps on a metadata edit, even when the new value equals the old.
      collection.updated_at = Time.zone.now
    end

    def save_metadata_changes(collection:)
      collection.save!
    end

    # docs/10: an edit is an "admin action" only when the actor needed their staff
    # standing for it — a staff member editing a collection they own is doing routine
    # owner management (the policy above lets them through as owner alone), so nothing
    # is logged. Non-staff owner edits never reach here (the audit step skips them).
    # Only values that actually changed are recorded: a PUT resubmitting the same name
    # still bumps updated_at but administers nothing. `context` holds the
    # collection-name snapshot; on a rename that is the pre-rename name, so an older row
    # keeps naming the collection as it was then (docs/10 §2).
    def audit_metadata_changes(collection:, params:, guardian:)
      actor = guardian.user
      return unless actor&.staff?
      return if CollectionPolicy.for(collection:, user: actor).owner?

      previous_name = context[:previous_name]
      if params.name && previous_name != collection.name
        StaffActionLogger.new(actor).log_custom(
          :collection_name_change,
          subject: "Collection (#{collection.id})",
          context: previous_name,
          previous_value: previous_name,
          new_value: collection.name,
        )
      end

      previous_description = context[:previous_description]
      if params.description && previous_description != collection.description
        StaffActionLogger.new(actor).log_custom(
          :collection_intro_change,
          subject: "Collection (#{collection.id})",
          context: collection.name,
          previous_value: previous_description,
          new_value: collection.description,
        )
      end
    end
  end
end
