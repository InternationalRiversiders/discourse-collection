import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { NOTIFICATION_TYPES } from "discourse/tests/fixtures/concerns/notification-types";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

// Reaching a collection page settles the notifications that point at it. The pass is
// fire-and-forget, so what these tests watch is the request: whether the gate opens, and
// that nothing about the page waits on the answer.
function fullShape(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 3,
    owner: { id: 1, username: "river", name: "River", avatar_template: "/user_avatar/test/river/{size}/1.png" },
    teamworkers: [],
    subscriber_count: 2,
    is_subscribed: false,
    created_at: "2026-01-02T03:04:05.000Z",
    updated_at: "2026-01-02T03:04:05.000Z",
    last_topic_added_at: "2026-02-01T01:00:00.000Z",
    ...overrides,
  };
}

function emptyTopics() {
  return { topics: [], meta: { page: 0, page_size: 30, more: false, total: 0 } };
}

// The site core hands the client, with this plugin's four types added to the core map —
// which is where the gate reads their ids from.
function collectionTypes() {
  return {
    ...NOTIFICATION_TYPES,
    collection_topic_added: 21075,
    collection_invitation: 21076,
    collection_invitation_accepted: 21077,
    collection_invitation_declined: 21078,
  };
}

const calls = { markRead: [] };

function stubCollectionPage(server, helper) {
  calls.markRead = [];
  // The detail page also loads the invitation record (docs/05 §2.3) and the reading
  // feed (docs/04 §1), so every module needs those stubs whether or not it asserts on them.
  server.get("/collections/:id/invites.json", () =>
    helper.response({
      invites: [],
      meta: { page: 0, page_size: 30, more: false, total: 0 },
    })
  );
  server.get("/collections.json", () =>
    helper.response({
      collections: [],
      meta: { page: 0, page_size: 30, more: false, total: 0 },
    })
  );
  server.get("/collections/:id/topics.json", () => helper.response(emptyTopics()));
  server.get("/collections/5.json", () => helper.response(fullShape(5)));
  server.get("/collections/6.json", () => helper.response(fullShape(6)));
  server.put("/collections/:id/read_notifications.json", (request) => {
    calls.markRead.push(request.url);
    // Collection 6 answers as a server that refused the pass.
    return request.url.includes("/collections/6/")
      ? helper.response(500, {})
      : helper.response({ success: "OK" });
  });
}

acceptance("Collections read notifications — unread", function (needs) {
  needs.user({ grouped_unread_notifications: { 21075: 1 } });
  needs.site({ notification_types: collectionTypes() });
  needs.pretender(stubCollectionPage);

  test("arriving marks the collection's notifications read, once", async function (assert) {
    await visit("/collections/5");

    assert.strictEqual(calls.markRead.length, 1, "one read pass");
    assert.true(
      calls.markRead[0]?.includes("/collections/5/read_notifications.json"),
      "for the collection that was opened"
    );
  });

  test("a refused read pass leaves the page alone", async function (assert) {
    await visit("/collections/6");

    assert.dom(".collection-detail__name").hasText("Collection 6");
    assert.strictEqual(calls.markRead.length, 1, "the pass was still sent");
  });
});

acceptance("Collections read notifications — nothing unread", function (needs) {
  needs.user({
    grouped_unread_notifications: {
      21075: 0,
      21076: 0,
      21077: 0,
      21078: 0,
    },
  });
  needs.site({ notification_types: collectionTypes() });
  needs.pretender(stubCollectionPage);

  test("stays silent", async function (assert) {
    await visit("/collections/5");

    assert.dom(".collection-detail__name").hasText("Collection 5");
    assert.strictEqual(calls.markRead.length, 0, "no read pass");
  });
});

acceptance("Collections read notifications — no counts", function (needs) {
  needs.user();
  needs.site({ notification_types: collectionTypes() });
  needs.pretender(stubCollectionPage);

  test("stays silent", async function (assert) {
    await visit("/collections/5");

    assert.dom(".collection-detail__name").hasText("Collection 5");
    assert.strictEqual(calls.markRead.length, 0, "no read pass");
  });
});

acceptance("Collections read notifications — guest", function (needs) {
  needs.settings({ collection_allow_anonymous: true });
  needs.site({ notification_types: collectionTypes() });
  needs.pretender(stubCollectionPage);

  test("stays silent", async function (assert) {
    await visit("/collections/5");

    assert.dom(".collection-detail__name").hasText("Collection 5");
    assert.strictEqual(calls.markRead.length, 0, "no read pass");
  });
});
