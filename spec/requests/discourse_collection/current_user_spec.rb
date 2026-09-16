# frozen_string_literal: true

# The frontend leaves the create entry out by reading a boolean off the acting user
# instead of restating the admission rule in JavaScript (docs/01 §3), so that boolean
# has to agree with CollectionPolicy on every branch of the rule.
RSpec.describe "DiscourseCollection current user create flag" do
  fab!(:user)
  fab!(:group) { Fabricate(:group) }

  def can_create_collection
    sign_in(user)
    get "/session/current.json"
    response.parsed_body.dig("current_user", "can_create_collection")
  end

  context "when the user holds a group from the allowed list" do
    before do
      SiteSetting.collection_create_allowed_groups = group.id.to_s
      group.add(user)
    end

    it "reports true" do
      expect(can_create_collection).to eq(true)
    end
  end

  context "when the user holds a group from both lists" do
    fab!(:denied_group) { Fabricate(:group) }

    before do
      SiteSetting.collection_create_allowed_groups = group.id.to_s
      SiteSetting.collection_create_disallowed_groups = denied_group.id.to_s
      group.add(user)
      denied_group.add(user)
    end

    it "reports false — the disallowed list wins" do
      expect(can_create_collection).to eq(false)
    end
  end

  context "when the user holds no group from the allowed list" do
    before { SiteSetting.collection_create_allowed_groups = group.id.to_s }

    it "reports false" do
      expect(can_create_collection).to eq(false)
    end
  end

  context "when the allowed list is blank" do
    before { SiteSetting.collection_create_allowed_groups = "" }

    it "reports false — a blank list admits nobody" do
      expect(can_create_collection).to eq(false)
    end
  end
end
