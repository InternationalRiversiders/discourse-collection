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

      # The notifications about a deleted collection are the one child row the foreign keys
      # cannot carry away (they live in the core table), and the lookup that finds them has no
      # index behind it — so the delete hands them to a job and returns (docs/09 §4).
      it "enqueues the notification cleanup for the deleted collection" do
        expect { result }.to change(
          Jobs::DiscourseCollection::PurgeCollectionNotifications.jobs,
          :size,
        ).by(1)

        args = Jobs::DiscourseCollection::PurgeCollectionNotifications.jobs.last["args"].first

        expect(args["collection_id"]).to eq(collection.id)
      end
    end

    # What the job does with them is the job's own spec; here it is only the handoff that is
    # under test — the delete must not wait for the purge, and must not enqueue one for a
    # delete that never happened.
    context "when the collection has notifications" do
      it "leaves every notification about the collection for the job" do
        notification = create_notification(outsider, :collection_topic_added)

        expect { result }.not_to change { Notification.where(id: notification.id).count }
      end

      it "enqueues nothing when the delete does not go through" do
        allow_any_instance_of(DiscourseCollection::Collection).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed,
        )

        expect { result }.to raise_error(ActiveRecord::RecordNotDestroyed)
        expect(Jobs::DiscourseCollection::PurgeCollectionNotifications.jobs).to be_empty
      end
    end
  end
end
