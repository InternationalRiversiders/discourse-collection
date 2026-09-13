# frozen_string_literal: true

RSpec.describe Jobs::DiscourseCollection::RecomputeCollectionCounts do
  fab!(:collection) { Fabricate(:collection) }

  subject(:run_job) { described_class.new.execute({}) }

  # collection_topics.created_at is stamped by ActiveRecord at insert; rewind it
  # afterwards so memberships land at controlled, distinguishable times.
  def collect(topic, at:)
    Fabricate(:collection_topic, collection:, topic:)
      .tap { |membership| membership.update_column(:created_at, at) }
  end

  it "lowers topic_count to live topics while last_topic_added_at keeps every membership" do
    live = Fabricate(:topic)
    deleted = Fabricate(:topic)
    collect(live, at: 3.days.ago)
    collect(deleted, at: 1.day.ago)
    deleted.update_column(:deleted_at, 12.hours.ago)

    collection.update_column(:topic_count, 12) # drifted high: includes the deleted topic
    collection.update_column(:last_topic_added_at, 10.days.ago)
    collection.update_column(:updated_at, 5.days.ago)

    run_job

    # Soft-deleted topic no longer counts (reading page hides it the same way)...
    expect(collection.reload.topic_count).to eq(1)
    # ...but last_topic_added_at follows the existing remove-time semantic: the newest
    # membership over ALL rows, which here is the (now deleted) topic.
    expect(collection.reload.last_topic_added_at).to be_within(1.second).of(1.day.ago)
    # This statement really rewrote topic_count + last_topic_added_at, yet updated_at must
    # stay 5 days back: any AR-object save or an explicit updated_at=now would jump ~5 days
    # away and fail the within-1s assertion.
    expect(collection.reload.updated_at).to be_within(1.second).of(5.days.ago)
  end

  it "recounts subscribers excluding the owner's own row and never touches updated_at" do
    owner = Fabricate(:user)
    Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    # The owner auto-subscribes in the real flow; their row exists but does not count.
    Fabricate(:collection_subscriber, collection:, user: owner)
    fan = Fabricate(:user)
    Fabricate(:collection_subscriber, collection:, user: fan)

    collection.update_column(:subscribers_count, 9)
    collection.update_column(:updated_at, 3.days.ago)

    run_job

    expect(collection.reload.subscribers_count).to eq(1)
    # A drift-repair pass is not collection activity: updated_at stays where it was.
    expect(collection.reload.updated_at).to be_within(1.second).of(3.days.ago)
  end

  it "recomputes has_selected_reply from whether a selected-reply row exists" do
    t1 = Fabricate(:topic)
    t2 = Fabricate(:topic)
    flagged = collect(t1, at: 3.days.ago)
    unflagged = collect(t2, at: 3.days.ago)
    flagged.update_column(:has_selected_reply, true) # flagged but has no rows -> drop
    Fabricate(
      :collection_topic_selected_reply,
      collection:,
      topic: t2,
      post: Fabricate(:post, topic: t2),
    ) # has a row but is not flagged -> raise
    # collection_topics carries its own updated_at; rewind it far into the past so a
    # regression that bumps it while flipping the flag is caught (a fresh row's ≈now value
    # would be indistinguishable from a bump to now).
    flagged.update_column(:updated_at, 5.days.ago)
    unflagged.update_column(:updated_at, 5.days.ago)

    run_job

    expect(flagged.reload.has_selected_reply).to eq(false)
    expect(unflagged.reload.has_selected_reply).to eq(true)
    # Both statements really flipped the flag on their row; updated_at must stay 5 days back.
    expect(flagged.reload.updated_at).to be_within(1.second).of(5.days.ago)
    expect(unflagged.reload.updated_at).to be_within(1.second).of(5.days.ago)
  end

  it "is idempotent: a second run rewrites nothing once values are correct" do
    collect(Fabricate(:topic), at: 2.days.ago)
    collection.update_column(:topic_count, 7)
    collection.update_column(:updated_at, 2.days.ago)

    run_job

    expect(collection.reload.topic_count).to eq(1)
    expect(collection.reload.updated_at).to be_within(1.second).of(2.days.ago)
    before = collection.reload.attributes.slice("topic_count", "subscribers_count", "last_topic_added_at")

    run_job

    expect(collection.reload.attributes.slice("topic_count", "subscribers_count", "last_topic_added_at")).to eq(before)
    expect(collection.reload.updated_at).to be_within(1.second).of(2.days.ago)
  end

  context "when the plugin is disabled" do
    before { SiteSetting.collection_enabled = false }

    it "leaves drift untouched" do
      collect(Fabricate(:topic), at: 2.days.ago)
      collection.update_column(:topic_count, 7)

      run_job

      expect(collection.reload.topic_count).to eq(7)
    end
  end
end
