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
