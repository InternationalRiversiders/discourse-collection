# frozen_string_literal: true

RSpec.describe DiscourseCollection::CollectionPolicy do
  fab!(:collection) { Fabricate(:collection) }
  fab!(:regular_user, :user)
  fab!(:admin, :admin)
  fab!(:moderator, :moderator)

  fab!(:owner_user) { Fabricate(:user) }
  fab!(:co_worker_user) { Fabricate(:user) }

  let(:policy) { described_class.for(collection:, user: actor) }
  let(:actor) { regular_user }

  before do
    Fabricate(:collection_teamworker, collection:, user: owner_user, is_owner: true)
    Fabricate(:collection_teamworker, collection:, user: co_worker_user, is_owner: false)
  end

  describe "#owner?" do
    it "is true for the user holding the is_owner row" do
      expect(described_class.for(collection:, user: owner_user).owner?).to eq(true)
    end

    it "is false for a co-maintainer, an outsider and an anonymous visitor" do
      expect(described_class.for(collection:, user: co_worker_user).owner?).to eq(false)
      expect(described_class.for(collection:, user: regular_user).owner?).to eq(false)
      expect(described_class.for(collection:, user: nil).owner?).to eq(false)
    end
  end

  describe "#team_worker?" do
    it "is true for a co-maintainer (is_owner=false row)" do
      expect(described_class.for(collection:, user: co_worker_user).team_worker?).to eq(true)
    end

    it "is false for the owner, an outsider and an anonymous visitor" do
      expect(described_class.for(collection:, user: owner_user).team_worker?).to eq(false)
      expect(described_class.for(collection:, user: regular_user).team_worker?).to eq(false)
      expect(described_class.for(collection:, user: nil).team_worker?).to eq(false)
    end
  end

  describe "#staff?" do
    it "is true for admins and moderators" do
      expect(described_class.for(collection:, user: admin).staff?).to eq(true)
      expect(described_class.for(collection:, user: moderator).staff?).to eq(true)
    end

    it "is false for regular users and anonymous visitors" do
      expect(described_class.for(collection:, user: regular_user).staff?).to eq(false)
      expect(described_class.for(collection:, user: nil).staff?).to eq(false)
    end
  end

  describe "#can_manage_collection?" do
    context "when collection_moderators_can_manage_collections is disabled" do
      before { SiteSetting.collection_moderators_can_manage_collections = false }

      it "lets admins manage, but not moderators" do
        expect(described_class.for(collection:, user: admin).can_manage_collection?).to eq(true)
        expect(described_class.for(collection:, user: moderator).can_manage_collection?).to eq(false)
      end
    end

    context "when collection_moderators_can_manage_collections is enabled" do
      before { SiteSetting.collection_moderators_can_manage_collections = true }

      it "lets both admins and moderators manage" do
        expect(described_class.for(collection:, user: admin).can_manage_collection?).to eq(true)
        expect(described_class.for(collection:, user: moderator).can_manage_collection?).to eq(true)
      end
    end

    it "does not let regular users or anonymous visitors manage" do
      expect(described_class.for(collection:, user: regular_user).can_manage_collection?).to eq(false)
      expect(described_class.for(collection:, user: nil).can_manage_collection?).to eq(false)
    end
  end

  # docs/02 §5 — the five levels are cumulative, so each context adds one role to the
  # previous and the viewer's roles are asked of THIS collection (the fixture gives it an
  # owner and a co-maintainer, and neither of them is staff).
  describe "#can_view_subscribers?" do
    context "when the visibility is admin" do
      before { SiteSetting.collection_subscribers_visibility = "admin" }

      it "admits admins only" do
        expect(described_class.for(collection:, user: admin).can_view_subscribers?).to eq(true)
        expect(described_class.for(collection:, user: moderator).can_view_subscribers?).to eq(false)
        expect(described_class.for(collection:, user: owner_user).can_view_subscribers?).to eq(false)
        expect(described_class.for(collection:, user: co_worker_user).can_view_subscribers?).to eq(
          false,
        )
        expect(described_class.for(collection:, user: regular_user).can_view_subscribers?).to eq(
          false,
        )
        expect(described_class.for(collection:, user: nil).can_view_subscribers?).to eq(false)
      end
    end

    context "when the visibility is staff" do
      before { SiteSetting.collection_subscribers_visibility = "staff" }

      it "admits admins and moderators, whatever the collection management setting says" do
        SiteSetting.collection_moderators_can_manage_collections = false

        expect(described_class.for(collection:, user: admin).can_view_subscribers?).to eq(true)
        expect(described_class.for(collection:, user: moderator).can_view_subscribers?).to eq(true)
        expect(described_class.for(collection:, user: owner_user).can_view_subscribers?).to eq(false)
        expect(described_class.for(collection:, user: regular_user).can_view_subscribers?).to eq(
          false,
        )
      end
    end

    context "when the visibility is staff_owner" do
      before { SiteSetting.collection_subscribers_visibility = "staff_owner" }

      it "adds this collection's owner, but not its co-maintainers" do
        expect(described_class.for(collection:, user: owner_user).can_view_subscribers?).to eq(true)
        expect(described_class.for(collection:, user: co_worker_user).can_view_subscribers?).to eq(
          false,
        )
        expect(described_class.for(collection:, user: regular_user).can_view_subscribers?).to eq(
          false,
        )
      end

      it "does not carry ownership over to another collection" do
        other = Fabricate(:collection)

        expect(described_class.for(collection: other, user: owner_user).can_view_subscribers?).to eq(
          false,
        )
      end
    end

    context "when the visibility is staff_owner_teamworker" do
      before { SiteSetting.collection_subscribers_visibility = "staff_owner_teamworker" }

      it "adds this collection's co-maintainers" do
        expect(described_class.for(collection:, user: owner_user).can_view_subscribers?).to eq(true)
        expect(described_class.for(collection:, user: co_worker_user).can_view_subscribers?).to eq(
          true,
        )
        expect(described_class.for(collection:, user: regular_user).can_view_subscribers?).to eq(
          false,
        )
        expect(described_class.for(collection:, user: nil).can_view_subscribers?).to eq(false)
      end
    end

    context "when the visibility is logged_in (the default)" do
      it "admits any signed-in user and turns anonymous visitors away" do
        expect(SiteSetting.collection_subscribers_visibility).to eq("logged_in")
        expect(described_class.for(collection:, user: regular_user).can_view_subscribers?).to eq(
          true,
        )
        expect(described_class.for(collection:, user: nil).can_view_subscribers?).to eq(false)
      end
    end
  end

  describe "#exempt_from_collection_cap?" do
    context "when the unlimited role is set to nobody" do
      before { SiteSetting.collection_unlimited_collections_role = "nobody" }

      it "exempts nobody" do
        expect(described_class.for(collection:, user: regular_user).exempt_from_collection_cap?).to eq(
          false,
        )
        expect(described_class.for(collection:, user: admin).exempt_from_collection_cap?).to eq(false)
        expect(
          described_class.for(collection:, user: moderator).exempt_from_collection_cap?,
        ).to eq(false)
      end
    end

    context "when the unlimited role is set to admin" do
      before { SiteSetting.collection_unlimited_collections_role = "admin" }

      it "exempts admins only" do
        expect(described_class.for(collection:, user: admin).exempt_from_collection_cap?).to eq(true)
        expect(
          described_class.for(collection:, user: moderator).exempt_from_collection_cap?,
        ).to eq(false)
        expect(described_class.for(collection:, user: regular_user).exempt_from_collection_cap?).to eq(
          false,
        )
      end
    end

    context "when the unlimited role is set to staff" do
      before { SiteSetting.collection_unlimited_collections_role = "staff" }

      it "exempts admins and moderators" do
        expect(described_class.for(collection:, user: admin).exempt_from_collection_cap?).to eq(true)
        expect(
          described_class.for(collection:, user: moderator).exempt_from_collection_cap?,
        ).to eq(true)
        expect(described_class.for(collection:, user: regular_user).exempt_from_collection_cap?).to eq(
          false,
        )
      end
    end
  end

  describe "#exempt_from_teamworker_cap?" do
    context "when the unlimited role is set to nobody" do
      before { SiteSetting.collection_unlimited_teamworkers_role = "nobody" }

      it "exempts nobody from the co-maintainer cap" do
        expect(
          described_class.for(collection:, user: regular_user).exempt_from_teamworker_cap?,
        ).to eq(false)
        expect(
          described_class.for(collection:, user: admin).exempt_from_teamworker_cap?,
        ).to eq(false)
        expect(
          described_class.for(collection:, user: moderator).exempt_from_teamworker_cap?,
        ).to eq(false)
      end
    end

    context "when the unlimited role is set to admin" do
      before { SiteSetting.collection_unlimited_teamworkers_role = "admin" }

      it "exempts admins only from the co-maintainer cap" do
        expect(
          described_class.for(collection:, user: admin).exempt_from_teamworker_cap?,
        ).to eq(true)
        expect(
          described_class.for(collection:, user: moderator).exempt_from_teamworker_cap?,
        ).to eq(false)
        expect(
          described_class.for(collection:, user: regular_user).exempt_from_teamworker_cap?,
        ).to eq(false)
      end
    end

    context "when the unlimited role is set to staff" do
      before { SiteSetting.collection_unlimited_teamworkers_role = "staff" }

      it "exempts admins and moderators from the co-maintainer cap" do
        expect(
          described_class.for(collection:, user: admin).exempt_from_teamworker_cap?,
        ).to eq(true)
        expect(
          described_class.for(collection:, user: moderator).exempt_from_teamworker_cap?,
        ).to eq(true)
        expect(
          described_class.for(collection:, user: regular_user).exempt_from_teamworker_cap?,
        ).to eq(false)
      end
    end
  end

  describe ".allowed_to_create_collections?" do
    fab!(:allowed_group) { Fabricate(:group) }
    fab!(:denied_group) { Fabricate(:group) }
    fab!(:allowed_user) { Fabricate(:user) }
    fab!(:denied_user) { Fabricate(:user) }

    before do
      SiteSetting.collection_create_allowed_groups = allowed_group.id.to_s
      allowed_group.add(allowed_user)
      allowed_group.add(denied_user)
    end

    it "admits a member of the allowed groups" do
      expect(described_class.allowed_to_create_collections?(allowed_user)).to eq(true)
    end

    it "refuses a non-member and an anonymous visitor" do
      expect(described_class.allowed_to_create_collections?(regular_user)).to eq(false)
      expect(described_class.allowed_to_create_collections?(nil)).to eq(false)
    end

    it "refuses everyone while the allowed list is empty" do
      SiteSetting.collection_create_allowed_groups = ""

      expect(described_class.allowed_to_create_collections?(allowed_user)).to eq(false)
    end

    it "refuses no one while the disallowed list is empty" do
      SiteSetting.collection_create_disallowed_groups = ""

      expect(described_class.allowed_to_create_collections?(allowed_user)).to eq(true)
    end

    context "when the user is a member of a disallowed group as well" do
      before do
        denied_group.add(denied_user)
        SiteSetting.collection_create_disallowed_groups = denied_group.id.to_s
      end

      it "refuses them, the disallowed list winning over the allowed one" do
        expect(described_class.allowed_to_create_collections?(denied_user)).to eq(false)
      end

      it "still admits a user who is only in the allowed groups" do
        expect(described_class.allowed_to_create_collections?(allowed_user)).to eq(true)
      end

      it "has no staff exemption" do
        allowed_group.add(admin)
        denied_group.add(admin)

        expect(described_class.allowed_to_create_collections?(admin)).to eq(false)
      end
    end
  end

  describe ".allowed_to_become_teamworker?" do
    fab!(:allowed_group) { Fabricate(:group) }
    fab!(:denied_group) { Fabricate(:group) }
    fab!(:allowed_user) { Fabricate(:user) }
    fab!(:denied_user) { Fabricate(:user) }

    before do
      SiteSetting.collection_teamworker_allowed_groups = allowed_group.id.to_s
      allowed_group.add(allowed_user)
      allowed_group.add(denied_user)
    end

    it "admits a member of the allowed groups" do
      expect(described_class.allowed_to_become_teamworker?(allowed_user)).to eq(true)
    end

    it "refuses a non-member and an anonymous visitor" do
      expect(described_class.allowed_to_become_teamworker?(regular_user)).to eq(false)
      expect(described_class.allowed_to_become_teamworker?(nil)).to eq(false)
    end

    it "refuses everyone while the allowed list is empty" do
      SiteSetting.collection_teamworker_allowed_groups = ""

      expect(described_class.allowed_to_become_teamworker?(allowed_user)).to eq(false)
    end

    it "refuses no one while the disallowed list is empty" do
      SiteSetting.collection_teamworker_disallowed_groups = ""

      expect(described_class.allowed_to_become_teamworker?(allowed_user)).to eq(true)
    end

    context "when the user is a member of a disallowed group as well" do
      before do
        denied_group.add(denied_user)
        SiteSetting.collection_teamworker_disallowed_groups = denied_group.id.to_s
      end

      it "refuses them, the disallowed list winning over the allowed one" do
        expect(described_class.allowed_to_become_teamworker?(denied_user)).to eq(false)
      end

      it "still admits a user who is only in the allowed groups" do
        expect(described_class.allowed_to_become_teamworker?(allowed_user)).to eq(true)
      end

      it "has no staff exemption" do
        allowed_group.add(admin)
        denied_group.add(admin)

        expect(described_class.allowed_to_become_teamworker?(admin)).to eq(false)
      end
    end
  end
end
