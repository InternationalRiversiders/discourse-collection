import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import NotificationTypeBase from "discourse/lib/notification-types/base";
import {
  getRenderDirector,
  registerNotificationTypeRenderer,
  resetNotificationTypeRenderers,
} from "discourse/lib/notification-types-manager";
import Notification from "discourse/models/notification";
import { createRenderDirector } from "discourse/tests/helpers/notification-types-helper";
import CollectionNotificationsInitializer from "discourse/plugins/discourse-collection/discourse/initializers/collection-notifications";
import {
  registerCollectionNotificationRenderers,
  shouldMarkCollectionNotificationsRead,
} from "discourse/plugins/discourse-collection/discourse/lib/collection-notifications";
import { i18n } from "discourse-i18n";

// One notification as the jobs write them (docs/09 §1): a locator-only `data`
// plus the numeric type. The type number is only carried along for realism — the
// renderer is picked by the name core looks up from it.
function notificationFor(notificationType, data) {
  return Notification.create({
    id: 1,
    user_id: 1,
    notification_type: notificationType,
    read: false,
    high_priority: false,
    created_at: "2026-01-01T00:00:00.000Z",
    data,
  });
}

module("Unit | Collection notifications", function (hooks) {
  setupTest(hooks);

  hooks.beforeEach(function () {
    // A bare setupTest does not put siteSettings on the test context (only the
    // acceptance / component helpers do), and the base label getter reads it.
    this.siteSettings = this.owner.lookup("service:site-settings");

    // Registering through the real manager is what lets createRenderDirector find
    // these classes at all; the suite is about the four renderers, so the wiring
    // itself gets its own test below.
    registerCollectionNotificationRenderers({ registerNotificationTypeRenderer });
  });

  test("a subscriber is told there are updates and sent to the collection", function (assert) {
    const director = createRenderDirector(
      notificationFor(21075, {
        display_username: "Riverside gems",
        collection_id: 7,
      }),
      "collection_topic_added",
      this.siteSettings
    );

    assert.strictEqual(director.label, "Riverside gems", "the collection names the row");
    assert.strictEqual(
      director.description,
      i18n("notifications.collection_topic_added"),
      "the second line carries no topic — a batch may span several"
    );
    assert.strictEqual(director.linkHref, "/collections/7");
    assert.strictEqual(director.icon, "collection");
    assert.strictEqual(
      director.linkTitle,
      i18n("notifications.titles.collection_topic_added")
    );
  });

  test("an invitation is worded by role and opens the inbox", function (assert) {
    const data = {
      display_username: "river",
      collection_id: 7,
      collection_name: "Riverside gems",
    };

    const asMaintainer = createRenderDirector(
      notificationFor(21076, { ...data, action_type: 0 }),
      "collection_invitation",
      this.siteSettings
    );
    assert.strictEqual(asMaintainer.label, "river", "the inviter names the row");
    assert.strictEqual(
      asMaintainer.description,
      i18n("notifications.collection_invitation.maintainer", {
        collection: "Riverside gems",
      })
    );
    // The invitee has something to answer, so the inbox — not the collection — is
    // where this leads (docs/05 §2.4).
    assert.strictEqual(asMaintainer.linkHref, "/collections/invites");
    assert.strictEqual(asMaintainer.icon, "user-plus");

    const asOwner = createRenderDirector(
      notificationFor(21076, { ...data, action_type: 1 }),
      "collection_invitation",
      this.siteSettings
    );
    assert.strictEqual(
      asOwner.description,
      i18n("notifications.collection_invitation.owner", {
        collection: "Riverside gems",
      })
    );
  });

  test("an accepted invitation is worded by role and opens the collection", function (assert) {
    const data = {
      display_username: "river",
      collection_id: 7,
      collection_name: "Riverside gems",
    };

    const asMaintainer = createRenderDirector(
      notificationFor(21077, { ...data, action_type: 0 }),
      "collection_invitation_accepted",
      this.siteSettings
    );
    assert.strictEqual(asMaintainer.label, "river", "the invitee names the row");
    assert.strictEqual(
      asMaintainer.description,
      i18n("notifications.collection_invitation_accepted.maintainer", {
        collection: "Riverside gems",
      })
    );
    assert.strictEqual(asMaintainer.linkHref, "/collections/7");
    assert.strictEqual(asMaintainer.icon, "user-check");

    const asOwner = createRenderDirector(
      notificationFor(21077, { ...data, action_type: 1 }),
      "collection_invitation_accepted",
      this.siteSettings
    );
    assert.strictEqual(
      asOwner.description,
      i18n("notifications.collection_invitation_accepted.owner", {
        collection: "Riverside gems",
      })
    );
  });

  test("a declined invitation needs no role and opens the collection", function (assert) {
    const director = createRenderDirector(
      notificationFor(21078, {
        display_username: "river",
        action_type: 1,
        collection_id: 7,
        collection_name: "Riverside gems",
      }),
      "collection_invitation_declined",
      this.siteSettings
    );

    assert.strictEqual(director.label, "river");
    assert.strictEqual(
      director.description,
      i18n("notifications.collection_invitation_declined", {
        collection: "Riverside gems",
      })
    );
    assert.strictEqual(director.linkHref, "/collections/7");
    assert.strictEqual(director.icon, "user-xmark");
  });

  // The behaviour above says nothing about whether the plugin actually wires the
  // renderers up on boot, which is what keeps them from falling back to the base
  // class in production.
  // The initializer is invoked with the owner, the way the app invokes it: core wraps
  // every plugin initializer so the Discourse-style container argument arrives as
  // `app.__container__` (app.js#resolveDiscourseInitializer). A stand-in container fails
  // there, and the owner is what core's own plugin tests hand their initializers.
  test("the initializer registers the four renderers", function (assert) {
    resetNotificationTypeRenderers();
    this.siteSettings.collection_enabled = true;

    CollectionNotificationsInitializer.initialize(this.owner);

    notificationTypes().forEach((name) => {
      assert.notStrictEqual(
        directorFor(name).constructor,
        NotificationTypeBase,
        `${name} has a renderer of its own`
      );
    });
  });

  test("the initializer registers nothing when the plugin is off", function (assert) {
    resetNotificationTypeRenderers();
    this.siteSettings.collection_enabled = false;

    CollectionNotificationsInitializer.initialize(this.owner);

    notificationTypes().forEach((name) => {
      assert.strictEqual(
        directorFor(name).constructor,
        NotificationTypeBase,
        `${name} falls back to the base renderer`
      );
    });
  });
});

