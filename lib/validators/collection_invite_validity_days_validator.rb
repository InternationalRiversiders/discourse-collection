# frozen_string_literal: true

# Enforces the invitation validity window (collection_invite_validity_days): an
# integer >= 1. A positive history retention window (collection_invite_history_days)
# must be at least this long, so a pending row is never purged while still
# answerable; when history is 0 ("keep forever", retention disabled) there is no
# upper bound on validity. Range and cross-check both live in this validator
# because YamlLoader forbids declaring settings.yml min:/max: on a setting that
# also has a validator (core lib/site_settings/yaml_loader.rb raises on that
# combination) — same pattern as the collection name-length validators.
class CollectionInviteValidityDaysValidator
  MIN_INVITE_VALIDITY_DAYS = 1

  def initialize(opts = {})
    @opts = opts
  end

  def valid_value?(value)
    if value < MIN_INVITE_VALIDITY_DAYS
      @range_violation = true
      return false
    end

    history_days = SiteSetting.collection_invite_history_days
    if history_days.positive? && value > history_days
      @exceeds_history = true
      return false
    end

    true
  end

  def error_message
    if @range_violation
      I18n.t(
        "site_settings.errors.invalid_integer_min",
        min: MIN_INVITE_VALIDITY_DAYS,
      )
    elsif @exceeds_history
      I18n.t("site_settings.errors.collection_invite_validity_days_range")
    end
  end
end
