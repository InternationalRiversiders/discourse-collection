# frozen_string_literal: true

module DiscourseCollection
  # Full collection shape (docs/03 §1): used by detail (docs/03 §4) and, later, by create/
  # update/change-owner responses. Carries the full co-maintainer array (owner excluded).
  class CollectionSerializer < CollectionBaseSerializer
    attributes :teamworkers, :default_topic_sort, :default_topic_order

    def teamworkers
      (@options.fetch(:co_worker_users, {})[object.id] || []).map do |user|
        ::BasicUserSerializer.new(user, scope:, root: false).as_json
      end
    end
  end
end