// The three types whose link is the collection page; the invitation type is left out
// because it leads to the inbox, and the gate must stay shut for it.
const GATED_TYPES = [
  "collection_topic_added",
  "collection_invitation_accepted",
  "collection_invitation_declined",
];

// The gate the collection page puts in front of its read pass
// (routes/collections-show.js). Both halves of it read payloads core builds, so the
// shapes below are the ones the wire actually carries: a per-type count map keyed by the
// numeric type id, and the site's name → id lookup.
module("Unit | Collection notification read gate", function () {
  const TYPES = {
    collection_topic_added: 21075,
    collection_invitation: 21076,
    collection_invitation_accepted: 21077,
    collection_invitation_declined: 21078,
  };

  const site = { notification_types: TYPES };

  function viewer(unreadCounts) {
    return { grouped_unread_notifications: unreadCounts };
  }

  test("opens when a type that leads to the collection page is unread", function (assert) {
    GATED_TYPES.forEach((name) => {
      const user = viewer({ [TYPES[name]]: 1 });

      assert.true(shouldMarkCollectionNotificationsRead(user, site), name);
    });
  });

  test("stays shut when every count is zero", function (assert) {
    const user = viewer({ 21075: 0, 21076: 0, 21077: 0, 21078: 0 });

    assert.false(shouldMarkCollectionNotificationsRead(user, site));
  });

  // 21076 leads to the invitation inbox, and answering or revoking the invitation deletes
  // the row — opening a collection settles nothing about it.
  test("stays shut for the invitation type", function (assert) {
    const user = viewer({ [TYPES.collection_invitation]: 4 });

    assert.false(shouldMarkCollectionNotificationsRead(user, site));
  });

  // Fail-closed: a client that cannot read its own payload must not send the request.
  test("stays shut without the counts", function (assert) {
    assert.false(shouldMarkCollectionNotificationsRead({}, site));
  });

  test("stays shut without the site's type lookup", function (assert) {
    const user = viewer({ 21075: 1 });

    assert.false(shouldMarkCollectionNotificationsRead(user, {}));
  });

  test("stays shut for a guest", function (assert) {
    assert.false(shouldMarkCollectionNotificationsRead(null, site));
  });
});

function notificationTypes() {
  return [
    "collection_topic_added",
    "collection_invitation",
    "collection_invitation_accepted",
    "collection_invitation_declined",
  ];
}

// A director looked up outside any rendering context: the type name is all that
// decides which class answers, so the site / user are irrelevant here.
function directorFor(name) {
  return getRenderDirector(
    name,
    notificationFor(21075, { display_username: "Riverside gems" }),
    null,
    null,
    null
  );
}
