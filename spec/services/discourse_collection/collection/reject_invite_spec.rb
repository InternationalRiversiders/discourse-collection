# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::RejectInvite do
  fab!(:owner, :user)
  fab!(:candidate, :user)
  fab!(:outsider, :user)

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
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

  let(:collection) { add_owned_collection(owner) }
  let(:invite) do
    Fabricate(:collection_invite, collection:, inviter: owner, invitee: candidate)
  end
  let(:guardian) { Guardian.new(actor) }
  let(:dependencies) { { guardian: } }
  let(:actor) { candidate }
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
      before { invite.update!(accept: true) }

      it { is_expected.to fail_a_step(:ensure_pending) }
    end

    context "when the candidate rejects their pending invite" do
      it { is_expected.to run_successfully }

      it "records accept=false and writes no membership row" do
        expect { result }.not_to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count
        }

        expect(invite.reload.accept).to eq(false)
      end

      it "enqueues the 21078 declined job for the inviter" do
        expect { result }.to change(
          Jobs::DiscourseCollection::NotifyInvitationResult.jobs,
          :size,
        ).by(1)
      end
    end

    # 21076 is a question waiting to be answered; turning it down ends the question, and
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

      it "deletes the invitee's notification for the rejected invitation" do
        notification = invite_notification(invite)

        expect { result }.to change { Notification.exists?(id: notification.id) }.to(false)
      end

      it "leaves the other pending invitation's notification alone" do
        rejected = invite_notification(invite)
        awaiting = invite_notification(other_invite)

        result

        expect(Notification.exists?(id: rejected.id)).to eq(false)
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
