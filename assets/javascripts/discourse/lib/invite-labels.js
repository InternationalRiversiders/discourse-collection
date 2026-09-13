import { i18n } from "discourse-i18n";
import { INVITE_OWNER } from "./collection-api";

// Wording shared by the two invite surfaces (the owner's record list on a collection
// and the invitee's inbox) so the same invitation reads the same in both places.

// docs/05 §2.5 — one of pending | expired | accepted | rejected, computed server-side.
export function inviteStatusLabel(status) {
  return i18n(`collections.invites.status.${status}`);
}

// The role an invitation awards, as a bare noun: both surfaces build a sentence around
// it ("invited you to become X" / "invited Y to be X"), so it carries no wording of its
// own — and no articles, which is what lets en and zh share it.
export function inviteRoleName(actionType) {
  return i18n(
    actionType === INVITE_OWNER
      ? "collections.invites.role_name.owner"
      : "collections.invites.role_name.maintainer"
  );
}
