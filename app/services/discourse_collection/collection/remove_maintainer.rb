# frozen_string_literal: true

module DiscourseCollection
  # DELETE /collections/:id/teamworkers/:user_id.json — remove a co-maintainer.
  #
  # Two callers share this endpoint (docs/02 §3): the collection owner removing any
  # co-maintainer, and a co-maintainer removing themself (= leaving / 自助离队). A
  # co-maintainer may only target themself — removing a teammate still requires the
  # owner. The target must be a registered user (else 404) and currently hold an
  # is_owner=false membership row (else 422, non-idempotent, docs/02). The owner row
  # is managed exclusively through the invitation flow — ownership changes go via a
  # type=1 invite (docs/05 §2) — so removing the owner as a co-maintainer is
  # rejected (an owner cannot delete themself here either; leaving as owner is the
  # transfer flow of docs/05 §2). Membership removal and the updated_at bump happen in one
  # transaction.
  class Collection::RemoveMaintainer
    include Service::Base

    params do
      attribute :id, :integer
      attribute :user_id, :integer

      validates :id, :user_id, presence: true
    end

    model :collection
    model :target_user, :fetch_target_user
    policy :can_manage_maintainers

    transaction do
      step :ensure_user_is_not_the_owner
      step :ensure_user_is_a_maintainer
      step :destroy_maintainer_membership
      step :mark_collection_activity
    end

    private

    def fetch_collection(params:)
      Collection.find_by(id: params.id)
    end

    def fetch_target_user(params:)
      User.find_by(id: params.user_id)
    end

    def can_manage_maintainers(collection:, target_user:, guardian:)
      actor = guardian.user
      return false if actor.blank?

      # A co-maintainer may remove themself (= leave the collection); targeting anyone
      # else is the owner's privilege.
      return true if target_user.id == actor.id

      CollectionPolicy.for(collection:, user: actor).owner?
    end

    def ensure_user_is_not_the_owner(collection:, target_user:)
      is_owner =
        CollectionTeamworker
          .where(collection_id: collection.id, user_id: target_user.id, is_owner: true)
          .exists?
      if is_owner
        fail!(I18n.t("discourse_collection.errors.owner_membership_change_not_allowed"))
      end
    end

    def ensure_user_is_a_maintainer(collection:, target_user:)
      is_maintainer =
        CollectionTeamworker
          .where(collection_id: collection.id, user_id: target_user.id, is_owner: false)
          .exists?
      if !is_maintainer
        fail!(I18n.t("discourse_collection.errors.not_a_maintainer"))
      end
    end

    def destroy_maintainer_membership(collection:, target_user:)
      membership =
        CollectionTeamworker.find_by!(
          collection_id: collection.id,
          user_id: target_user.id,
          is_owner: false,
        )
      membership.destroy!
    end

    def mark_collection_activity(collection:)
      # Reflects the team change on the collection's updated_at (docs/08); the membership
      # row was already removed above.
      collection.update!(updated_at: Time.zone.now)
    end
  end
end
