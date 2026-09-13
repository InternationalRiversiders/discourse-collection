# frozen_string_literal: true

# Enforces the collection name upper bound: integer range (1..100, matching the DB
# VARCHAR(100) ceiling) plus that it never drops below the configured lower bound.
#
# Range and cross-check both live in this validator because YamlLoader forbids
# declaring settings.yml min:/max: on a setting that also has a validator (core
# lib/site_settings/yaml_loader.rb raises on that combination). Core couples its
# two username-length settings the same way.
class CollectionNameMaxLengthValidator
  COLLECTION_NAME_LENGTH_RANGE = 1..100

  def initialize(opts = {})
    @opts = opts
  end

  def valid_value?(value)
    if !COLLECTION_NAME_LENGTH_RANGE.cover?(value)
      @range_violation = true
      return false
    end

    if value < SiteSetting.collection_name_min_length
      @min_value_violation = true
      return false
    end

    true
  end

  def error_message
    if @range_violation
      I18n.t(
        "site_settings.errors.invalid_integer_min_max",
        min: COLLECTION_NAME_LENGTH_RANGE.begin,
        max: COLLECTION_NAME_LENGTH_RANGE.end,
      )
    elsif @min_value_violation
      I18n.t("site_settings.errors.collection_name_max_length_range")
    end
  end
end
