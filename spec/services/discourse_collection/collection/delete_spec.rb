# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::Delete do
  fab!(:owner, :user)
  fab!(:outsider, :user)
  fab!(:admin, :admin)

  def add_owned_collection(user)
    Fabricate(:collection).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  # A notification row the way this plugin writes it (docs/09 §1): the type plus the locator
  # keys, no topic_id. `collection:` defaults to the one under test, so only the rows that
  # pass it explicitly are about somewhere else.
  def create_notification(user, type, collection: self.collection)
    Notification.create!(
      user_id: user.id,
      notification_type: Notification.types[type],
      data: {
        display_username: collection.name,
        collection_id: collection.id,
      }.to_json,
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

    let(:collection) { add_owned_collection(owner) }
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id } }

    context "when the collection does not exist" do
      let(:params) { { id: -999 } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the acting user is an outsider" do
      let(:actor) { outsider }

      it { is_expected.to fail_a_policy(:can_delete_collection) }
    end

    context "when the acting user is staff but not the owner" do
      let(:actor) { admin }

      it "does not let staff delete someone else's collection" do
        is_expected.to fail_a_policy(:can_delete_collection)
      end
    end

    context "when the acting user is the owner" do
      it { is_expected.to run_successfully }

      it "deletes the collection" do
        collection # materialize the lazy let before the change matcher snapshots the count

        expect { result }.to change { DiscourseCollection::Collection.count }.by(-1)
      end

      it "cascades to the membership and subscriber rows" do
        Fabricate(:collection_teamworker, collection:, user: outsider, is_owner: false)
        Fabricate(:collection_subscriber, collection:, user: outsider)

        expect { result }.to change {
          DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count
        }.to(0).and change {
          DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).count
        }.to(0)
      end
    end

    # Notifications are the one child row the foreign keys cannot carry away — they live in
    # the core table — so the delete purges them itself, and inside its own transaction.
    context "when the collection has notifications" do
      # Seen recently, so core counts them as live and actually publishes their state
      # (User#allow_live_notifications?).
      let(:subscriber1) { Fabricate(:user, last_seen_at: 1.day.ago) }
      let(:subscriber2) { Fabricate(:user, last_seen_at: 1.day.ago) }
      let(:other_collection) { add_owned_collection(outsider) }

      # One row of each type the plugin writes, all located the same way: nothing but
      # collection_id inside data, so nothing else identifies them either.
      let(:plugin_notifications) do
        [
          create_notification(subscriber1, :collection_topic_added),
          create_notification(subscriber1, :collection_invitation),
          create_notification(subscriber2, :collection_invitation_accepted),
          create_notification(subscriber2, :collection_invitation_declined),
        ]
      end

      # A core type carrying the same collection_id, and a plugin type pointing at another
      # collection. Neither one is about the collection being deleted.
      let(:bystanders) do
        [
          create_notification(subscriber1, :liked),
          create_notification(subscriber1, :collection_topic_added, collection: other_collection),
        ]
      end

      it "deletes every notification about the collection, whatever its type" do
        ids = (plugin_notifications + bystanders).map(&:id)

        expect { result }.to change { Notification.where(id: ids).count }.from(6).to(2)
      end

      it "publishes the notification state of every user it emptied" do
        plugin_notifications

        channels = MessageBus.track_publish { result }.map(&:channel)

        expect(channels).to include(
          "/notification/#{subscriber1.id}",
          "/notification/#{subscriber2.id}",
        )
      end

      it "keeps the notifications when the delete does not go through" do
        ids = plugin_notifications.map(&:id)

        allow_any_instance_of(DiscourseCollection::Collection).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed,
        )

        expect { result }.to raise_error(ActiveRecord::RecordNotDestroyed)
        expect(Notification.where(id: ids).count).to eq(4)
      end
    end
  end
end
