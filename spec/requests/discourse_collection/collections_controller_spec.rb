# frozen_string_literal: true

RSpec.describe DiscourseCollection::CollectionsController do
  fab!(:user)
  fab!(:other_user) { Fabricate(:user) }
  fab!(:stranger) { Fabricate(:user) }
  fab!(:admin, :admin)
  fab!(:moderator, :moderator)

  def build_collection(name:, owner: nil, last_topic_added_at: nil)
    collection = Fabricate(:collection, name:, last_topic_added_at:)
    if owner
      Fabricate(:collection_teamworker, collection: collection, user: owner, is_owner: true)
    end
    collection
  end

  def add_co_worker(collection, worker)
    Fabricate(:collection_teamworker, collection: collection, user: worker, is_owner: false)
  end

  # docs/08 §1: subscriber_count is a stored column (`collections.subscribers_count`)
  # maintained by the write path; a real subscribe bumps it +1. None of the users added
  # through this helper is a collection owner, so the helper mirrors that +1.
  def add_subscriber(collection, subscriber)
    Fabricate(:collection_subscriber, collection: collection, user: subscriber)
    collection.update!(subscribers_count: (collection.subscribers_count || 0) + 1)
  end

  def payload_collection_by_id(payload, id)
    payload["collections"].find { |row| row["id"] == id }
  end

  describe "#index" do
    let(:now) { Time.zone.now }

    it "is disabled when collection_enabled is off" do
      SiteSetting.collection_enabled = false
      sign_in(user)

      get "/collections.json"

      expect(response.status).to eq(404)
    end

    context "when anonymous access is disabled" do
      before { SiteSetting.collection_allow_anonymous = false }

      it "rejects anonymous visitors with a 404" do
        get "/collections.json"

        expect(response.status).to eq(404)
      end
    end

    context "when anonymous access is enabled" do
      before { SiteSetting.collection_allow_anonymous = true }

      it "lets anonymous visitors list collections" do
        build_collection(name: "Public", owner: other_user)

        get "/collections.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["collections"].length).to eq(1)
        expect(payload["collections"].first["name"]).to eq("Public")
      end
    end

    context "when signed in" do
      before { sign_in(user) }

      let(:owned_collection) { build_collection(name: "Owned", owner: user, last_topic_added_at: now) }
      let(:maintained_collection) do
        build_collection(name: "Maintained", owner: other_user, last_topic_added_at: now - 2.hours)
      end
      let(:subscribed_collection) do
        build_collection(name: "Subscribed", owner: other_user, last_topic_added_at: now - 3.hours)
      end
      let(:empty_collection) { build_collection(name: "Empty") }

      it "returns collections sorted by last_topic_added_at desc, nulls last, with meta" do
        subscribed_collection
        maintained_collection
        owned_collection
        empty_collection

        get "/collections.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body

        expect(payload["collections"].map { |row| row["name"] }).to eq(
          %w[Owned Maintained Subscribed Empty],
        )
        expect(payload["meta"]).to eq(
          { "page" => 0, "page_size" => 30, "more" => false, "total" => 4 },
        )
      end

      it "sorts ascending and by other whitelisted columns" do
        subscribed_collection
        maintained_collection
        owned_collection

        get "/collections.json", params: { sort: "created_at", order: "asc" }

        expect(response.status).to eq(200)
        expect(payload_collection_by_id(response.parsed_body, owned_collection.id)).to be_present
      end

      it "sorts by subscriber_count (stored column subscribers_count)" do
        owned_collection # subscriber_count 0
        build_collection(name: "Few", owner: other_user).tap do |collection|
          add_subscriber(collection, user)
          add_subscriber(collection, stranger)
        end
        build_collection(name: "Many", owner: other_user).tap do |collection|
          add_subscriber(collection, user)
          add_subscriber(collection, stranger)
          add_subscriber(collection, admin)
        end

        get "/collections.json", params: { sort: "subscriber_count", order: "asc" }

        expect(response.status).to eq(200)
        expect(
          response.parsed_body["collections"].map do |row|
            [row["name"], row["subscriber_count"]]
          end,
        ).to eq([["Owned", 0], ["Few", 2], ["Many", 3]])

        get "/collections.json", params: { sort: "subscriber_count", order: "desc" }

        expect(response.status).to eq(200)
        expect(
          response.parsed_body["collections"].map { |row| [row["name"], row["subscriber_count"]] },
        ).to eq([["Many", 3], ["Few", 2], ["Owned", 0]])
      end

      it "carries counts and visitor booleans" do
        add_co_worker(maintained_collection, user)
        add_subscriber(subscribed_collection, user)
        add_subscriber(owned_collection, other_user)

        get "/collections.json"

        payload = response.parsed_body
        owned_row = payload_collection_by_id(payload, owned_collection.id)
        maintained_row = payload_collection_by_id(payload, maintained_collection.id)
        subscribed_row = payload_collection_by_id(payload, subscribed_collection.id)

        expect(owned_row["teamworker_count"]).to eq(0)
        expect(owned_row["subscriber_count"]).to eq(1)
        expect(owned_row["is_teamworker"]).to eq(false)
        expect(owned_row["is_subscribed"]).to eq(false)
        expect(owned_row["owner"]["username"]).to eq(user.username)

        expect(maintained_row["teamworker_count"]).to eq(1)
        expect(maintained_row["is_teamworker"]).to eq(true)

        expect(subscribed_row["subscriber_count"]).to eq(1)
        expect(subscribed_row["is_subscribed"]).to eq(true)
      end

      it "filters to collections the given username created or maintains" do
        owned_collection
        add_co_worker(maintained_collection, user)
        build_collection(name: "Foreign", owner: other_user)

        get "/collections.json", params: { username: user.username }

        expect(response.status).to eq(200)
        payload = response.parsed_body
        names = payload["collections"].map { |row| row["name"] }

        expect(names).to contain_exactly("Owned", "Maintained")
        expect(payload["meta"]["total"]).to eq(2)
      end

      it "returns an empty list for an unknown username" do
        owned_collection

        get "/collections.json", params: { username: "ghost_user" }

        expect(response.status).to eq(200)
        expect(response.parsed_body["collections"]).to eq([])
      end

      it "rejects an unknown sort with a 400" do
        get "/collections.json", params: { sort: "bumped_at" }

        expect(response.status).to eq(400)
      end

      it "rejects an invalid order with a 400" do
        get "/collections.json", params: { order: "sideways" }

        expect(response.status).to eq(400)
      end

      it "paginates" do
        owned_collection
        build_collection(name: "Second", owner: user, last_topic_added_at: now - 1.hour)

        get "/collections.json", params: { page: 1, page_size: 1 }

        expect(response.status).to eq(200)
        expect(response.parsed_body["collections"].length).to eq(1)
        expect(response.parsed_body["meta"]).to include("page" => 1, "page_size" => 1)
      end
    end
  end

  describe "#show" do
    let(:collection) do
      build_collection(name: "Detail", owner: other_user, last_topic_added_at: Time.zone.now).tap do |collection|
        add_co_worker(collection, user)
      end
    end

    it "is disabled when collection_enabled is off" do
      SiteSetting.collection_enabled = false
      sign_in(user)

      get "/collections/#{collection.id}.json"

      expect(response.status).to eq(404)
    end

    context "when anonymous access is disabled" do
      it "rejects anonymous visitors with a 404" do
        get "/collections/#{collection.id}.json"

        expect(response.status).to eq(404)
      end
    end

    context "when signed in" do
      before { sign_in(user) }

      it "returns the full collection shape" do
        add_subscriber(collection, user)

        get "/collections/#{collection.id}.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body

        expect(payload["name"]).to eq("Detail")
        expect(payload["topic_count"]).to eq(0)
        expect(payload["owner"]["username"]).to eq(other_user.username)
        expect(payload["teamworkers"].map { |worker| worker["id"] }).to contain_exactly(user.id)
        expect(payload["subscriber_count"]).to eq(1)
        expect(payload["is_subscribed"]).to eq(true)
        expect(payload.key?("created_at")).to eq(true)
        expect(payload.key?("last_topic_added_at")).to eq(true)
      end

      it "returns null owner and empty teamworkers for an ownerless collection" do
        ownerless = build_collection(name: "Orphan")

        get "/collections/#{ownerless.id}.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["owner"]).to be_nil
        expect(payload["teamworkers"]).to eq([])
      end

      it "returns a 404 for a missing collection" do
        get "/collections/999999.json"

        expect(response.status).to eq(404)
      end
    end

    context "when anonymous access is enabled" do
      before { SiteSetting.collection_allow_anonymous = true }

      it "lets anonymous visitors read details with visitor booleans off" do
        get "/collections/#{collection.id}.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["is_subscribed"]).to eq(false)
        expect(payload["teamworkers"].map { |worker| worker["id"] }).to contain_exactly(user.id)
      end
    end
  end

  describe "#mine" do
    it "requires a logged-in user" do
      get "/collections/mine.json"

      expect(response.status).to eq(403)
    end

    context "when signed in" do
      before { sign_in(user) }

      it "returns only the collections the user owns or maintains, as the list shape" do
        owned = build_collection(name: "Mine owned", owner: user, last_topic_added_at: Time.zone.now)
        maintained = build_collection(name: "Mine maintained", owner: other_user)
        add_co_worker(maintained, user)
        build_collection(name: "Foreign", owner: other_user)

        get "/collections/mine.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body

        names = payload["collections"].map { |row| row["name"] }
        expect(names).to contain_exactly("Mine owned", "Mine maintained")
        expect(payload["meta"]["total"]).to eq(2)

        owned_row = payload_collection_by_id(payload, owned.id)
        maintained_row = payload_collection_by_id(payload, maintained.id)

        expect(owned_row["owner"]["id"]).to eq(user.id)
        expect(owned_row["is_teamworker"]).to eq(false)
        expect(maintained_row["owner"]["id"]).to eq(other_user.id)
        expect(maintained_row["is_teamworker"]).to eq(true)
      end

      it "returns an empty list when the user has no collections" do
        get "/collections/mine.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["collections"]).to eq([])
      end
    end
  end

  describe "#create" do
    it "requires a logged-in user" do
      post "/collections.json", params: { name: "New collection" }, as: :json

      expect(response.status).to eq(403)
    end

    it "rejects creation with a 403 when the user is not in the create-allowed groups" do
      # Default allowed groups = @trust_level_1; this :user fabricator is trust_level 0.
      sign_in(user)

      post "/collections.json", params: { name: "New collection" }, as: :json

      expect(response.status).to eq(403)
    end

    context "when signed in" do
      fab!(:create_group) { Fabricate(:group) }

      before do
        SiteSetting.collection_create_allowed_groups = create_group.id.to_s
        create_group.add(user)
        sign_in(user)
      end

      it "creates a collection owned by the acting user, who auto-subscribes" do
        post "/collections.json", params: { name: "New collection" }, as: :json

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["name"]).to eq("New collection")
        expect(payload["description"]).to eq("")
        expect(payload["topic_count"]).to eq(0)
        expect(payload["owner"]["username"]).to eq(user.username)
        expect(payload["teamworkers"]).to eq([])
        # docs/08 §1: the owner's subscription row exists but never counts.
        expect(payload["subscriber_count"]).to eq(0)
        expect(payload["is_subscribed"]).to eq(true)
        expect(
          DiscourseCollection::CollectionSubscriber.where(
            collection_id: payload["id"],
            user_id: user.id,
          ).count,
        ).to eq(1)
      end

      it "trims the name and stores a non-empty description" do
        post "/collections.json", params: { name: "  Padded  ", description: "notes" }, as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["name"]).to eq("Padded")
        expect(response.parsed_body["description"]).to eq("notes")
      end

      it "rejects an out-of-range name with a 422" do
        post "/collections.json",
             params: { name: "a" * (SiteSetting.collection_name_max_length + 1) },
             as: :json

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to be_present
      end

      it "rejects creation when the user is at the collection cap" do
        SiteSetting.collection_max_collections_per_user = 1
        build_collection(name: "Existing", owner: user)

        post "/collections.json", params: { name: "New collection" }, as: :json

        expect(response.status).to eq(422)
        expect(response.parsed_body["errors"]).to include(
          I18n.t("discourse_collection.errors.collection_limit_reached", max: 1),
        )
      end
    end
  end

  describe "#update" do
    it "requires a logged-in user" do
      put "/collections/#{build_collection(name: "Before", owner: other_user).id}.json",
          params: { name: "After" },
          as: :json

      expect(response.status).to eq(403)
    end

    it "lets the owner rename their own collection" do
      collection = build_collection(name: "Before", owner: user)
      sign_in(user)

      put "/collections/#{collection.id}.json", params: { name: "After" }, as: :json

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["name"]).to eq("After")
      expect(payload["owner"]["username"]).to eq(user.username)
    end

    it "rejects an outsider with a 403" do
      collection = build_collection(name: "Before", owner: other_user)
      sign_in(user)

      put "/collections/#{collection.id}.json", params: { name: "After" }, as: :json

      expect(response.status).to eq(403)
    end

    it "lets staff rename someone else's collection" do
      collection = build_collection(name: "Before", owner: other_user)
      sign_in(admin)

      put "/collections/#{collection.id}.json", params: { name: "After" }, as: :json

      expect(response.status).to eq(200)
      expect(response.parsed_body["name"]).to eq("After")
      expect(response.parsed_body["owner"]["username"]).to eq(other_user.username)
    end

    it "lets staff rename an ownerless collection" do
      collection = build_collection(name: "Orphan")
      sign_in(admin)

      put "/collections/#{collection.id}.json", params: { name: "Adopted" }, as: :json

      expect(response.status).to eq(200)
      expect(response.parsed_body["name"]).to eq("Adopted")
      expect(response.parsed_body["owner"]).to be_nil
    end

    it "rejects an empty update with a 422" do
      collection = build_collection(name: "Before", owner: user)
      sign_in(user)

      put "/collections/#{collection.id}.json", params: {}, as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "rejects a co-maintainer with a 403 (metadata edits are owner/staff-only)" do
      collection = build_collection(name: "Before", owner: other_user)
      add_co_worker(collection, user)
      sign_in(user)

      put "/collections/#{collection.id}.json", params: { name: "After" }, as: :json

      expect(response.status).to eq(403)
    end

    context "as a moderator (management ops follow collection_moderators_can_manage_collections)" do
      it "denies renaming someone else's collection when the setting is off" do
        SiteSetting.collection_moderators_can_manage_collections = false
        collection = build_collection(name: "Before", owner: other_user)
        sign_in(moderator)

        put "/collections/#{collection.id}.json", params: { name: "After" }, as: :json

        expect(response.status).to eq(403)
      end

      it "lets a moderator rename someone else's collection when the setting is on" do
        SiteSetting.collection_moderators_can_manage_collections = true
        collection = build_collection(name: "Before", owner: other_user)
        sign_in(moderator)

        put "/collections/#{collection.id}.json", params: { name: "After" }, as: :json

        expect(response.status).to eq(200)
        expect(response.parsed_body["name"]).to eq("After")
        expect(response.parsed_body["owner"]["username"]).to eq(other_user.username)
      end
    end
  end

  describe "#destroy" do
    it "requires a logged-in user" do
      collection = build_collection(name: "Bye", owner: other_user)

      delete "/collections/#{collection.id}.json"

      expect(response.status).to eq(403)
    end

    it "lets the owner delete their collection" do
      collection = build_collection(name: "Bye", owner: user)
      sign_in(user)

      delete "/collections/#{collection.id}.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq("OK")
      expect(DiscourseCollection::Collection.find_by(id: collection.id)).to be_nil
    end

    it "does not let staff delete someone else's collection" do
      collection = build_collection(name: "Bye", owner: other_user)
      sign_in(admin)

      delete "/collections/#{collection.id}.json"

      expect(response.status).to eq(403)
      expect(DiscourseCollection::Collection.find_by(id: collection.id)).not_to be_nil
    end

    it "does not let a co-maintainer delete the collection (owner-only)" do
      collection = build_collection(name: "Bye", owner: other_user)
      add_co_worker(collection, user)
      sign_in(user)

      delete "/collections/#{collection.id}.json"

      expect(response.status).to eq(403)
      expect(DiscourseCollection::Collection.find_by(id: collection.id)).not_to be_nil
    end
  end

  describe "#create_invite" do
    let(:collection) { build_collection(name: "Team", owner: user) }
    let(:invite_url) { "/collections/#{collection.id}/invites.json" }

    fab!(:create_group) { Fabricate(:group) }
    fab!(:teamworker_group) { Fabricate(:group) }

    # The invite gates check the TARGET's membership (default @trust_level_1 would block
    # the :user fabricators used as invitees below); grant them so the intended steps run.
    before do
      SiteSetting.collection_create_allowed_groups = create_group.id.to_s
      SiteSetting.collection_teamworker_allowed_groups = teamworker_group.id.to_s
      [user, other_user, stranger, moderator].each do |member|
        create_group.add(member)
        teamworker_group.add(member)
      end
    end

    it "requires a logged-in user" do
      post invite_url, params: { user_id: other_user.id, action_type: 0 }, as: :json

      expect(response.status).to eq(403)
    end

    it "lets the owner invite a co-maintainer (201, pending invite)" do
      sign_in(user)

      post invite_url, params: { user_id: other_user.id, action_type: 0 }, as: :json

      expect(response.status).to eq(201)
      payload = response.parsed_body
      expect(payload["action_type"]).to eq(0)
      expect(payload["status"]).to eq("pending")
      expect(payload["inviter"]["id"]).to eq(user.id)
      expect(payload["invitee"]["id"]).to eq(other_user.id)
      expect(payload["collection"]).to eq("id" => collection.id, "name" => "Team")
      expect(
        DiscourseCollection::CollectionInvite.find_by(
          collection_id: collection.id,
          invitee_user_id: other_user.id,
        ).accept,
      ).to be_nil
    end

    it "returns the live pending row with 200 on a duplicate issue" do
      sign_in(user)
      post invite_url, params: { user_id: other_user.id, action_type: 0 }, as: :json

      post invite_url, params: { user_id: other_user.id, action_type: 0 }, as: :json

      expect(response.status).to eq(200)
      expect(DiscourseCollection::CollectionInvite.where(collection_id: collection.id).count).to eq(1)
    end

    it "rejects an outsider with 403 and an unknown target with 404" do
      sign_in(stranger)
      post invite_url, params: { user_id: other_user.id, action_type: 0 }, as: :json
      expect(response.status).to eq(403)

      sign_in(user)
      post invite_url, params: { user_id: 999999, action_type: 0 }, as: :json
      expect(response.status).to eq(404)
    end

    it "rejects a second type=1 ownership invite with a 422" do
      Fabricate(
        :collection_invite,
        collection: collection,
        inviter: user,
        invitee: stranger,
        action_type: 1,
      )
      sign_in(user)

      post invite_url, params: { user_id: other_user.id, action_type: 1 }, as: :json

      expect(response.status).to eq(422)
    end

    it "rejects a type=1 plain transfer once co-maintainers already exceed the cap with a 422" do
      SiteSetting.collection_max_teamworkers_per_collection = 1
      add_co_worker(collection, other_user)
      add_co_worker(collection, stranger)
      # The target must pass the create-group admission gate first, so the request
      # reaches the cap check (a plain transfer to a non-co-worker at cap+1 is refused).
      target = Fabricate(:user)
      create_group.add(target)
      sign_in(user)

      post invite_url, params: { user_id: target.id, action_type: 1 }, as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.ownership_transfer_teamworker_limit_reached", max: 1),
      )
    end

    it "lets staff take the collection over by inviting themselves (200, already accepted)" do
      create_group.add(admin)
      sign_in(admin)

      post invite_url, params: { user_id: admin.id, action_type: 1 }, as: :json

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["invite"]["status"]).to eq("accepted")
      expect(payload["invite"]["action_type"]).to eq(1)
      expect(payload["invite"]["inviter"]["id"]).to eq(admin.id)
      expect(payload["invite"]["invitee"]["id"]).to eq(admin.id)
      expect(payload["invite"]["collection"]).to eq("id" => collection.id, "name" => "Team")
      # The collection rides along in its new shape: the caller needs no second read.
      expect(payload["collection"]["owner"]["id"]).to eq(admin.id)
      expect(payload["collection"]["teamworkers"].map { |row| row["id"] }).to eq([user.id])
    end

    it "refuses staff who already own the collection with a 422" do
      owned = build_collection(name: "Mine", owner: admin)
      create_group.add(admin)
      sign_in(admin)

      post "/collections/#{owned.id}/invites.json",
           params: { user_id: admin.id, action_type: 1 },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.already_the_owner"),
      )
    end

    it "still refuses a plain owner inviting themselves with a 422" do
      sign_in(user)

      post invite_url, params: { user_id: user.id, action_type: 1 }, as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.invite_self_not_allowed"),
      )
    end

    it "gives a moderator no self-takeover while the manage-moderation setting is off" do
      SiteSetting.collection_moderators_can_manage_collections = false
      shared = build_collection(name: "Shared", owner: other_user)
      sign_in(moderator)

      post "/collections/#{shared.id}/invites.json",
           params: { user_id: moderator.id, action_type: 1 },
           as: :json

      expect(response.status).to eq(403)
    end

    it "rejects a co-maintainer inviting on someone else's collection with a 403" do
      shared = build_collection(name: "Shared", owner: other_user)
      add_co_worker(shared, user)
      sign_in(user)

      post "/collections/#{shared.id}/invites.json",
           params: { user_id: stranger.id, action_type: 0 },
           as: :json

      expect(response.status).to eq(403)
    end

    context "as a moderator issuing a type=1 (become-owner) invite" do
      it "is denied when the manage-moderation setting is off" do
        SiteSetting.collection_moderators_can_manage_collections = false
        collection = build_collection(name: "Shared", owner: other_user)
        sign_in(moderator)

        post "/collections/#{collection.id}/invites.json",
             params: { user_id: stranger.id, action_type: 1 },
             as: :json

        expect(response.status).to eq(403)
      end

      it "can issue a type=1 invite on someone else's collection when the setting is on" do
        SiteSetting.collection_moderators_can_manage_collections = true
        collection = build_collection(name: "Shared", owner: other_user)
        sign_in(moderator)

        post "/collections/#{collection.id}/invites.json",
             params: { user_id: stranger.id, action_type: 1 },
             as: :json

        expect(response.status).to eq(201)
        expect(response.parsed_body["action_type"]).to eq(1)
      end
    end

    it "lets staff issue a type=1 invite on an ownerless collection to designate a first owner" do
      orphan = build_collection(name: "Orphan")
      sign_in(admin)

      post "/collections/#{orphan.id}/invites.json",
           params: { user_id: other_user.id, action_type: 1 },
           as: :json

      expect(response.status).to eq(201)
      expect(response.parsed_body["action_type"]).to eq(1)
      expect(response.parsed_body["invitee"]["id"]).to eq(other_user.id)
    end

    it "rejects a type=0 invite with a 422 when the target is not in the teamworker-allowed groups" do
      sign_in(user)
      outside = Fabricate(:user)

      post invite_url, params: { user_id: outside.id, action_type: 0 }, as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.invitee_not_in_teamworker_allowed_groups"),
      )
    end

    it "rejects a type=1 invite with a 422 when the target is not in the create-allowed groups" do
      sign_in(user)
      outside = Fabricate(:user)

      post invite_url, params: { user_id: outside.id, action_type: 1 }, as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.invitee_not_in_create_allowed_groups"),
      )
    end
  end

  describe "#collection_invites" do
    let(:collection) { build_collection(name: "Team", owner: user) }

    it "lets the owner list the collection's invites" do
      Fabricate(:collection_invite, collection: collection, inviter: user, invitee: other_user)
      sign_in(user)

      get "/collections/#{collection.id}/invites.json"

      expect(response.status).to eq(200)
      rows = response.parsed_body["invites"]
      expect(rows.size).to eq(1)
      expect(rows.first["status"]).to eq("pending")
    end

    it "hides the record from a stranger with a 403" do
      sign_in(stranger)

      get "/collections/#{collection.id}/invites.json"

      expect(response.status).to eq(403)
    end

    it "requires a logged-in user (the record is owner/staff-only, not anon-readable)" do
      get "/collections/#{collection.id}/invites.json"

      expect(response.status).to eq(403)
    end

    it "lets an admin list another collection's invites" do
      foreign = build_collection(name: "Foreign", owner: other_user)
      Fabricate(:collection_invite, collection: foreign, inviter: other_user, invitee: user)
      sign_in(admin)

      get "/collections/#{foreign.id}/invites.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["invites"].size).to eq(1)
    end

    context "as a moderator (record access follows the manage-moderation setting)" do
      it "is denied on another collection when the setting is off" do
        SiteSetting.collection_moderators_can_manage_collections = false
        foreign = build_collection(name: "Foreign", owner: other_user)
        sign_in(moderator)

        get "/collections/#{foreign.id}/invites.json"

        expect(response.status).to eq(403)
      end

      it "can list another collection's invites when the setting is on" do
        SiteSetting.collection_moderators_can_manage_collections = true
        foreign = build_collection(name: "Foreign", owner: other_user)
        Fabricate(:collection_invite, collection: foreign, inviter: other_user, invitee: user)
        sign_in(moderator)

        get "/collections/#{foreign.id}/invites.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["invites"].size).to eq(1)
      end
    end

    it "rejects a co-maintainer with a 403 (only the owner or staff may view)" do
      shared = build_collection(name: "Shared", owner: other_user)
      add_co_worker(shared, user)
      sign_in(user)

      get "/collections/#{shared.id}/invites.json"

      expect(response.status).to eq(403)
    end
  end

  describe "#invites_inbox" do
    it "requires a logged-in user" do
      get "/collections/invites.json"

      expect(response.status).to eq(403)
    end

    it "lists the invites addressed to me with an owner snapshot" do
      collection = build_collection(name: "Team", owner: other_user)
      Fabricate(:collection_invite, collection: collection, inviter: other_user, invitee: user)
      sign_in(user)

      get "/collections/invites.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["invites"].size).to eq(1)
      expect(payload["invites"].first["collection"]["id"]).to eq(collection.id)
      expect(payload["invites"].first["collection"]["owner"]["id"]).to eq(other_user.id)
      expect(payload["invites"].first).not_to have_key("invitee")
    end
  end

  describe "#revoke_invite" do
    let(:collection) { build_collection(name: "Team", owner: user) }
    let!(:invite) do
      Fabricate(:collection_invite, collection: collection, inviter: user, invitee: other_user)
    end

    it "requires a logged-in user" do
      delete "/collections/#{collection.id}/invites/#{invite.id}.json"

      expect(response.status).to eq(403)
    end

    it "lets the initiator revoke their pending invite" do
      sign_in(user)

      delete "/collections/#{collection.id}/invites/#{invite.id}.json"

      expect(response.status).to eq(200)
      expect(DiscourseCollection::CollectionInvite.find_by(id: invite.id)).to be_nil
    end

    it "does not let the invitee revoke" do
      sign_in(other_user)

      delete "/collections/#{collection.id}/invites/#{invite.id}.json"

      expect(response.status).to eq(403)
    end

    it "lets an admin revoke someone else's pending invite, and audits it" do
      sign_in(admin)

      delete "/collections/#{collection.id}/invites/#{invite.id}.json"

      expect(response.status).to eq(200)
      expect(DiscourseCollection::CollectionInvite.find_by(id: invite.id)).to be_nil
      expect(UserHistory.find_by(custom_type: "collection_invite_revoke")).to be_present
    end

    it "does not let a moderator revoke while the management setting is off" do
      sign_in(moderator)

      delete "/collections/#{collection.id}/invites/#{invite.id}.json"

      expect(response.status).to eq(403)
      expect(DiscourseCollection::CollectionInvite.find_by(id: invite.id)).to be_present
    end
  end

  describe "#accept_invite" do
    let(:collection) { build_collection(name: "Team", owner: other_user) }
    let!(:invite) do
      Fabricate(:collection_invite, collection: collection, inviter: other_user, invitee: user)
    end

    fab!(:create_group) { Fabricate(:group) }
    fab!(:teamworker_group) { Fabricate(:group) }

    # The accept gates re-check the invitee's membership (default @trust_level_1 would
    # block the :user invitee); grant user so the intended steps below run.
    before do
      SiteSetting.collection_create_allowed_groups = create_group.id.to_s
      SiteSetting.collection_teamworker_allowed_groups = teamworker_group.id.to_s
      create_group.add(user)
      teamworker_group.add(user)
    end

    it "requires a logged-in user" do
      post "/collections/invites/#{invite.id}/accept.json"

      expect(response.status).to eq(403)
    end

    it "adds the invitee as a co-maintainer (type=0) and returns the collection" do
      sign_in(user)

      post "/collections/invites/#{invite.id}/accept.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["teamworkers"].map { |worker| worker["id"] }).to contain_exactly(user.id)
      expect(invite.reload.accept).to eq(true)
    end

    it "404s for someone who is not the invitee" do
      sign_in(stranger)

      post "/collections/invites/#{invite.id}/accept.json"

      expect(response.status).to eq(404)
    end

    it "rejects a type=1 accept when the invitee already owns more collections than the cap, keeping it pending" do
      SiteSetting.collection_max_collections_per_user = 1
      build_collection(name: "Owned A", owner: user)
      build_collection(name: "Owned B", owner: user)
      ownership =
        Fabricate(
          :collection_invite,
          collection: collection,
          inviter: other_user,
          invitee: user,
          action_type: 1,
        )
      sign_in(user)

      post "/collections/invites/#{ownership.id}/accept.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.ownership_accept_collection_limit_reached", max: 1),
      )
      expect(ownership.reload.accept).to be_nil
    end

    it "rejects a type=0 accept with a 422 when the invitee is not in the teamworker-allowed groups" do
      stranger_invite =
        Fabricate(
          :collection_invite,
          collection:,
          inviter: other_user,
          invitee: stranger,
        )
      sign_in(stranger)

      post "/collections/invites/#{stranger_invite.id}/accept.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.joiner_not_in_teamworker_allowed_groups"),
      )
    end

    it "rejects a type=1 accept with a 422 when the invitee is not in the create-allowed groups" do
      stranger_ownership =
        Fabricate(
          :collection_invite,
          collection:,
          inviter: other_user,
          invitee: stranger,
          action_type: 1,
        )
      sign_in(stranger)

      post "/collections/invites/#{stranger_ownership.id}/accept.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.new_owner_not_in_create_allowed_groups"),
      )
    end
  end

  describe "#reject_invite" do
    let(:collection) { build_collection(name: "Team", owner: other_user) }
    let!(:invite) do
      Fabricate(:collection_invite, collection: collection, inviter: other_user, invitee: user)
    end

    it "requires a logged-in user" do
      post "/collections/invites/#{invite.id}/reject.json"

      expect(response.status).to eq(403)
    end

    it "records a rejection without touching the team" do
      sign_in(user)

      post "/collections/invites/#{invite.id}/reject.json"

      expect(response.status).to eq(200)
      expect(invite.reload.accept).to eq(false)
      expect(
        DiscourseCollection::CollectionTeamworker.where(collection_id: collection.id).count,
      ).to eq(1) # only the owner row remains
    end
  end

  describe "#remove_maintainer" do
    let(:collection) do
      build_collection(name: "Shared", owner: user).tap { |collection| add_co_worker(collection, other_user) }
    end

    it "requires a logged-in user" do
      delete "/collections/#{collection.id}/teamworkers/#{other_user.id}.json"

      expect(response.status).to eq(403)
    end

    it "lets the owner remove a co-maintainer and returns the full collection shape" do
      sign_in(user)

      delete "/collections/#{collection.id}/teamworkers/#{other_user.id}.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["owner"]["id"]).to eq(user.id)
      expect(payload["teamworkers"]).to eq([])
      expect(
        DiscourseCollection::CollectionTeamworker.find_by(
          collection_id: collection.id,
          user_id: other_user.id,
        ),
      ).to be_nil
    end

    it "rejects an outsider with a 403" do
      sign_in(stranger)

      delete "/collections/#{collection.id}/teamworkers/#{other_user.id}.json"

      expect(response.status).to eq(403)
    end

    it "does not let staff remove a co-maintainer from someone else's collection" do
      sign_in(admin)

      delete "/collections/#{collection.id}/teamworkers/#{other_user.id}.json"

      expect(response.status).to eq(403)
    end

    it "does not let another co-maintainer remove a teammate (only themself or the owner)" do
      collection = build_collection(name: "Shared", owner: other_user)
      add_co_worker(collection, user)
      add_co_worker(collection, stranger)
      sign_in(user)

      delete "/collections/#{collection.id}/teamworkers/#{stranger.id}.json"

      expect(response.status).to eq(403)
    end

    it "lets a co-maintainer remove themself (self-leave) and returns the full collection shape" do
      collection = build_collection(name: "Shared", owner: other_user)
      add_co_worker(collection, user)
      sign_in(user)

      delete "/collections/#{collection.id}/teamworkers/#{user.id}.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["owner"]["id"]).to eq(other_user.id)
      expect(payload["teamworkers"]).to eq([])
      expect(
        DiscourseCollection::CollectionTeamworker.find_by(
          collection_id: collection.id,
          user_id: user.id,
        ),
      ).to be_nil
    end

    it "rejects removing a user who is not a co-maintainer with a 422" do
      collection_without_member = build_collection(name: "Solo", owner: user)
      sign_in(user)

      delete "/collections/#{collection_without_member.id}/teamworkers/#{other_user.id}.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.not_a_maintainer"),
      )
    end

    it "rejects removing the collection owner with a 422" do
      sign_in(user)

      delete "/collections/#{collection.id}/teamworkers/#{user.id}.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.owner_membership_change_not_allowed"),
      )
    end

    it "returns a 404 when the target user does not exist" do
      sign_in(user)

      delete "/collections/#{collection.id}/teamworkers/999999.json"

      expect(response.status).to eq(404)
    end
  end

  describe "#subscribe" do
    let(:collection) { build_collection(name: "Shared", owner: other_user) }

    it "requires a logged-in user" do
      post "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(403)
    end

    it "subscribes the acting user and bumps the stored count by one" do
      sign_in(user)

      post "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["is_subscribed"]).to eq(true)
      expect(payload["subscriber_count"]).to eq(1)
      expect(
        DiscourseCollection::CollectionSubscriber.where(
          collection_id: collection.id,
          user_id: user.id,
        ).count,
      ).to eq(1)
      expect(collection.reload.subscribers_count).to eq(1)
    end

    it "is idempotent when the user is already subscribed" do
      add_subscriber(collection, user)
      sign_in(user)

      post "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["subscriber_count"]).to eq(1)
      expect(
        DiscourseCollection::CollectionSubscriber.where(collection_id: collection.id).count,
      ).to eq(1)
    end

    it "lets the owner re-subscribe after unsubscribing, never counting them" do
      collection = build_collection(name: "Own", owner: user)
      sign_in(user)

      # Owner auto-subscribed on creation (via Create); here simulate an unsubscribe
      # then a re-subscribe: row is recreated but subscriber_count stays 0.
      post "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["is_subscribed"]).to eq(true)
      expect(payload["subscriber_count"]).to eq(0)
    end

    it "lets a co-maintainer subscribe and counts them" do
      add_co_worker(collection, user)
      sign_in(user)

      post "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["subscriber_count"]).to eq(1)
    end

    it "returns a 404 for a missing collection" do
      sign_in(user)

      post "/collections/999999/subscription.json"

      expect(response.status).to eq(404)
    end
  end

  describe "#unsubscribe" do
    let(:collection) { build_collection(name: "Shared", owner: other_user) }

    it "requires a logged-in user" do
      delete "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(403)
    end

    it "removes the acting user's row and decrements the stored count" do
      add_subscriber(collection, user)
      sign_in(user)

      delete "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["is_subscribed"]).to eq(false)
      expect(payload["subscriber_count"]).to eq(0)
      expect(
        DiscourseCollection::CollectionSubscriber.where(
          collection_id: collection.id,
          user_id: user.id,
        ).count,
      ).to eq(0)
      expect(collection.reload.subscribers_count).to eq(0)
    end

    it "is a no-op 200 when the user is not subscribed" do
      sign_in(user)

      delete "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["is_subscribed"]).to eq(false)
    end

    it "lets the owner unsubscribe without changing the count" do
      collection = build_collection(name: "Own", owner: user)
      # Simulate the owner's auto-subscription row from creation (owner never counts).
      Fabricate(:collection_subscriber, collection: collection, user:)
      sign_in(user)

      delete "/collections/#{collection.id}/subscription.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["subscriber_count"]).to eq(0)
      expect(
        DiscourseCollection::CollectionSubscriber.where(
          collection_id: collection.id,
          user_id: user.id,
        ).count,
      ).to eq(0)
    end

    it "returns a 404 for a missing collection" do
      sign_in(user)

      delete "/collections/999999/subscription.json"

      expect(response.status).to eq(404)
    end
  end

  describe "#subscribed" do
    it "requires a logged-in user" do
      get "/collections/subscribed.json"

      expect(response.status).to eq(403)
    end

    context "when signed in" do
      before { sign_in(user) }

      it "returns only the collections the user subscribes to, as the list shape" do
        subscribed_collection = build_collection(name: "Subbed", owner: other_user)
        add_subscriber(subscribed_collection, user)
        owned_collection = build_collection(name: "Owned", owner: user)
        build_collection(name: "Foreign", owner: other_user)

        get "/collections/subscribed.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body
        names = payload["collections"].map { |row| row["name"] }
        expect(names).to contain_exactly("Subbed")
        expect(payload["meta"]["total"]).to eq(1)

        row = payload["collections"].first
        expect(row["is_subscribed"]).to eq(true)
        expect(row["subscriber_count"]).to eq(1)
        expect(row["owner"]["id"]).to eq(other_user.id)
        expect(row["teamworker_count"]).to eq(0)
      end

      it "returns an empty list when the user subscribes to nothing" do
        get "/collections/subscribed.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["collections"]).to eq([])
      end

      it "defaults to last_topic_added_at desc like the other list endpoints" do
        quiet = build_collection(name: "Quiet", owner: other_user, last_topic_added_at: 2.days.ago)
        add_subscriber(quiet, user)
        active = build_collection(name: "Active", owner: other_user, last_topic_added_at: 1.hour.ago)
        add_subscriber(active, user)
        empty = build_collection(name: "Empty", owner: other_user)
        add_subscriber(empty, user)

        get "/collections/subscribed.json"

        expect(response.status).to eq(200)
        expect(response.parsed_body["collections"].map { |row| row["name"] }).to eq(
          %w[Active Quiet Empty],
        )
      end

      it "accepts the same four sort columns as docs/03 §3 / mine" do
        add_subscriber(build_collection(name: "Subbed", owner: other_user), user)

        %w[created_at last_topic_added_at topic_count subscriber_count].each do |sort|
          get "/collections/subscribed.json", params: { sort: }

          expect(response.status).to eq(200), "expected sort=#{sort} to be accepted"
        end
      end

      it "rejects a sort column outside the shared list whitelist with a 400" do
        add_subscriber(build_collection(name: "Subbed", owner: other_user), user)

        get "/collections/subscribed.json", params: { sort: "updated_at" }
        expect(response.status).to eq(400)

        get "/collections/subscribed.json", params: { sort: "bumped_at" }
        expect(response.status).to eq(400)
      end
    end
  end

  describe "#subscribers" do
    let(:collection) do
      build_collection(name: "Shared", owner: other_user).tap { |collection| add_subscriber(collection, user) }
    end

    it "is disabled when collection_enabled is off" do
      SiteSetting.collection_enabled = false
      sign_in(user)

      get "/collections/#{collection.id}/subscribers.json"

      expect(response.status).to eq(404)
    end

    context "when anonymous access is disabled" do
      it "rejects anonymous visitors with a 404" do
        get "/collections/#{collection.id}/subscribers.json"

        expect(response.status).to eq(404)
      end
    end

    context "when signed in" do
      before { sign_in(user) }

      it "lists the counted subscribers (current owner never appears)" do
        # Owner other_user auto-subscribed as owner (never counted); user is a real
        # subscriber. The list must contain only the subscriber.
        Fabricate(:collection_subscriber, collection: collection, user: other_user)

        get "/collections/#{collection.id}/subscribers.json"

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["subscribers"].map { |sub| sub["id"] }).to contain_exactly(user.id)
        expect(payload["meta"]).to eq(
          { "page" => 0, "page_size" => 30, "more" => false, "total" => 1 },
        )
      end

      it "orders oldest subscription first and paginates" do
        # Fresh collection with two distinct subscribers (collection from `let` already holds
        # user's row, so build a separate one to avoid the composite PK).
        paged_collection = build_collection(name: "Paged", owner: other_user)
        older = Fabricate(:collection_subscriber, collection: paged_collection, user: user)
        Fabricate(:collection_subscriber, collection: paged_collection, user: stranger)
        older.update!(created_at: 1.day.ago)

        get "/collections/#{paged_collection.id}/subscribers.json", params: { page_size: 1 }

        expect(response.status).to eq(200)
        payload = response.parsed_body
        expect(payload["subscribers"].length).to eq(1)
        expect(payload["meta"]["total"]).to eq(2)
        expect(payload["meta"]["more"]).to eq(true)
      end

      it "returns a 404 for a missing collection" do
        get "/collections/999999/subscribers.json"

        expect(response.status).to eq(404)
      end
    end
  end

  describe "#add_topic" do
    let(:collection) { build_collection(name: "Reading", owner: user) }
    let(:some_topic) { Fabricate(:topic) }

    it "requires a logged-in user" do
      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(403)
    end

    it "lets the owner collect a topic and returns the full collection shape" do
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id, note: "keep" },
           as: :json

      expect(response.status).to eq(200)
      payload = response.parsed_body
      expect(payload["topic_count"]).to eq(1)
      expect(
        DiscourseCollection::CollectionTopic.find_by(
          collection_id: collection.id,
          topic_id: some_topic.id,
        ).note,
      ).to eq("keep")
      expect(collection.reload.last_topic_added_at).to be_within(1.second).of(Time.zone.now)
    end

    it "lets a co-maintainer collect a topic" do
      collection = build_collection(name: "Shared", owner: other_user)
      add_co_worker(collection, user)
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(200)
    end

    it "rejects an outsider with a 403" do
      sign_in(stranger)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(403)
    end

    it "does not let staff collect into someone else's collection" do
      collection = build_collection(name: "Other", owner: other_user)
      sign_in(admin)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(403)
    end

    it "returns a 404 for a missing collection" do
      sign_in(user)

      post "/collections/999999/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(404)
    end

    it "returns a 404 for a missing topic" do
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: 999999 },
           as: :json

      expect(response.status).to eq(404)
    end

    it "returns a 404 for a topic the actor cannot see (soft-deleted)" do
      some_topic.trash!
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(404)
    end

    it "rejects collecting a private message the owner can see with a 422" do
      pm = Fabricate(:private_message_topic, recipient: user)
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: pm.id },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.private_message_topic_not_allowed"),
      )
      expect(DiscourseCollection::CollectionTopic.where(collection_id: collection.id).count).to eq(0)
    end

    it "returns a 404 for a private message the actor cannot see (no leak)" do
      pm = Fabricate(:private_message_topic, recipient: user)
      sign_in(stranger)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: pm.id },
           as: :json

      expect(response.status).to eq(404)
    end

    it "is idempotent when the topic is already collected" do
      Fabricate(:collection_topic, collection: collection, topic: some_topic)
      collection.update!(topic_count: 1)
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(200)
      expect(response.parsed_body["topic_count"]).to eq(1)
      expect(
        DiscourseCollection::CollectionTopic.where(collection_id: collection.id).count,
      ).to eq(1)
    end

    it "rejects an over-long note with a 422" do
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id, note: "a" * 101 },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.note_too_long", max: 100),
      )
    end

    it "rejects collecting past the collection cap with a 422" do
      SiteSetting.collection_max_topics_per_collection = 1
      Fabricate(:collection_topic, collection: collection, topic: Fabricate(:topic))
      collection.update!(topic_count: 1)
      sign_in(user)

      post "/collections/#{collection.id}/topics.json",
           params: { topic_id: some_topic.id },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.topic_limit_reached", max: 1),
      )
    end
  end

  describe "#remove_topic" do
    let(:collection) do
      build_collection(name: "Reading", owner: user).tap do |collection|
        Fabricate(:collection_topic, collection: collection, topic: some_topic)
        collection.update!(topic_count: 1)
      end
    end
    let(:some_topic) { Fabricate(:topic) }

    it "requires a logged-in user" do
      delete "/collections/#{collection.id}/topics/#{some_topic.id}.json"

      expect(response.status).to eq(403)
    end

    it "lets the owner remove a topic and returns the full collection shape" do
      sign_in(user)

      delete "/collections/#{collection.id}/topics/#{some_topic.id}.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["topic_count"]).to eq(0)
      expect(
        DiscourseCollection::CollectionTopic.find_by(
          collection_id: collection.id,
          topic_id: some_topic.id,
        ),
      ).to be_nil
      expect(collection.reload.last_topic_added_at).to be_nil
    end

    it "lets a co-maintainer remove a topic" do
      collection = build_collection(name: "Shared", owner: other_user)
      add_co_worker(collection, user)
      Fabricate(:collection_topic, collection: collection, topic: some_topic)
      collection.update!(topic_count: 1)
      sign_in(user)

      delete "/collections/#{collection.id}/topics/#{some_topic.id}.json"

      expect(response.status).to eq(200)
    end

    it "rejects an outsider with a 403" do
      sign_in(stranger)

      delete "/collections/#{collection.id}/topics/#{some_topic.id}.json"

      expect(response.status).to eq(403)
    end

    it "returns a 404 for a missing collection" do
      sign_in(user)

      delete "/collections/999999/topics/#{some_topic.id}.json"

      expect(response.status).to eq(404)
    end

    it "rejects removing a topic that is not in the collection with a 422" do
      uncollected = Fabricate(:topic)
      sign_in(user)

      delete "/collections/#{collection.id}/topics/#{uncollected.id}.json"

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to include(
        I18n.t("discourse_collection.errors.topic_not_in_collection"),
      )
    end
  end
end
