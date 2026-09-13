# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # Daily reconciliation pass for the denormalized columns that are otherwise
    # business-layer maintained (CLAUDE hard rule 4): recomputes
    # collections.topic_count / last_topic_added_at / subscribers_count and
    # collection_topics.has_selected_reply from their source tables so any drift
    # self-heals (per-column semantics in Collection.reconcile_denormalized_state! —
    # the one materially-lowering recompute is topic_count, which drops memberships
    # whose topic core soft-deleted after collection). Runs on the mini_scheduler clock
    # once a day. Purely corrective: it never bumps updated_at, so a reconciliation
    # never masquerades as fresh collection activity in the updated_at timestamp.
    class RecomputeCollectionCounts < ::Jobs::Scheduled
      every 1.day

      def execute(_args)
        return unless SiteSetting.collection_enabled

        ::DiscourseCollection::Collection.reconcile_denormalized_state!
      end
    end
  end
end
