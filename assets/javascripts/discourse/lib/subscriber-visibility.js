/**
 * Whether this viewer may open the collection's subscriber list.
 *
 * The server owns the rule (CollectionPolicy#can_view_subscribers?, docs/02 §5) and
 * re-checks it on every request; this is the same rule written out for the page, which
 * needs it to decide whether to render the entry at all. Both sides read the same site
 * setting, and the five levels are cumulative, so each case below adds a role to the one
 * above it.
 *
 * The viewer's owner / co-maintainer roles are asked of THIS collection, which is why they
 * arrive as arguments rather than being derived here. No level admits a visitor who is not
 * signed in, so a missing user is a flat no whatever the setting says.
 */
export function canViewSubscriberList({ setting, user, isOwner, isTeamworker }) {
  if (!user) {
    return false;
  }

  switch (setting) {
    case "admin":
      return !!user.admin;
    case "staff":
      return !!user.staff;
    case "staff_owner":
      return !!user.staff || !!isOwner;
    case "staff_owner_teamworker":
      return !!user.staff || !!isOwner || !!isTeamworker;
    default:
      // logged_in, the default level. Anything else is a setting the client has not been
      // handed yet (an older payload), which reads as the default for the same reason.
      return true;
  }
}
