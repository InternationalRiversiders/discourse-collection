# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::RevokeInvite do
  fab!(:owner, :user)
  fab!(:candidate, :user)
  fab!(:outsider, :user)
  fab!(:admin, :admin)
  fab!(:moderator, :moderator)

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  # The audit row of a proxy revocation (docs/10 §1).
  def revoke_log
    UserHistory.find_by(custom_type: "collection_invite_revoke")
  end

  def stored_invite
    DiscourseCollection::CollectionInvite.find_by(id: invite.id)
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

  let(:collection) { add_owned_collection(owner) }
  let(:invite) do
    Fabricate(:collection_invite, collection:, inviter: owner, invitee: candidate)
  end
  let(:guardian) { Guardian.new(actor) }
  let(:dependencies) { { guardian: } }
  let(:actor) { owner }
  let(:params) { { id: collection.id, invite_id: invite.id } }

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1, invite_id: 2 } }

    context "with an id and invite_id" do
      it { is_expected.to be_valid }
    end

    context "without an invite_id" do
      let(:params) { { id: 1 } }

      it { is_expected.not_to be_valid }
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    context "when the collection does not exist" do
      let(:params) { { id: -999, invite_id: invite.id } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the invite is not in the collection from the URL" do
      let(:other_collection) { add_owned_collection(candidate) }
      let(:params) { { id: other_collection.id, invite_id: invite.id } }

      it { is_expected.to fail_to_find_a_model(:invite) }
    end

    context "when the invite was already accepted" do
      before { invite.update!(accept: true) }

      it { is_expected.to fail_a_step(:ensure_pending) }
    end

    context "when the invite has expired" do
      before { invite.update_column(:created_at, 20.days.ago) }

      it { is_expected.to fail_a_step(:ensure_pending) }
    end

    context "when the acting user is not the initiator" do
      let(:actor) { outsider }

      it { is_expected.to fail_a_policy(:can_revoke) }
    end

    # The collection owner runs the collection, never the invitations of others
    # (docs/05 §2.2): revoking someone else's call is a management action.
    context "when the collection owner is not the initiator and holds no staff role" do
      let(:actor) { owner }
      let(:invite) do
        Fabricate(:collection_invite, collection:, inviter: outsider, invitee: candidate)
      end

      it { is_expected.to fail_a_policy(:can_revoke) }
    end

    context "when the initiator account is gone (FK SET NULL)" do
      before { invite.update!(inviter_user_id: nil) }

      context "when the acting user is not staff" do
        let(:actor) { outsider }

        it { is_expected.to fail_a_policy(:can_revoke) }
      end

      context "when a staff manager revokes it" do
        let(:actor) { admin }

        it { is_expected.to run_successfully }

        it "logs the action with the unnameable side marked" do
          result

          expect(revoke_log.target_user_id).to be_nil
          expect(revoke_log.details).to eq("❌ + #{candidate.username}")
        end
      end
    end

    context "when the initiator revokes their own pending invite" do
      it { is_expected.to run_successfully }

      it "deletes the row" do
        expect { result }.to change { stored_invite }.to(nil)
      end

      it "logs nothing — withdrawing one's own call is not a management action" do
        result

        expect(revoke_log).to be_nil
      end
    end

    # 21076 is a question waiting to be answered; a revoked invitation stops being one, and
    # core's own cleanup cannot reach a notification carrying no topic_id.
    context "when the invitee holds a notification for this invitation" do
      # Seen recently, so core counts them as live and actually publishes their state
      # (User#allow_live_notifications?).
      let(:candidate) { Fabricate(:user, last_seen_at: 1.day.ago) }
      # A second, still-awaiting invitation for the same collection and the invitee: nothing
      # but invite_id tells the two apart.
      let(:other_invite) do
        Fabricate(:collection_invite, collection:, inviter: owner, invitee: candidate)
      end

      it "deletes the invitee's notification for the revoked invitation" do
        notification = invite_notification(invite)

        expect { result }.to change { Notification.exists?(id: notification.id) }.to(false)
      end

      it "leaves the other pending invitation's notification alone" do
        revoked = invite_notification(invite)
        awaiting = invite_notification(other_invite)

        result

        expect(Notification.exists?(id: revoked.id)).to eq(false)
        expect(Notification.exists?(id: awaiting.id)).to eq(true)
      end

      it "leaves another type's notification for the inviter alone" do
        notification =
          Notification.create!(
            user_id: owner.id,
            notification_type: Notification.types[:collection_invitation_accepted],
            data: { collection_id: collection.id }.to_json,
            skip_send_email: true,
          )

        result

        expect(Notification.exists?(id: notification.id)).to eq(true)
      end

      it "publishes the notification state of the invitee it emptied" do
        invite_notification(invite)

        channels = MessageBus.track_publish { result }.map(&:channel)

        expect(channels).to include("/notification/#{candidate.id}")
      end

      it "keeps the notification when the revoke does not go through" do
        notification = invite_notification(invite)

        allow_any_instance_of(DiscourseCollection::CollectionInvite).to receive(
          :destroy!,
        ).and_raise(ActiveRecord::RecordNotDestroyed)

        expect { result }.to raise_error(ActiveRecord::RecordNotDestroyed)
        expect(Notification.exists?(id: notification.id)).to eq(true)
      end
    end

    context "when a staff manager revokes someone else's invitation" do
      let(:actor) { admin }
      let(:invite) do
        Fabricate(:collection_invite, collection:, inviter: outsider, invitee: candidate)
      end

      it { is_expected.to run_successfully }

      it "deletes the row" do
        expect { result }.to change { stored_invite }.to(nil)
      end

      it "logs the management action against the issuer" do
        result

        expect(revoke_log).to have_attributes(
          action: UserHistory.actions[:custom_staff],
          acting_user_id: admin.id,
          target_user_id: outsider.id,
          subject: "Collection (#{collection.id})",
          context: collection.name,
          # type=0 reads as "who asked + whom they asked" (docs/10 §1).
          details: "#{outsider.username} + #{candidate.username}",
          previous_value: nil,
          new_value: nil,
        )
      end
    end

    context "when a staff manager revokes a pending ownership invitation" do
      let(:actor) { admin }
      let(:invite) do
        Fabricate(
          :collection_invite,
          collection:,
          inviter: owner,
          invitee: candidate,
          action_type: DiscourseCollection::CollectionInvite::ACTION_TYPE_OWNER,
        )
      end

      it "logs the transfer that was called off" do
        result

        expect(revoke_log.details).to eq("#{owner.username} → #{candidate.username}")
      end
    end

    context "when the acting user is a moderator" do
      let(:actor) { moderator }
      let(:invite) do
        Fabricate(:collection_invite, collection:, inviter: outsider, invitee: candidate)
      end

      context "with collection_moderators_can_manage_collections off" do
        it { is_expected.to fail_a_policy(:can_revoke) }
      end

      context "with collection_moderators_can_manage_collections on" do
        before { SiteSetting.collection_moderators_can_manage_collections = true }

        it { is_expected.to run_successfully }
      end
    end
  end
end
