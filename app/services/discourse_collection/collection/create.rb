# frozen_string_literal: true

module DiscourseCollection
  # docs/03 §2 POST /collections.json — create a collection owned by the acting user.
  #
  # Business rules (docs/03 §2): name is trimmed and validated against the
  # [min, max] length settings (inclusive); description is capped by its own max.
  # The per-user collection cap (is_owner=true rows) is enforced unless the acting user
  # is exempt via collection_unlimited_collections_role. The collection row, its owner
  # membership row and the owner's auto-subscription row are created in one
  # transaction (docs/08 §1 — the owner subscribes but never counts).
  class Collection::Create
    include Service::Base

    params do
      attribute :name, :string
      attribute :description, :string, default: ""

      before_validation { self.name = name&.strip }

      validate :name_is_valid
      validate :description_is_valid

      private

      def name_is_valid
        if name.blank?
          errors.add(:base, I18n.t("discourse_collection.errors.name_blank"))
          return
        end

        min = SiteSetting.collection_name_min_length
        max = SiteSetting.collection_name_max_length
        if name.length < min || name.length > max
          errors.add(
            :base,
            I18n.t("discourse_collection.errors.name_out_of_range", min:, max:),
          )
        end
      end

      def description_is_valid
        max = SiteSetting.collection_description_max_length
        if description.length > max
          errors.add(
            :base,
            I18n.t("discourse_collection.errors.description_out_of_range", max:),
          )
        end
      end
    end

    model :collection, :build_collection
    policy :can_create_collection

    transaction do
      step :ensure_under_collection_limit
      step :persist_collection
      step :record_owner_membership
      step :record_owner_subscription
    end

    private

    def build_collection(params:)
      Collection.new(name: params.name, description: params.description)
    end

    def can_create_collection(guardian:)
      CollectionPolicy.allowed_to_create_collections?(guardian.user)
    end

    def ensure_under_collection_limit(guardian:)
      return if CollectionPolicy.exempt_from_collection_cap?(guardian.user)

      max = SiteSetting.collection_max_collections_per_user
      owned = CollectionTeamworker.where(user_id: guardian.user.id, is_owner: true).count
      if owned >= max
        fail!(I18n.t("discourse_collection.errors.collection_limit_reached", max:))
      end
    end

    def persist_collection(collection:)
      collection.save!
    end

    def record_owner_membership(collection:, guardian:)
      CollectionTeamworker.create!(
        collection_id: collection.id,
        user_id: guardian.user.id,
        is_owner: true,
      )
    end

    def record_owner_subscription(collection:, guardian:)
      # docs/08 §1: the owner auto-subscribes to their own collection (single row in
      # collection_subscribers) but is the only subscriber who never counts towards
      # subscribers_count — which stays 0 here (default column value), since no other
      # subscription rows exist yet.
      CollectionSubscriber.create!(collection_id: collection.id, user_id: guardian.user.id)
    end
  end
end
