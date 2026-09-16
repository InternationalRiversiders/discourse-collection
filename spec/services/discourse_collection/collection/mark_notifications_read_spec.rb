# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::MarkNotificationsRead do
  # Seen recently, so core counts them as live and actually publishes their state
  # (User#allow_live_notifications?).
  fab!(:user) { Fabricate(:user, last_seen_at: 1.day.ago) }
  fab!(:other_user) { Fabricate(:user, last_seen_at: 1.day.ago) }

  def add_owned_collection(owner)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    end
  end

  # A notification row the way this plugin writes it (docs/09 §1): the type plus the locator
  # keys, no topic_id. `collection:` defaults to the one under test, so only the rows that
  # pass it explicitly are about somewhere else.
  def create_notification(recipient, type, collection: self.collection, read: false)
    Notification.create!(
      user_id: recipient.id,
      notification_type: Notification.types[type],
      data: {
        display_username: collection.name,
        collection_id: collection.id,
      }.to_json,
      read:,
      skip_send_email: true,
    )
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { id: 1 } }

    context "with an id" do
      it { is_expected.to be_valid }
    end

    context "without an id" do
      let(:params) { {} }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:id]).to be_present
      end
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) { add_owned_collection(other_user) }
    let(:guardian) { Guardian.new(user) }
    let(:dependencies) { { guardian: } }
    let(:params) { { id: collection.id } }

    context "when the collection does not exist" do
      let(:params) { { id: -999 } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the caller has unread notifications about the collection" do
      # The three types that point at the collection page (docs/09 §1).
      let!(:notifications) do
        [
          create_notification(user, :collection_topic_added),
          create_notification(user, :collection_invitation_accepted),
          create_notification(user, :collection_invitation_declined),
        ]
      end

      it { is_expected.to run_successfully }

      it "marks all of them read" do
        expect { result }.to change { Notification.where(id: notifications.map(&:id)).unread.count }
          .from(3)
          .to(0)
      end

      it "publishes the caller's notification state" do
        channels = MessageBus.track_publish { result }.map(&:channel)

        expect(channels).to include("/notification/#{user.id}")
      end
    end

    # Nothing about the collection is unread, or nothing is unread at all: the write is
    # skipped and there is no state change to publish.
    context "when the caller has nothing unread about the collection" do
      let!(:already_read) { create_notification(user, :collection_topic_added, read: true) }
      let!(:other_collection_notification) do
        create_notification(user, :collection_topic_added, collection: add_owned_collection(user))
      end

      it { is_expected.to run_successfully }

      it "publishes nothing" do
        expect(MessageBus.track_publish { result }).to be_empty
      end

      it "leaves the notification about the other collection unread" do
        expect { result }.not_to change { other_collection_notification.reload.read }
      end
    end

    # 21076 points at the invitation inbox, not at the collection page, and is deleted
    # outright when it is answered or revoked — the mark must not reach it. 21077 / 21078
    # do point at the collection page and are marked like the subscription type.
    context "with notifications the endpoint must not touch" do
      let(:other_collection) { add_owned_collection(other_user) }
      let!(:bystanders) do
        [
          create_notification(user, :collection_invitation),
          create_notification(user, :liked),
          create_notification(user, :collection_topic_added, collection: other_collection),
          create_notification(other_user, :collection_topic_added),
        ]
      end

      before { create_notification(user, :collection_topic_added) }

      it "leaves every other row unread" do
        expect { result }.not_to change {
          Notification.where(id: bystanders.map(&:id)).unread.count
        }
      end

      it "publishes only for the caller" do
        channels = MessageBus.track_publish { result }.map(&:channel)

        expect(channels).to eq(["/notification/#{user.id}"])
      end
    end

    context "when run twice" do
      before do
        create_notification(user, :collection_topic_added)
        # The first run: it reads the row, so the subject below is the second one.
        described_class.call(params:, **dependencies)
      end

      it { is_expected.to run_successfully }

      it "publishes nothing on the second run" do
        expect(MessageBus.track_publish { result }).to be_empty
      end
    end
  end
end
