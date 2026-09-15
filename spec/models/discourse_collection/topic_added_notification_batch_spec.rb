# frozen_string_literal: true

RSpec.describe DiscourseCollection::TopicAddedNotificationBatch do
  fab!(:actor, :user)
  fab!(:collection) { Fabricate(:collection) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:second_topic) { Fabricate(:topic) }

  def collect(topic:, at: nil)
    attributes = { collection:, topic: }
    attributes[:created_at] = at if at
    Fabricate(:collection_topic, **attributes)
  end

  def register(topic:)
    described_class.register!(collection:, actor_user_id: actor.id, topic:)
  end

  describe ".register!" do
    it "schedules the flush one silence window out, carrying the locators" do
      freeze_time
      collect(topic:)

      expect_enqueued_with(
        job: Jobs::DiscourseCollection::NotifyTopicAdded,
        args: {
          collection_id: collection.id,
          actor_user_id: actor.id,
          topic_author_id: topic.user_id,
        },
        at: described_class::SILENCE_WINDOW.from_now,
      ) { register(topic:) }
    end

    it "stamps the run with the created_at of the row the collect inserted" do
      row = collect(topic:)

      stamp = register(topic:)

      expect(stamp).to eq(row.reload.created_at.utc.iso8601(6))
    end

    it "stamps the run of a later collect differently, so the earlier one stands down" do
      collect(topic:)
      first = register(topic:)
      collect(topic: second_topic)
      second = register(topic: second_topic)

      expect(second).not_to eq(first)
      expect(described_class.current?(collection.id, first)).to eq(false)
      expect(described_class.current?(collection.id, second)).to eq(true)
    end

    it "schedules nothing when the notification is turned off" do
      SiteSetting.collection_topic_added_notification_enabled = false
      collect(topic:)

      expect { register(topic:) }.not_to change(
        Jobs::DiscourseCollection::NotifyTopicAdded.jobs,
        :size,
      )

      expect(register(topic:)).to be_nil
    end

    it "schedules nothing when the collect was already undone" do
      expect { register(topic:) }.not_to change(
        Jobs::DiscourseCollection::NotifyTopicAdded.jobs,
        :size,
      )

      expect(register(topic:)).to be_nil
    end

    it "keeps separate stamps per collection" do
      other_collection = Fabricate(:collection)
      collect(topic:)
      Fabricate(:collection_topic, collection: other_collection, topic: second_topic)

      first = register(topic:)
      second =
        described_class.register!(
          collection: other_collection,
          actor_user_id: actor.id,
          topic: second_topic,
        )

      expect(second).not_to eq(first)
      expect(described_class.current?(other_collection.id, second)).to eq(true)
      expect(described_class.current?(collection.id, first)).to eq(true)
    end
  end

  describe ".current?" do
    it "is true for the stamp of the newest membership row" do
      collect(topic:)

      expect(described_class.current?(collection.id, register(topic:))).to eq(true)
    end

    it "is false once a later collect added a newer row" do
      collect(topic:)
      stamp = register(topic:)
      collect(topic: second_topic)

      expect(described_class.current?(collection.id, stamp)).to eq(false)
    end

    it "is false once the stamped row is un-collected, even with older rows left" do
      collect(topic: second_topic, at: 2.days.ago)
      collect(topic:)
      stamp = register(topic:)

      DiscourseCollection::CollectionTopic.where(
        collection_id: collection.id,
        topic_id: topic.id,
      ).delete_all

      expect(described_class.current?(collection.id, stamp)).to eq(false)
    end

    it "is true again when the newer row is un-collected, leaving the stamped row newest" do
      collect(topic: second_topic, at: 2.days.ago)
      stamp = register(topic: second_topic)
      collect(topic:)

      expect(described_class.current?(collection.id, stamp)).to eq(false)

      DiscourseCollection::CollectionTopic.where(
        collection_id: collection.id,
        topic_id: topic.id,
      ).delete_all

      expect(described_class.current?(collection.id, stamp)).to eq(true)
    end

    it "is false as soon as the collection has no membership left" do
      collect(topic:)
      stamp = register(topic:)

      DiscourseCollection::CollectionTopic.where(collection_id: collection.id).delete_all

      expect(described_class.current?(collection.id, stamp)).to eq(false)
    end

    it "is false for a stamp no membership carries, and for no stamp at all" do
      collect(topic:)

      expect(described_class.current?(collection.id, "2020-01-01T00:00:00.000000Z")).to eq(false)
      expect(described_class.current?(collection.id, nil)).to eq(false)
    end
  end

  describe ".claim!" do
    it "claims a stamp once, so a re-delivered run does not send again" do
      collect(topic:)
      stamp = register(topic:)

      expect(described_class.claim!(collection.id, stamp)).to eq(true)
      expect(described_class.claim!(collection.id, stamp)).to eq(false)
    end

    it "claims the next stamp after an earlier one was sent" do
      collect(topic:)
      first = register(topic:)
      described_class.claim!(collection.id, first)
      collect(topic: second_topic)
      second = register(topic: second_topic)

      expect(described_class.claim!(collection.id, second)).to eq(true)
    end
  end
end
