# frozen_string_literal: true

# Single-select role for collection_unlimited_teamworkers_role: who may keep adding
# co-maintainers past collection_max_teamworkers_per_collection.
class CollectionUnlimitedTeamworkersRoleSiteSetting < EnumSiteSetting
  def self.valid_value?(val)
    values.any? { |v| v[:value] == val }
  end

  def self.values
    @values ||= [
      { name: "admin.site_settings.collection_unlimited_teamworkers_role.nobody", value: "nobody" },
      { name: "admin.site_settings.collection_unlimited_teamworkers_role.admin", value: "admin" },
      { name: "admin.site_settings.collection_unlimited_teamworkers_role.staff", value: "staff" },
    ]
  end

  def self.translate_names?
    true
  end
end
