# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::NotifyTopicAdded do
  fab!(:author, :user)
  fab!(:actor, :user)
  # Last seen recently, so core counts them as live and actually publishes their state
  # (User#allow_live_notifications?).
  fab!(:subscriber1) { Fabricate(:user, last_seen_at: 1.day.ago) }
  fab!(:subscriber2) { Fabricate(:user, last_seen_at: 1.day.ago) }
  fab!(:collection) { Fabricate(:collection) }
  fab!(:topic) { Fabricate(:topic, user: author) }
  fab!(:subscription1) do
    Fabricate(:collection_subscriber, collection:, user: subscriber1)
  end
  fab!(:subscription2) do
    Fabricate(:collection_subscriber, collection:, user: subscriber2)
  end

  NOTIFICATION_TYPE = Notification.types[:collection_topic_added]

  let(:job_args) do
    { collection_id: collection.id, topic_id: topic.id, actor_user_id: actor.id }
  end
  subject(:run_job) { described_class.new.execute(**job_args) }

  # A row the way a previous run would have left it — no topic_id, the two locator keys only.
  def stored_notification(user, collection: self.collection, at: nil, read: false)
    now = at || Time.zone.now

    Notification.create!(
      user_id: user.id,
      notification_type: NOTIFICATION_TYPE,
      data: { display_username: collection.name, collection_id: collection.id }.to_json,
      read: read,
      created_at: now,
      updated_at: now,
      skip_send_email: true,
    )
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

  it "notifies once however often the same run is delivered" do
    run_job

    expect { described_class.new.execute(**job_args) }.not_to change { Notification.count }
    expect(notifications_for(subscriber1).count).to eq(1)
    expect(notifications_for(subscriber2).count).to eq(1)
  end

  context "when a subscriber already holds a notification for this collection" do
    let!(:existing) { stored_notification(subscriber2, at: 3.days.ago, read: true) }

    it "reuses that row instead of adding another one" do
      expect { run_job }.to change { Notification.count }.by(1)

      expect(notifications_for(subscriber2).pluck(:id)).to eq([existing.id])
      expect(notifications_for(subscriber1).count).to eq(1)
    end

    it "moves the row back to the top and marks it unread again" do
      run_job

      refreshed = existing.reload
      expect(refreshed.read).to eq(false)
      expect(refreshed.created_at).to be_within(1.second).of(Time.zone.now)
    end

    it "re-reads the collection name into the first line" do
      collection.update!(name: "Renamed collection")

      run_job

      expect(JSON.parse(existing.reload.data)["display_username"]).to eq("Renamed collection")
    end

    context "when the subscriber holds more than one row for this collection" do
      let!(:newer) { stored_notification(subscriber2) }

      it "keeps the highest id and drops the duplicates" do
        # Net zero: the duplicate goes (−1), subscriber1 gains a row (+1).
        expect { run_job }.to change { Notification.count }.by(0)

        expect(notifications_for(subscriber2).pluck(:id)).to eq([newer.id])
      end

      it "leaves the duplicates of another collection alone" do
        other = Fabricate(:collection)
        other_row = stored_notification(subscriber2, collection: other)

        run_job

        expect(Notification.exists?(other_row.id)).to eq(true)
      end
    end
  end

  context "when a subscriber's row was refreshed" do
    before { stored_notification(subscriber2, at: 3.days.ago) }

    # update_all bypasses the callbacks the live notification state is published from.
    it "pushes the refreshed subscriber's state" do
      messages =
        MessageBus.track_publish("/notification/#{subscriber2.id}") { run_job }

      expect(messages.size).to eq(1)
    end

    # BulkCreate publishes for the rows it inserts, so the job must not push for them too.
    it "leaves the push for a new row to BulkCreate, exactly once" do
      messages =
        MessageBus.track_publish("/notification/#{subscriber1.id}") { run_job }

      expect(messages.size).to eq(1)
    end
  end

  context "when the acting user subscribes" do
    let(:job_args) { super().merge(actor_user_id: subscriber2.id) }

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

  context "when the topic sits in an unrestricted category" do
    it "answers from the topic alone, without asking each recipient's Guardian" do
      Guardian.any_instance.expects(:can_see_topic?).never

      run_job
    end
  end

  context "when the topic sits in a restricted category" do
    fab!(:group)
    fab!(:category) { Fabricate(:private_category, group:) }
    let(:topic) { Fabricate(:topic, user: author, category:) }

    context "when only some subscribers may see it" do
      before { group.add(subscriber1) }

      it "notifies only those subscribers" do
        expect { run_job }.to change { Notification.count }.by(1)
        expect(notifications_for(subscriber1).count).to eq(1)
        expect(notifications_for(subscriber2).count).to eq(0)
      end

      it "neither floats nor unreads the existing row of a subscriber who may not" do
        existing = stored_notification(subscriber2, at: 3.days.ago, read: true)

        run_job

        expect(existing.reload.read).to eq(true)
        expect(existing.reload.created_at).to be_within(1.second).of(3.days.ago)
      end
    end

    context "when no subscriber may see it" do
      it "writes nothing at all" do
        expect { run_job }.not_to change { Notification.count }
      end
    end
  end

  # Unlisted is a listing rule, not a read rule: the reading page keeps such a topic for
  # whoever may list it, namely staff and TL4. The notification follows the same rule, and
  # per recipient — the fast path cannot answer it, since the topic belongs to some
  # subscribers and not others.
  context "when the topic is unlisted" do
    let(:topic) do
      Fabricate(:topic, user: author).tap { |unlisted| unlisted.update_column(:visible, false) }
    end

    it "notifies nobody when no subscriber may list it" do
      expect { run_job }.not_to change { Notification.count }
    end

    it "neither floats nor unreads the existing row of a subscriber who may not list it" do
      existing = stored_notification(subscriber2, at: 3.days.ago, read: true)

      run_job

      expect(existing.reload.read).to eq(true)
      expect(existing.reload.created_at).to be_within(1.second).of(3.days.ago)
    end

    context "when a subscriber may list unlisted topics" do
      fab!(:lister) { Fabricate(:user, trust_level: TrustLevel[4]) }
      fab!(:listers_subscription) { Fabricate(:collection_subscriber, collection:, user: lister) }

      it "notifies that subscriber only" do
        expect { run_job }.to change { Notification.count }.by(1)

        expect(notifications_for(lister).count).to eq(1)
        expect(notifications_for(subscriber1).count).to eq(0)
        expect(notifications_for(subscriber2).count).to eq(0)
      end
    end
  end

  # A deleted topic is listed by the reading page to nobody — its feed joins on
  # topics.deleted_at IS NULL — so it notifies nobody either, staff included. Settled before
  # the recipients are asked, because can_see_topic? does serve a deleted topic to a
  # moderator of its category.
  context "when the collected topic has been deleted" do
    let(:topic) do
      Fabricate(:topic, user: author).tap { |gone| gone.update_column(:deleted_at, Time.zone.now) }
    end

    it "notifies nobody, staff subscribers included" do
      Fabricate(:collection_subscriber, collection:, user: Fabricate(:admin))

      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the collection no longer exists" do
    let(:job_args) { super().merge(collection_id: -999) }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the topic no longer exists" do
    let(:job_args) { super().merge(topic_id: -999) }

    it "creates nothing" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  context "when the only subscriber is excluded" do
    # Deleting the fab!-shared instance itself would hit the composite-key destroy path;
    # delete by primary key the way production code does.
    before do
      DiscourseCollection::CollectionSubscriber
        .where(collection_id: collection.id, user_id: subscriber2.id)
        .delete_all
    end

    let(:job_args) { super().merge(actor_user_id: subscriber1.id) }

    it "creates nothing once no recipient is left" do
      expect { run_job }.not_to change { Notification.count }
    end
  end

  # None of this plugin's four types mails: the new rows are handed to BulkCreate with
  # skip_send_email rather than leaning on core having no EmailUser method named after the
  # type.
  it "processes no email" do
    NotificationEmailer.expects(:process_notification).never

    run_job
  end

  context "when a recipient is in do not disturb mode" do
    before do
      Fabricate(
        :do_not_disturb_timing,
        user: subscriber1,
        starts_at: 1.hour.ago,
        ends_at: 1.hour.from_now,
      )
    end

    it "shelves nothing" do
      expect { run_job }.not_to change { ShelvedNotification.count }
    end
  end
end
