# frozen_string_literal: true

# Enforces the invitation history retention window (collection_invite_history_days):
# an integer >= 0, where 0 means "keep forever" (rows are never purged). Any
# positive value must stay at or above the validity window
# (collection_invite_validity_days), so a still-answerable pending row (age <=
# validity) is never past the retention cutoff. Range and cross-check both live in
# this validator because YamlLoader forbids declaring settings.yml min:/max: on a
# setting that also has a validator (core lib/site_settings/yaml_loader.rb
# raises on that combination) — same pattern as the collection name-length
# validators.
class CollectionInviteHistoryDaysValidator
  MIN_INVITE_HISTORY_DAYS = 0

  def initialize(opts = {})
    @opts = opts
  end

  def valid_value?(value)
    if value < MIN_INVITE_HISTORY_DAYS
      @range_violation = true
      return false
    end

    # 0 = keep forever (nothing is ever purged), so no lower bound from validity.
    if value.positive? && value < SiteSetting.collection_invite_validity_days
      @below_validity = true
      return false
    end

    true
  end

  def error_message
    if @range_violation
      I18n.t(
        "site_settings.errors.invalid_integer_min",
        min: MIN_INVITE_HISTORY_DAYS,
      )
    elsif @below_validity
      I18n.t("site_settings.errors.collection_invite_history_days_range")
    end
  end
end
