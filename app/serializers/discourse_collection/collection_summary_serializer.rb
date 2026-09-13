# frozen_string_literal: true

module DiscourseCollection
  # Compact list shape (docs/03 §1): the co-maintainer array is collapsed into a count
  # and the visitor-related is_teamworker boolean is added instead (full form never
  # outputs this boolean — the caller compares owner.id/teamworkers[].id instead).
  class CollectionSummarySerializer < CollectionBaseSerializer
    attributes :teamworker_count, :is_teamworker

    def teamworker_count
      @options.fetch(:teamworker_counts, {})[object.id] || 0
    end

    def is_teamworker
      @options.fetch(:teamworker_ids, []).include?(object.id)
    end
  end
end
