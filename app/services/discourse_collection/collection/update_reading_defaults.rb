# frozen_string_literal: true

module DiscourseCollection
  class Collection::UpdateReadingDefaults
    include Service::Base

    params do
      attribute :id, :integer
      attribute :default_topic_sort, :string
      attribute :default_topic_order, :string

      validates :default_topic_sort, inclusion: { in: Collection::TOPIC_SORT_FIELDS }
      validates :default_topic_order, inclusion: { in: Collection::TOPIC_ORDERS }
    end

    model :collection
    policy :can_manage_reading_defaults
    step :save_defaults

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def can_manage_reading_defaults(collection:, guardian:)
      CollectionPolicy.for(collection:, user: guardian.user).can_manage_reading_defaults?
    end

    def save_defaults(collection:, guardian:, params:)
      collection.with_lock do
        # Recheck after the lock: membership may have changed while waiting.
        raise Discourse::InvalidAccess unless can_manage_reading_defaults(collection:, guardian:)
        collection.update!(
          default_topic_sort: params.default_topic_sort,
          default_topic_order: params.default_topic_order,
        )
      end
    end
  end
end
