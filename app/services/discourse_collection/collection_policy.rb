# frozen_string_literal: true

module DiscourseCollection
  # Single source of truth for who can do what on a collection (permission matrix,
  # docs/06 §2). Used by controllers and services; the "who" is always the acting
  # user (nil for anonymous).
  #
  # Collection roles:
  #   - owner: holds the is_owner=true teamworker row (at most one per collection).
  #   - co-maintainer / teamworker: holds an is_owner=false teamworker row.
  #   - staff management: admin always; moderator only when
  #     collection_moderators_can_manage_collections is enabled.
  #   - note rewrite exception: any staff (admin or moderator), no setting gate.
  class CollectionPolicy
    def self.for(collection:, user:)
      new(collection:, user:)
    end

    def initialize(collection:, user:)
      @collection = collection
      @user = user
    end

    def owner?
      membership&.is_owner == true
    end

    def team_worker?
      !owner? && !membership.nil?
    end

    # May collect / remove topics (and later edit their note/featured replies, docs/04 §4):
    # the collection owner or any co-maintainer (docs/06 §2). Ownerless collections have no
    # one in this role; staff are not a stand-in here.
    def can_write_topics?
      owner? || team_worker?
    end

    # Admin or moderator. Guards the note-rewrite exception (docs/06 §1), which is
    # not gated by collection_moderators_can_manage_collections.
    def staff?
      user.present? && user.staff?
    end

    # Staff may run collection-level management ops (rename/desc/change owner) on ANY
    # collection. Moderators only when the site setting is on; admins always.
    def can_manage_collection?
      user.present? && (user.admin? || (user.moderator? && collection_moderators_can_manage?))
    end

    # May open this collection's subscriber list (docs/02 §5): the site setting names the
    # minimum role, and its levels are cumulative. Ownership is asked of THIS collection, so
    # the same viewer may read one collection's list and not another's. Staff here is core
    # staff (admin and moderator, always) — not the narrower management role above.
    # Anonymous callers never arrive: the action raises NotLoggedIn first, whatever this
    # setting says (docs/01 §2).
    def can_view_subscribers?
      return false if user.blank?

      case SiteSetting.collection_subscribers_visibility.to_s
      when "admin" then user.admin?
      when "staff" then user.staff?
      when "staff_owner" then user.staff? || owner?
      when "staff_owner_teamworker" then user.staff? || owner? || team_worker?
      # logged_in, the default. Any other value means "not configured" rather than
      # "misconfigured" (valid_value? refuses every other value at the write), so it reads
      # as the default instead of taking the list away from everyone.
      else true
      end
    end

    # Cap exemption roles (docs/03 §2 / docs/02 §3): whoever the site setting names is
    # exempt from the per-user collection cap and the per-collection co-maintainer cap.
    # Instance methods delegate to the class helpers so services can ask about a user
    # before any collection exists (the create cap is checked with no collection in hand).
    def exempt_from_collection_cap?
      self.class.exempt_from_collection_cap?(user)
    end

    def exempt_from_teamworker_cap?
      self.class.exempt_from_teamworker_cap?(user)
    end

    def self.exempt_from_collection_cap?(user)
      exempt_from_role?(SiteSetting.collection_unlimited_collections_role, user)
    end

    def self.exempt_from_teamworker_cap?(user)
      exempt_from_role?(SiteSetting.collection_unlimited_teamworkers_role, user)
    end

    def self.exempt_from_role?(role, user)
      case role.to_s
      when "admin"
        user&.admin?
      when "staff"
        user&.staff?
      else
        false # nobody or unknown => nobody is exempt
      end
    end
    private_class_method :exempt_from_role?

    # Group-gated admission (docs/01 §3 / docs/03 §2 / docs/05 §2.1 / docs/05 §2.5): who
    # may create a collection vs who may be invited / accepted as a co-maintainer.
    # Membership is only checked when the operation happens — there is no staff
    # exemption, everyone (including staff) must hold the matching group at that moment.
    # Empty allowed list (map blank) disables the operation for everyone. The disallowed
    # list wins over the allowed one: a member of both is refused, and a blank disallowed
    # list refuses no one.
    def self.in_allowed_groups?(user, allowed_map, disallowed_map)
      return false if user.blank? || allowed_map.blank?
      return false if member_of?(user, disallowed_map)

      member_of?(user, allowed_map)
    end

    # Blank map matches no one (core's *_map semantics).
    def self.member_of?(user, map)
      map.present? && user.group_users&.exists?(group_id: map)
    end
    private_class_method :member_of?

    # May create a collection (and therefore own one): member of
    # collection_create_allowed_groups and not of collection_create_disallowed_groups.
    # Owner transfers target the same gate — the new owner must be able to own a
    # collection.
    def self.allowed_to_create_collections?(user)
      in_allowed_groups?(
        user,
        SiteSetting.collection_create_allowed_groups_map,
        SiteSetting.collection_create_disallowed_groups_map,
      )
    end

    # May hold an is_owner=false co-maintainer row: member of
    # collection_teamworker_allowed_groups and not of
    # collection_teamworker_disallowed_groups.
    def self.allowed_to_become_teamworker?(user)
      in_allowed_groups?(
        user,
        SiteSetting.collection_teamworker_allowed_groups_map,
        SiteSetting.collection_teamworker_disallowed_groups_map,
      )
    end

    private

    attr_reader :collection, :user

    def collection_moderators_can_manage?
      SiteSetting.collection_moderators_can_manage_collections
    end

    def membership
      return if user.blank?

      @membership ||=
        CollectionTeamworker.find_by(collection_id: collection.id, user_id: user.id)
    end
  end
end
