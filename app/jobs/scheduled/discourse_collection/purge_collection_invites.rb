# frozen_string_literal: true

module Jobs
  module DiscourseCollection
    # Physically removes collection_invites rows that fell out of the history
    # window (older than collection_invite_history_days, docs/05 §2.6). Reads
    # (record / inbox) already exclude them via CollectionInvite.within_history, so
    # without this they would pile up forever. Runs on the mini_scheduler clock once
    # a day — phase is set by when the job is first discovered, there is no fixed
    # hour, same as every core cleanup job. history_days = 0 ("keep forever")
    # makes out_of_history match nothing, so the run is a no-op. Otherwise
    # validity <= history (enforced by the setting validators) keeps the cutoff in
    # the past of any still-answerable pending row.
    class PurgeCollectionInvites < ::Jobs::Scheduled
      every 1.day

      def execute(_args)
        return unless SiteSetting.collection_enabled

        ::DiscourseCollection::CollectionInvite.out_of_history.in_batches(of: 1000).delete_all
      end
    end
  end
end
