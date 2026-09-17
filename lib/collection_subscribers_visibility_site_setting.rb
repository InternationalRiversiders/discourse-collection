# frozen_string_literal: true

# Single-select level for collection_subscribers_visibility: who may open a
# collection's subscriber list. The levels are cumulative — each one adds a role to
# the one below it — and none of them admits a visitor who is not signed in.
class CollectionSubscribersVisibilitySiteSetting < EnumSiteSetting
  KEY_PREFIX = "admin.site_settings.collection_subscribers_visibility"

  def self.valid_value?(val)
    values.any? { |v| v[:value] == val }
  end

  def self.values
    @values ||= [
      { name: "#{KEY_PREFIX}.admin", value: "admin" },
      { name: "#{KEY_PREFIX}.staff", value: "staff" },
      { name: "#{KEY_PREFIX}.staff_owner", value: "staff_owner" },
      { name: "#{KEY_PREFIX}.staff_owner_teamworker", value: "staff_owner_teamworker" },
      { name: "#{KEY_PREFIX}.logged_in", value: "logged_in" },
    ]
  end

  def self.translate_names?
    true
  end
end
