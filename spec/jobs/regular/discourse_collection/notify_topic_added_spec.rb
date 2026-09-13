# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::NotifyTopicAdded do
  fab!(:author, :user)
  fab!(:actor, :user)
  fab!(:subscriber1, :user)
  fab!(:subscriber2, :user)
  fab!(:collection) { Fabricate(:collection) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:membership) { Fabricate(:collection_topic, collection:, topic:) }
  fab!(:subscription1) do
    Fabricate(:collection_subscriber, collection:, user: subscriber1)
  end
  fab!(:subscription2) do
    Fabricate(:collection_subscriber, collection:, user: subscriber2)
  end

  NOTIFICATION_TYPE = Notification.types[:collection_topic_added]

  # The collect that opened the batch. One collect both stamps the batch and hands the job
  # its actor, so both are derived from this — overriding only one of them would exercise a
  # run production never schedules.
  let(:batch_actor) { actor }
  let(:batch_stamp) { register_batch }
  let(:job_args) do
    {
      collection_id: collection.id,
      stamp: batch_stamp,
      actor_user_id: batch_actor.id,
      topic_author_id: author.id,
    }
  end
  subject(:run_job) { described_class.new.execute(**job_args) }

  def collect(topic:, at: nil)
    attributes = { collection:, topic: }
    attributes[:created_at] = at if at
    Fabricate(:collection_topic, **attributes)
  end

  def register_batch(actor_user_id: batch_actor.id, topic: self.topic)
    DiscourseCollection::TopicAddedNotificationBatch.register!(
      collection:,
      actor_user_id:,
      topic:,
    )
  end

  def unnotify(topic:)
    DiscourseCollection::CollectionTopic.where(
      collection_id: collection.id,
      topic_id: topic.id,
    ).delete_all
  end

  def notifications_for(user)
    Notification.where(user_id: user.id, notification_type: NOTIFICATION_TYPE)
  end

  it "creates a collection_topic_added notification for every subscriber" do
    expect { run_job }.to change { Notification.count }.by(2)
    expect(notifications_for(subscriber1).count).to eq(1)
    expect(notifications_for(subscriber2).count).to eq(1)
  end

  it "anchors the notification to the collection, not to any one topic" do
    run_job

    notification = notifications_for(subscriber1).last
    expect(notification.topic_id).to be_nil
    expect(JSON.parse(notification.data)).to eq(
      "display_username" => collection.name,
      "collection_id" => collection.id,
    )
  end

  it "sends once per stamp — a re-delivered run sends nothing" do
    run_job

    expect { described_class.new.execute(**job_args) }.not_to change { Notification.count }
  end

  context "when a later collect stamped the batch anew" do
    let(:batch_stamp) do
      superseded = register_batch
      later = Fabricate(:topic)
      collect(topic: later)
      register_batch(topic: later)
      superseded
    end

    it "sends nothing — the burst is still open" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the collect that opened the run was undone" do
    let(:batch_stamp) do
      stamp = register_batch
      unnotify(topic:)
      stamp
    end

    it "sends nothing — undoing the collect undoes its notification" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when some older collect was undone instead" do
    let(:batch_stamp) do
      older = Fabricate(:topic)
      collect(topic: older, at: 2.days.ago)
      stamp = register_batch
      unnotify(topic: older)
      stamp
    end

    it "still sends — the newest collect is untouched" do
      expect { run_job }.to change { Notification.count }.by(2)
      expect(notifications_for(subscriber1).count).to eq(1)
      expect(notifications_for(subscriber2).count).to eq(1)
    end
  end

  context "when the acting user subscribes" do
    let(:batch_actor) { subscriber2 }

    it "skips that subscriber" do
      expect { run_job }.to change { Notification.count }.by(1)
      expect(notifications_for(subscriber1).count).to eq(1)
      expect(notifications_for(subscriber2).count).to eq(0)
    end
  end

  context "when a subscriber ignores the author of the collected topic (docs/09 §2)" do
    before do
      IgnoredUser.create!(
        user_id: subscriber2.id,
        ignored_user_id: author.id,
        expiring_at: 1.year.from_now,
      )
    end

    it "skips subscribers who ignore a non-staff OP" do
      expect { run_job }.to change { Notification.count }.by(1)
      expect(notifications_for(subscriber1).count).to eq(1)
      expect(notifications_for(subscriber2).count).to eq(0)
    end

    context "when the OP is staff" do
      before { author.update!(admin: true) }

      it "does not apply the ignore exclusion" do
        expect { run_job }.to change { Notification.count }.by(2)
        expect(notifications_for(subscriber2).count).to eq(1)
      end
    end

    context "when the ignore has expired" do
      before do
        IgnoredUser
          .find_by(user_id: subscriber2.id, ignored_user_id: author.id)
          .update!(expiring_at: 1.day.ago)
      end

      it "does not exclude (only active ignores fold the OP's topics)" do
        expect { run_job }.to change { Notification.count }.by(2)
        expect(notifications_for(subscriber2).count).to eq(1)
      end
    end
  end

  context "when the collection no longer exists" do
    let(:job_args) { super().merge(collection_id: -999) }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the only subscriber is excluded" do
    let(:batch_actor) { subscriber1 }

    # Deleting the let_it_be-shared fab! instance itself would hit the composite-key
    # destroy path; delete by primary key the way production code does.
    before do
      DiscourseCollection::CollectionSubscriber
        .where(collection_id: collection.id, user_id: subscriber2.id)
        .delete_all
    end

    it "creates nothing once no recipient is left" do
      expect { run_job }.not_to change { Notification.count }
    end
  end
end
