# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::AcceptInvite do
  fab!(:owner, :user)
  fab!(:candidate, :user)
  fab!(:outsider, :user)
  fab!(:subscriber, :user)
  fab!(:admin_invitee, :admin)
  fab!(:create_group) { Fabricate(:group) }
  fab!(:teamworker_group) { Fabricate(:group) }

  TYPE_MAINTAINER = DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER
  TYPE_OWNER = DiscourseCollection::CollectionInvite::ACTION_TYPE_OWNER

  # The accept gates re-check the invitee's group membership (default settings name
  # @trust_level_1, which ordinary :user fabricators do not hold); grant candidate and
  # admin_invitee so the cap / write paths below are actually exercised.
  before do
    SiteSetting.collection_create_allowed_groups = create_group.id.to_s
    SiteSetting.collection_teamworker_allowed_groups = teamworker_group.id.to_s
    create_group.add(candidate)
    create_group.add(admin_invitee)
    teamworker_group.add(candidate)
    teamworker_group.add(admin_invitee)
  end

  # Owner + owner's auto-subscription row (docs/08 §1), mirroring what docs/03 §2 creates.
  def owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
      Fabricate(:collection_subscriber, collection:, user:)
    end
  end

  # The 21076 the invitation job leaves the invitee (docs/09 §1), invite_id included — that
  # is the key the invitation flow locates the row by once the invitation is answered.
  def invite_notification(invite)
    Notification.create!(
      user_id: invite.invitee_user_id,
      notification_type: Notification.types[:collection_invitation],
      data: {
        display_username: invite.inviter.username,
        action_type: invite.action_type,
        collection_id: invite.collection_id,
        collection_name: invite.collection.name,
        invite_id: invite.id,
      }.to_json,
      skip_send_email: true,
    )
  end

  let(:collection) { owned_collection(owner) }
  let(:invite) do
    Fabricate(:collection_invite, collection:, inviter: owner, invitee: candidate, action_type:)
  end
  let(:guardian) { Guardian.new(actor) }
  let(:dependencies) { { guardian: } }
  let(:actor) { candidate }
  let(:action_type) { TYPE_MAINTAINER }
  let(:params) { { invite_id: invite.id } }

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { invite_id: 1 } }

    context "with an invite_id" do
      it { is_expected.to be_valid }
    end

    context "without an invite_id" do
      let(:params) { {} }

      it { is_expected.not_to be_valid }
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    context "when the invite does not exist or belongs to someone else" do
      let(:actor) { outsider }

      it { is_expected.to fail_to_find_a_model(:invite) }
    end

    context "when the invite is no longer pending" do
      before { invite.update!(accept: false) }

      it { is_expected.to fail_a_step(:ensure_pending) }
    end

    context "when the invite has expired" do
      before { invite.update_column(:created_at, 20.days.ago) }

      it { is_expected.to fail_a_step(:ensure_pending) }
    end

    context "type=0 when the invitee already is the collection owner" do
      # The ownership changed after the invite was issued.
      before do
        collection.teamworkers.update_all(is_owner: false)
        Fabricate(:collection_teamworker, collection:, user: candidate, is_owner: true)
      end

      it { is_expected.to fail_a_step(:join_as_maintainer_on_accept) }
    end

    context "type=0 when the invitee is not in the teamworker-allowed groups" do
      let(:actor) { outsider }
      let(:invite) do
        Fabricate(
          :collection_invite,
          collection:,
          inviter: owner,
          invitee: outsider,
          action_type:,
        )
      end

      it { is_expected.to fail_a_step(:ensure_joiner_in_teamworker_allowed_groups) }

      it "keeps the invite pending (accept stays NULL)" do
        result
        expect(invite.reload.accept).to be_nil
      end
    end

    context "type=0 when the invitee is in the teamworker-disallowed groups" do
      fab!(:denied_group) { Fabricate(:group) }

      before do
        denied_group.add(candidate)
        SiteSetting.collection_teamworker_disallowed_groups = denied_group.id.to_s
      end

      it { is_expected.to fail_a_step(:ensure_joiner_in_teamworker_allowed_groups) }

      it "keeps the invite pending (accept stays NULL)" do
        result
        expect(invite.reload.accept).to be_nil
      end
    end

    context "type=1 when the invitee is in the create-disallowed groups" do
      fab!(:denied_group) { Fabricate(:group) }
      let(:action_type) { TYPE_OWNER }

      before do
        denied_group.add(candidate)
        SiteSetting.collection_create_disallowed_groups = denied_group.id.to_s
      end

      it { is_expected.to fail_a_step(:ensure_new_owner_in_create_allowed_groups) }

      it "keeps the invite pending (accept stays NULL)" do
        result
        expect(invite.reload.accept).to be_nil
      end
    end

    context "type=1 when the invitee is not in the create-allowed groups" do
      let(:action_type) { TYPE_OWNER }
      let(:actor) { outsider }
      let(:invite) do
        Fabricate(
          :collection_invite,
          collection:,
          inviter: owner,
          invitee: outsider,
          action_type:,
        )
      end

      it { is_expected.to fail_a_step(:ensure_new_owner_in_create_allowed_groups) }

      it "keeps the invite pending (accept stays NULL)" do
        result
        expect(invite.reload.accept).to be_nil
      end
    end

    context "type=1 when a cap-exempt invitee is still not in the create-allowed groups" do
      fab!(:restricted_group) { Fabricate(:group) }
      let(:action_type) { TYPE_OWNER }
      let(:actor) { admin_invitee }
      let(:invite) do
        Fabricate(
          :collection_invite,
          collection:,
          inviter: owner,
          invitee: admin_invitee,
          action_type:,
        )
      end

      before do
        # The unlimited-collections role exempts the cap, not the admission gate.
        SiteSetting.collection_unlimited_collections_role = "admin"
        SiteSetting.collection_create_allowed_groups = restricted_group.id.to_s
      end

      it { is_expected.to fail_a_step(:ensure_new_owner_in_create_allowed_groups) }
    end

    context "when the candidate accepts a type=0 invite" do
      it { is_expected.to run_successfully }

      it "adds the invitee as a co-maintainer and marks the invite accepted" do
        expect { result }.to change {
          DiscourseCollection::CollectionTeamworker.where(
            collection_id: collection.id,
            user_id: candidate.id,
            is_owner: false,
          ).count
        }.by(1)

        expect(invite.reload.accept).to eq(true)
      end

      it "bumps the collection updated_at (team change is collection activity)" do
        collection.update!(updated_at: 2.days.ago)

        result

        expect(collection.reload.updated_at).to be > 1.day.ago
      end

      it "does not touch subscribers_count" do
        expect { result }.not_to change { collection.reload.subscribers_count }
      end

      it "enqueues the 21077 accepted job for the inviter" do
        expect { result }.to change(
          Jobs::DiscourseCollection::NotifyInvitationResult.jobs,
          :size,
        ).by(1)
      end

      it "does not log an owner change (type=0 is a maintainer join)" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_owner_change").count
        }
      end
    end

    context "when the invitee already is a co-maintainer (type=0, idempotent)" do
      before do
        Fabricate(:collection_teamworker, collection:, user: candidate, is_owner: false)
        collection.update!(updated_at: 2.days.ago)
      end

      it { is_expected.to run_successfully }

      it "keeps a single membership row and still marks the invite accepted" do
        expect {
          result
        }.not_to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id, user_id: candidate.id).count
        }

        expect(invite.reload.accept).to eq(true)
        expect(collection.reload.updated_at).to be < 1.day.ago
      end

      it "still enqueues the result job when the accept is a membership no-op" do
        expect { result }.to change(
          Jobs::DiscourseCollection::NotifyInvitationResult.jobs,
          :size,
        ).by(1)
      end
    end

    context "when the candidate accepts a type=1 invite" do
      let(:action_type) { TYPE_OWNER }

      before { Fabricate(:collection_subscriber, collection:, user: candidate) }

      it { is_expected.to run_successfully }

      it "promotes the invitee, demotes the old owner and recomputes the count" do
        result

        owner_row =
          DiscourseCollection::CollectionTeamworker.find_by(collection_id: collection.id, user_id: owner.id)
        candidate_row =
          DiscourseCollection::CollectionTeamworker.find_by(
            collection_id: collection.id,
            user_id: candidate.id,
          )

        expect(owner_row.is_owner).to eq(false)
        expect(candidate_row.is_owner).to eq(true)
        expect(invite.reload.accept).to eq(true)
        # subscribers after the switch: the old owner's row (demoted -> now counted)
        # plus the new owner's kept row — but the new owner's never counts (docs/08 §1).
        # 2 rows - 1 (the new owner's) = 1.
        expect(collection.reload.subscribers_count).to eq(1)
      end

      it "does not log an owner change for an owner-initiated transfer (routine)" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_owner_change").count
        }
      end
    end

    context "when staff issued the type=1 invite and the invitee accepts" do
      fab!(:staff, :admin)
      let(:action_type) { TYPE_OWNER }
      let(:invite) do
        Fabricate(:collection_invite, collection:, inviter: staff, invitee: candidate, action_type:)
      end

      it { is_expected.to run_successfully }

      it "logs a collection_owner_change audit row with the staff inviter acting and the new owner as target" do
        result

        history = UserHistory.find_by(custom_type: "collection_owner_change")
        expect(history).to be_present
        expect(history.action).to eq(UserHistory.actions[:custom_staff])
        expect(history.acting_user_id).to eq(staff.id)
        expect(history.target_user_id).to eq(candidate.id)
        expect(history.subject).to eq("Collection (#{collection.id})")
        expect(history.context).to eq(collection.name)
        expect(history.previous_value).to eq(owner.username)
        expect(history.new_value).to eq(candidate.username)
      end
    end

    context "type=1 when the candidate already owns more collections than the collection cap" do
      let(:action_type) { TYPE_OWNER }

      before do
        SiteSetting.collection_max_collections_per_user = 1
        owned_collection(candidate)
        owned_collection(candidate)
      end

      it { is_expected.to fail_a_step(:ensure_new_owner_within_collection_cap) }

      it "keeps the invite pending (accept stays NULL)" do
        result
        expect(invite.reload.accept).to be_nil
      end
    end

    context "type=1 when the candidate owns exactly the cap" do
      let(:action_type) { TYPE_OWNER }

      before do
        # Accept lands the candidate at cap+1 — the single extra this path allows.
        SiteSetting.collection_max_collections_per_user = 1
        owned_collection(candidate)
      end

      it { is_expected.to run_successfully }
    end

    context "type=1 when an exempt invitee already exceeds the collection cap" do
      let(:action_type) { TYPE_OWNER }
      let(:actor) { admin_invitee }
      let(:invite) do
        Fabricate(:collection_invite, collection:, inviter: owner, invitee: admin_invitee, action_type:)
      end

      before do
        SiteSetting.collection_max_collections_per_user = 1
        SiteSetting.collection_unlimited_collections_role = "admin"
        owned_collection(admin_invitee)
        owned_collection(admin_invitee)
      end

      it { is_expected.to run_successfully }
    end

    # 21076 is a question waiting to be answered; answering it ends the question, and core's
    # own cleanup cannot reach a notification carrying no topic_id.
    context "when the invitee holds a notification for this invitation" do
      # Seen recently, so core counts them as live and actually publishes their state
      # (User#allow_live_notifications?).
      let(:candidate) { Fabricate(:user, last_seen_at: 1.day.ago) }
      # The other of the two invitations one person can hold for the same collection at
      # once — a transfer invite alongside the maintainer invite being accepted here. Only
      # invite_id tells their notifications apart.
      let(:other_invite) do
        Fabricate(
          :collection_invite,
          collection:,
          inviter: owner,
          invitee: candidate,
          action_type: TYPE_OWNER,
        )
      end

      it "deletes the invitee's notification for the accepted invitation" do
        notification = invite_notification(invite)

        expect { result }.to change { Notification.exists?(id: notification.id) }.to(false)
      end

      it "leaves the other pending invitation's notification alone" do
        accepted = invite_notification(invite)
        awaiting = invite_notification(other_invite)

        result

        expect(Notification.exists?(id: accepted.id)).to eq(false)
        expect(Notification.exists?(id: awaiting.id)).to eq(true)
      end

      it "publishes the notification state of the invitee it emptied" do
        invite_notification(invite)

        channels = MessageBus.track_publish { result }.map(&:channel)

        expect(channels).to include("/notification/#{candidate.id}")
      end
    end
  end
end
