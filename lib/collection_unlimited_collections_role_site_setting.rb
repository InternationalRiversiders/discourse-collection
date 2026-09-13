# frozen_string_literal: true

# Single-select role for collection_unlimited_collections_role: who may keep creating
# collections past collection_max_collections_per_user.
class CollectionUnlimitedCollectionsRoleSiteSetting < EnumSiteSetting
  def self.valid_value?(val)
    values.any? { |v| v[:value] == val }
  end

  def self.values
    @values ||= [
      { name: "admin.site_settings.collection_unlimited_collections_role.nobody", value: "nobody" },
      { name: "admin.site_settings.collection_unlimited_collections_role.admin", value: "admin" },
      { name: "admin.site_settings.collection_unlimited_collections_role.staff", value: "staff" },
    ]
  end

  def self.translate_names?
    true
  end
end
