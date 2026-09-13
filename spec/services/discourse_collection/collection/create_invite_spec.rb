# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::CreateInvite do
  fab!(:owner, :user)
  fab!(:co_worker, :user)
  fab!(:candidate, :user)
  fab!(:outsider, :user)
  fab!(:admin, :admin)

  TYPE_MAINTAINER = DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER
  TYPE_OWNER = DiscourseCollection::CollectionInvite::ACTION_TYPE_OWNER

  fab!(:create_group) { Fabricate(:group) }
  fab!(:teamworker_group) { Fabricate(:group) }

  # The invite gates check the TARGET's group membership (the default @trust_level_1
  # would block ordinary :user fabricators); grant candidate so the existing cap and
  # write paths below are actually exercised.
  before do
    SiteSetting.collection_create_allowed_groups = create_group.id.to_s
    SiteSetting.collection_teamworker_allowed_groups = teamworker_group.id.to_s
    create_group.add(candidate)
    teamworker_group.add(candidate)
  end

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1, user_id: 2, action_type: TYPE_MAINTAINER } }

    context "with id, user_id and a valid action_type" do
      it { is_expected.to be_valid }
    end

    context "without an action_type" do
      let(:params) { { id: 1, user_id: 2 } }

      it { is_expected.not_to be_valid }
    end

    context "with an invalid action_type" do
      let(:params) { { id: 1, user_id: 2, action_type: 9 } }

      it "rejects it" do
        expect(contract).not_to be_valid
        expect(contract.errors[:base]).to include(
          I18n.t("discourse_collection.errors.invite_action_type_invalid"),
        )
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) { add_owned_collection(owner) }
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_MAINTAINER } }

    context "when the collection does not exist" do
      let(:params) { { id: -999, user_id: candidate.id, action_type: TYPE_MAINTAINER } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the target is not a registered user" do
      let(:params) { { id: collection.id, user_id: -999, action_type: TYPE_MAINTAINER } }

      it { is_expected.to fail_to_find_a_model(:invitee) }
    end

    context "when the acting user is not the owner (type=0)" do
      let(:actor) { outsider }

      it { is_expected.to fail_a_policy(:can_create_invite) }
    end

    context "type=0 on an ownerless collection (even staff cannot)" do
      let(:collection) { Fabricate(:collection) }
      let(:actor) { admin }

      it { is_expected.to fail_a_policy(:can_create_invite) }
    end

    context "when the owner invites themselves (type=1)" do
      let(:params) { { id: collection.id, user_id: owner.id, action_type: TYPE_OWNER } }

      it { is_expected.to fail_a_step(:ensure_user_is_not_the_inviter) }
    end

    context "type=1 by staff on an ownerless collection designates a first owner" do
      let(:collection) { Fabricate(:collection) }
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      it { is_expected.to run_successfully }
    end

    context "type=0 when the target is already a co-maintainer" do
      before do
        Fabricate(:collection_teamworker, collection:, user: candidate, is_owner: false)
      end

      it { is_expected.to fail_a_step(:ensure_user_is_not_yet_maintainer) }
    end

    context "type=0 when the co-maintainer cap is reached" do
      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
      end

      it { is_expected.to fail_a_step(:ensure_under_maintainer_cap) }
    end

    context "type=0 when a live pending type=0 invite holds the last spot" do
      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        Fabricate(:collection_invite, collection:, inviter: owner, invitee: co_worker, action_type: TYPE_MAINTAINER)
      end

      it { is_expected.to fail_a_step(:ensure_under_maintainer_cap) }
    end

    context "type=0 issued by an owner who is exempt from the cap" do
      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        SiteSetting.collection_unlimited_teamworkers_role = "admin"
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
      end

      let(:actor) { admin }
      let(:collection) { add_owned_collection(admin) }

      it { is_expected.to run_successfully }
    end

    context "type=1 when another ownership invite is already pending" do
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        Fabricate(:collection_invite, collection:, inviter: owner, invitee: co_worker, action_type: TYPE_OWNER)
      end

      it { is_expected.to fail_a_step(:ensure_no_pending_ownership_invite) }
    end

    context "when an admin takes a collection over by inviting themselves (docs/05 §2.7)" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      before { create_group.add(admin) }

      it { is_expected.to run_successfully }

      it "lands the transfer now and leaves an accepted self-invite behind" do
        expect { result }.to change { DiscourseCollection::CollectionInvite.count }.by(1)

        invite = DiscourseCollection::CollectionInvite.last
        expect(invite.collection_id).to eq(collection.id)
        expect(invite.inviter_user_id).to eq(admin.id)
        expect(invite.invitee_user_id).to eq(admin.id)
        expect(invite.action_type).to eq(TYPE_OWNER)
        expect(invite.accept).to eq(true)

        new_owner =
          DiscourseCollection::CollectionTeamworker.find_by(
            collection_id: collection.id,
            user_id: admin.id,
          )
        expect(new_owner.is_owner).to eq(true)

        previous_owner =
          DiscourseCollection::CollectionTeamworker.find_by(
            collection_id: collection.id,
            user_id: owner.id,
          )
        expect(previous_owner.is_owner).to eq(false)
      end

      it "subscribes the new owner without counting them, and bumps updated_at" do
        collection.update!(updated_at: 2.days.ago)

        result

        expect(
          DiscourseCollection::CollectionSubscriber.exists?(
            collection_id: collection.id,
            user_id: admin.id,
          ),
        ).to eq(true)
        expect(collection.reload.subscribers_count).to eq(0)
        expect(collection.updated_at).to be > 1.day.ago
      end

      it "sends no invitation notification" do
        expect { result }.not_to change(
          Jobs::DiscourseCollection::NotifyInvitation.jobs,
          :size,
        )
      end

      it "logs the ownership change right away" do
        expect { result }.to change {
          UserHistory.where(custom_type: "collection_owner_change").count
        }.by(1)

        history = UserHistory.find_by(custom_type: "collection_owner_change")
        expect(history.acting_user_id).to eq(admin.id)
        expect(history.target_user_id).to eq(admin.id)
        expect(history.previous_value).to eq(owner.username)
        expect(history.new_value).to eq(admin.username)
      end
    end

    context "when an admin takes over an ownerless collection (docs/05 §2.7)" do
      let(:collection) { Fabricate(:collection) }
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      before { create_group.add(admin) }

      it { is_expected.to run_successfully }

      it "becomes the first owner with no previous owner on the audit row" do
        result

        owner_row =
          DiscourseCollection::CollectionTeamworker.find_by(
            collection_id: collection.id,
            user_id: admin.id,
          )
        expect(owner_row.is_owner).to eq(true)
        expect(UserHistory.find_by(custom_type: "collection_owner_change").previous_value).to be_nil
      end
    end

    context "when a moderator takes a collection over (docs/05 §2.7)" do
      fab!(:moderator, :moderator)
      let(:actor) { moderator }
      let(:params) { { id: collection.id, user_id: moderator.id, action_type: TYPE_OWNER } }

      context "with the manage-moderation setting on" do
        before do
          SiteSetting.collection_moderators_can_manage_collections = true
          create_group.add(moderator)
        end

        it { is_expected.to run_successfully }
      end

      context "with the manage-moderation setting off" do
        before do
          SiteSetting.collection_moderators_can_manage_collections = false
          create_group.add(moderator)
        end

        it { is_expected.to fail_a_policy(:can_create_invite) }
      end
    end

    context "when staff already own the collection they invite themselves to (docs/05 §2.7)" do
      let(:collection) { add_owned_collection(admin) }
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      before { create_group.add(admin) }

      it { is_expected.to fail_a_step(:ensure_inviter_is_not_the_owner) }
    end

    context "when another ownership invite is already pending (docs/05 §2.7)" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      before do
        create_group.add(admin)
        Fabricate(:collection_invite, collection:, inviter: owner, invitee: candidate, action_type: TYPE_OWNER)
      end

      it { is_expected.to fail_a_step(:ensure_no_pending_ownership_invite) }
    end

    context "when the staff member is not in the create-allowed groups (docs/05 §2.7)" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      # admin is deliberately left out of create_group here.
      it { is_expected.to fail_a_step(:ensure_new_owner_in_create_allowed_groups) }
    end

    context "when the staff member already owns more collections than the cap (docs/05 §2.7)" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      before do
        SiteSetting.collection_max_collections_per_user = 1
        create_group.add(admin)
        add_owned_collection(admin)
        add_owned_collection(admin)
      end

      it { is_expected.to fail_a_step(:ensure_new_owner_within_collection_cap) }
    end

    context "when a takeover would push the co-maintainers past the cap (docs/05 §2.7)" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: admin.id, action_type: TYPE_OWNER } }

      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        create_group.add(admin)
        # cap=1 -> two co-maintainers is already one over; demoting the owner would
        # land the collection at cap+2.
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
        Fabricate(:collection_teamworker, collection:, user: outsider, is_owner: false)
      end

      it { is_expected.to fail_a_step(:ensure_ownership_transfer_within_teamworker_cap) }
    end

    context "when the owner issues a type=0 invite" do
      it { is_expected.to run_successfully }

      it "creates a pending invite row without touching collection activity" do
        collection.update!(updated_at: 2.days.ago)

        expect { result }.to change { DiscourseCollection::CollectionInvite.count }.by(1)

        invite = DiscourseCollection::CollectionInvite.last
        expect(invite.collection_id).to eq(collection.id)
        expect(invite.inviter_user_id).to eq(owner.id)
        expect(invite.invitee_user_id).to eq(candidate.id)
        expect(invite.action_type).to eq(TYPE_MAINTAINER)
        expect(invite.accept).to be_nil
        expect(invite.pending?).to eq(true)
        expect(collection.reload.updated_at).to be < 1.day.ago
      end

      it "enqueues the 21076 invitation job" do
        expect { result }.to change(
          Jobs::DiscourseCollection::NotifyInvitation.jobs,
          :size,
        ).by(1)
      end
    end

    context "when the owner issues a type=1 self-transfer invite" do
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      it { is_expected.to run_successfully }
    end

    context "type=1 plain transfer when co-maintainers already exceed the cap" do
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        # cap=1 -> 2 co-maintainers is already one over; accepting would demote the
        # owner and land at cap+2.
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
        Fabricate(:collection_teamworker, collection:, user: outsider, is_owner: false)
      end

      it { is_expected.to fail_a_step(:ensure_ownership_transfer_within_teamworker_cap) }
    end

    context "type=1 plain transfer at exactly cap co-maintainers" do
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        # cap=1 with 1 co-maintainer: accepting demotes the owner and lands at cap+1,
        # the single extra this path is allowed to reach.
        SiteSetting.collection_max_teamworkers_per_collection = 1
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
      end

      it { is_expected.to run_successfully }
    end

    context "type=1 on an ownerless collection even when co-maintainers exceed the cap" do
      let(:collection) { Fabricate(:collection) }
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
        Fabricate(:collection_teamworker, collection:, user: outsider, is_owner: false)
      end

      it { is_expected.to run_successfully }
    end

    context "type=1 promoting an existing co-maintainer even when the count exceeds the cap" do
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
        Fabricate(:collection_teamworker, collection:, user: candidate, is_owner: false)
      end

      it { is_expected.to run_successfully }
    end

    context "type=1 by an exempt owner when the count exceeds the cap" do
      let(:collection) { add_owned_collection(admin) }
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        SiteSetting.collection_max_teamworkers_per_collection = 1
        SiteSetting.collection_unlimited_teamworkers_role = "admin"
        Fabricate(:collection_teamworker, collection:, user: co_worker, is_owner: false)
        Fabricate(:collection_teamworker, collection:, user: outsider, is_owner: false)
      end

      it { is_expected.to run_successfully }
    end

    context "type=0 when the target is not in the teamworker-allowed groups" do
      let(:params) { { id: collection.id, user_id: outsider.id, action_type: TYPE_MAINTAINER } }

      it { is_expected.to fail_a_step(:ensure_target_in_teamworker_allowed_groups) }
    end

    context "type=0 when the teamworker-allowed group list is empty (disabled for everyone)" do
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_MAINTAINER } }

      before { SiteSetting.collection_teamworker_allowed_groups = "" }

      it { is_expected.to fail_a_step(:ensure_target_in_teamworker_allowed_groups) }
    end

    context "type=0 when the target is in the teamworker-disallowed groups" do
      fab!(:denied_group) { Fabricate(:group) }
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_MAINTAINER } }

      before do
        denied_group.add(candidate)
        SiteSetting.collection_teamworker_disallowed_groups = denied_group.id.to_s
      end

      it { is_expected.to fail_a_step(:ensure_target_in_teamworker_allowed_groups) }
    end

    context "type=1 when the target is not in the create-allowed groups" do
      let(:params) { { id: collection.id, user_id: outsider.id, action_type: TYPE_OWNER } }

      it { is_expected.to fail_a_step(:ensure_target_in_create_allowed_groups) }
    end

    context "type=1 when the target is in the create-disallowed groups" do
      fab!(:denied_group) { Fabricate(:group) }
      let(:params) { { id: collection.id, user_id: candidate.id, action_type: TYPE_OWNER } }

      before do
        denied_group.add(candidate)
        SiteSetting.collection_create_disallowed_groups = denied_group.id.to_s
      end

      it { is_expected.to fail_a_step(:ensure_target_in_create_allowed_groups) }
    end

    context "type=1 when a cap-exempt owner still cannot invite a target outside the create-allowed groups" do
      let(:collection) { add_owned_collection(admin) }
      let(:actor) { admin }
      let(:params) { { id: collection.id, user_id: outsider.id, action_type: TYPE_OWNER } }

      before do
        # The unlimited-teamworkers role exempts the cap, not the admission gate.
        SiteSetting.collection_unlimited_teamworkers_role = "admin"
      end

      it { is_expected.to fail_a_step(:ensure_target_in_create_allowed_groups) }
    end
  end
end
