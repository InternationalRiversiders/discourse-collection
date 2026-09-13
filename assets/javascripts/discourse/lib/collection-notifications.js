import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import { INVITE_MAINTAINER } from "./collection-api";

// The four native notification types this plugin raises (docs/09 §1), each with
// the user-menu rendering core cannot derive on its own. Without a renderer every one
// of them falls back to NotificationTypeBase, which reads its second line from
// `fancy_title`/`topic_title` and its href from `topic_id` (notification-types/base.js)
// — a collection notification carries neither, so the description would be blank and
// the link dead. Each class below supplies those two things: the sentence (from
// `data`) and the href (built from `data.collection_id`, since nothing points at a
// topic).
//
// The first line needs no override: base renders `data.display_username`, which each
// job fills with the name to show — the collection name on the subscriber notice, the
// other party's username on the three invitation notices.
//
// The icons are core names, except the subscriber notice which reuses this plugin's
// own sprite symbol (svg-icons/collection.svg, already used by the sidebar link and
// the post action bar); `notification.<name>` does not exist for our types, so base
// would render nothing.
export function registerCollectionNotificationRenderers(api) {
  api.registerNotificationTypeRenderer(
    "collection_topic_added",
    (NotificationTypeBase) =>
      class extends NotificationTypeBase {
        get linkHref() {
          return collectionPath(this.notification.data.collection_id);
        }

        get linkTitle() {
          return i18n("notifications.titles.collection_topic_added");
        }

        get icon() {
          return "collection";
        }

        get description() {
          return i18n("notifications.collection_topic_added");
        }
      }
  );

  // Tells the invitee there is something waiting for them, so it leads to the inbox
  // where they accept or decline (docs/05 §2.4) rather than to the collection.
  api.registerNotificationTypeRenderer(
    "collection_invitation",
    (NotificationTypeBase) =>
      class extends NotificationTypeBase {
        get linkHref() {
          return getURL("/collections/invites");
        }

        get linkTitle() {
          return i18n("notifications.titles.collection_invitation");
        }

        get icon() {
          return "user-plus";
        }

        get description() {
          return i18n(
            `notifications.collection_invitation.${roleKey(
              this.notification.data.action_type
            )}`,
            { collection: this.notification.data.collection_name }
          );
        }
      }
  );

  // The two answers go back to the inviter, and both lead to the collection — the
  // invitation is settled, so there is nothing left to do in the inbox.
  api.registerNotificationTypeRenderer(
    "collection_invitation_accepted",
    (NotificationTypeBase) =>
      class extends NotificationTypeBase {
        get linkHref() {
          return collectionPath(this.notification.data.collection_id);
        }

        get linkTitle() {
          return i18n("notifications.titles.collection_invitation_accepted");
        }

        get icon() {
          return "user-check";
        }

        get description() {
          return i18n(
            `notifications.collection_invitation_accepted.${roleKey(
              this.notification.data.action_type
            )}`,
            { collection: this.notification.data.collection_name }
          );
        }
      }
  );

  api.registerNotificationTypeRenderer(
    "collection_invitation_declined",
    (NotificationTypeBase) =>
      class extends NotificationTypeBase {
        get linkHref() {
          return collectionPath(this.notification.data.collection_id);
        }

        get linkTitle() {
          return i18n("notifications.titles.collection_invitation_declined");
        }

        get icon() {
          return "user-xmark";
        }

        get description() {
          return i18n("notifications.collection_invitation_declined", {
            collection: this.notification.data.collection_name,
          });
        }
      }
  );
}

// The two action_type values the jobs store (the same constants the invite flow
// uses); anything that is not a co-maintainer invitation is an ownership transfer.
function roleKey(actionType) {
  return actionType === INVITE_MAINTAINER ? "maintainer" : "owner";
}

function collectionPath(id) {
  return getURL(`/collections/${id}`);
}
