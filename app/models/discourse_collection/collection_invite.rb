# frozen_string_literal: true

module DiscourseCollection
  # Invitation flow row (docs/05 §2): "invite X as co-maintainer
  # (action_type=0) / as new owner (action_type=1)", answered by the invitee.
  # accept is NULL (pending) | true (accepted) | false (rejected). A surrogate key
  # is appropriate here — this is a process table with a state evolution, not a pure
  # join table (CLAUDE hard rule 1). One row never went through answering: a staff
  # self-takeover (docs/05 §2.7) is written already accepted, with inviter and
  # invitee the same user — it is the record of the takeover, not a question.
  #
  # Lifecycle is governed by two site settings, both measured from created_at:
  #   collection_invite_validity_days — window during which a NULL-accept row may
  #     still be answered; after it, the row is "expired" (kept, not answerable).
  #   collection_invite_history_days  — how long rows are kept at all; older rows
  #     are out of scope for every read (physically cleaned up by the scheduled
  #     Jobs::DiscourseCollection::PurgeCollectionInvites job, docs/05 §2.6).
  #     0 = keep rows forever (retention disabled).
  class CollectionInvite < ActiveRecord::Base
    self.table_name = "collection_invites"

    ACTION_TYPE_MAINTAINER = 0 # invite to become a co-maintainer
    ACTION_TYPE_OWNER = 1 # invite to become the new owner

    belongs_to :collection, class_name: "DiscourseCollection::Collection"
    # Both users may be gone (their FKs are ON DELETE SET NULL), so the rows are
    # optional; an invite whose issuer was deleted can still be revoked by staff
    # holding the management role (docs/05 §2.2).
    belongs_to :inviter, class_name: "User", foreign_key: :inviter_user_id, optional: true
    belongs_to :invitee, class_name: "User", foreign_key: :invitee_user_id, optional: true

    # --- the two time gates (single source for services, serializers and specs) ---

    def self.validity_days
      SiteSetting.collection_invite_validity_days
    end

    def self.history_days
      SiteSetting.collection_invite_history_days
    end

    # Still answerable rows: accept IS NULL and created_at still inside the validity
    # window (docs/05 §2.6: [0, validity] answerable, (validity, history] expired).
    def self.valid_pending(now: Time.zone.now)
      where(accept: nil).where("created_at > ?", now - validity_days.days)
    end

    # Rows kept by the reads (record / inbox): everything younger than the history
    # window — pending, expired, accepted and rejected alike. history_days = 0
    # ("keep forever") keeps every row in scope.
    def self.within_history(now: Time.zone.now)
      return all if history_days <= 0
      where("created_at > ?", now - history_days.days)
    end

    # Rows the scheduled purge deletes — the exact complement of within_history
    # (created_at <= now - history_days), covering every status. With history_days =
    # 0 ("keep forever") nothing matches. A row this old is necessarily past its
    # validity window as well (validity <= history is enforced by the setting
    # validators), so a still-answerable pending row can never be targeted. Only
    # PurgeCollectionInvites should delete these (docs/05 §2.6).
    def self.out_of_history(now: Time.zone.now)
      return none if history_days <= 0
      where("created_at <= ?", now - history_days.days)
    end

    def expires_at
      created_at + self.class.validity_days.days
    end

    def expired?(now: Time.zone.now)
      accept.nil? && expires_at <= now
    end

    def pending?(now: Time.zone.now)
      accept.nil? && !expired?(now:)
    end

    # Status exposed to the API (docs/05 §2.3 / §2.4): pending | expired |
    # accepted | rejected.
    def status(now: Time.zone.now)
      return "accepted" if accept == true
      return "rejected" if accept == false

      expired?(now:) ? "expired" : "pending"
    end
  end
end

# == Schema Information
#
# Table name: collection_invites
#
#  id               :integer          not null, primary key
#  action_type      :integer          not null
#  accept           :boolean
#  collection_id    :integer          not null
#  inviter_user_id  :integer
#  invitee_user_id  :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_collection_invites_on_collection_id_and_created_at   (collection_id,created_at)
#  index_collection_invites_on_invitee_user_id_and_created_at (invitee_user_id,created_at)
#
# Foreign Keys
#
#  collection_invites_collection_id_fkey  (collection_id => collections.id) ON DELETE => cascade
#  collection_invites_inviter_user_id_fkey (inviter_user_id => users.id) ON DELETE => nullify
#  collection_invites_invitee_user_id_fkey (invitee_user_id => users.id) ON DELETE => nullify
