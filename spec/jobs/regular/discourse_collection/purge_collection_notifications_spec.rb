# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::PurgeCollectionNotifications do
  # Seen recently, so core counts them as live and actually publishes their state
  # (User#allow_live_notifications?).
  fab!(:subscriber1) { Fabricate(:user, last_seen_at: 1.day.ago) }
  fab!(:subscriber2) { Fabricate(:user, last_seen_at: 1.day.ago) }
  fab!(:collection) { Fabricate(:collection) }
  fab!(:other_collection) { Fabricate(:collection) }

  subject(:run_job) { described_class.new.execute(collection_id: collection.id) }

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
  # collection. Neither one is about the collection it was given.
  let(:bystanders) do
    [
      create_notification(subscriber1, :liked),
      create_notification(subscriber1, :collection_topic_added, collection: other_collection),
    ]
  end

  it "deletes every notification about the collection, whatever its type" do
    ids = (plugin_notifications + bystanders).map(&:id)

    expect { run_job }.to change { Notification.where(id: ids).count }.from(6).to(2)
  end

  it "publishes the notification state of every user it emptied" do
    plugin_notifications

    channels = MessageBus.track_publish { run_job }.map(&:channel)

    expect(channels).to include(
      "/notification/#{subscriber1.id}",
      "/notification/#{subscriber2.id}",
    )
  end

  # A retry after a partial run, or a second run of the same enqueue, must not resurrect or
  # disturb anything.
  it "is a no-op once there is nothing left to delete" do
    plugin_notifications
    run_job

    expect { run_job }.not_to change { Notification.count }
  end

  it "does nothing without a collection id" do
    plugin_notifications

    expect { described_class.new.execute({}) }.not_to change { Notification.count }
  end
end
