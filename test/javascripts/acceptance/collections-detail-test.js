import { click, currentURL, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

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

// The face rides on avatar_template: core draws no `<img>` without one, so a fixture
// user meant to be seen needs it as much as any other.
const CURRENT_USER = {
  id: 19,
  username: "eviltrout",
  name: "Robin Ward",
  avatar_template: "/e/{size}.png",
};

// needs.user() makes the viewer eviltrout / id 19, who is admin, moderator and staff in the
// session fixture — so `needs.user()` alone hands a module the staff powers as well. The
// module at the bottom means a viewer who holds none of them, and says so.
const NON_STAFF = { admin: false, moderator: false, staff: false };

function listResponse() {
  return { collections: [], meta: { page: 0, page_size: 30, more: false, total: 0 } };
}

function emptyTopics() {
  return { topics: [], meta: { page: 0, page_size: 30, more: false, total: 0 } };
}

const calls = { subscribe: 0, unsubscribe: 0 };

acceptance("Collections detail page", function (needs) {
  needs.user();
  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    calls.subscribe = 0;
    calls.unsubscribe = 0;
    server.get("/collections.json", () => helper.response(listResponse()));
    server.get("/collections/5.json", () =>
      helper.response(
        fullShape(5, {
          name: "Riverside reads",
          owner: CURRENT_USER,
          teamworkers: [{ id: 2, username: "river", name: "River", avatar_template: "/user_avatar/test/river/{size}/2.png" }],
          is_subscribed: true,
        })
      )
    );
    server.get("/collections/6.json", () =>
      helper.response(
        fullShape(6, {
          teamworkers: [CURRENT_USER],
        })
      )
    );
    server.get("/collections/7.json", () =>
      helper.response(fullShape(7, { owner: null, teamworkers: [] }))
    );
    server.get("/collections/8.json", () =>
      helper.response(fullShape(8, { owner: null }))
    );
    server.post("/collections/8/subscription.json", () => {
      calls.subscribe += 1;
      return helper.response(fullShape(8, { owner: null, subscriber_count: 3, is_subscribed: true }));
    });
    server.get("/collections/9.json", () =>
      helper.response(fullShape(9, { owner: null, subscriber_count: 3, is_subscribed: true }))
    );
    server.delete("/collections/9/subscription.json", () => {
      calls.unsubscribe += 1;
      return helper.response(fullShape(9, { owner: null, subscriber_count: 2, is_subscribed: false }));
    });
    server.get("/collections/10.json", () =>
      helper.response(fullShape(10, { owner: null, subscriber_count: 0 }))
    );
    // The roster endpoint (docs/02 §5) answers most recent subscription first.
    server.get("/collections/5/subscribers.json", () =>
      helper.response({
        subscribers: [
          { id: 2, username: "river", name: "River", avatar_template: "/user_avatar/test/river/{size}/2.png" },
          { id: 3, username: "bob", name: "Bob", avatar_template: "/user_avatar/test/bob/{size}/3.png" },
        ],
        meta: { page: 0, page_size: 30, more: false, total: 2 },
      })
    );
    // The detail page loads the reading feed (docs/04 §1) for every opened collection.
    server.get("/collections/:id/topics.json", () => helper.response(emptyTopics()));
  });

  test("renders the full shape of an owned collection with the owner role chip", async function (assert) {
    await visit("/collections/5");

    assert.dom(".collection-detail__name").hasText("Riverside reads");
    assert.dom(".collection-detail__description").hasText("Description 5");
    assert.dom(".collection-detail__role").hasText(i18n("collections.owner_badge"));
    assert
      .dom(".collection-detail__team-member")
      .exists({ count: 2 }, "the roster holds the owner and the co-maintainer");
    assert.dom(".collection-detail__team-member.-owner").containsText("eviltrout");
    assert
      .dom(".collection-detail__team-member[data-username='river']")
      .containsText("river");
    // Face and name lead to the same profile, so they are one target: a second link
    // beside the first would only send the same click two ways.
    assert
      .dom(".collection-detail__owner a")
      .exists({ count: 1 }, "the owner's face and name share one link");
    assert
      .dom(".collection-detail__owner a img.avatar")
      .exists("with the face riding inside it");
    assert
      .dom(".collection-detail__team-member a")
      .exists({ count: 2 }, "and each roster row links face and name once");
  });

  test("shows the maintainer role chip when the current user co-maintains", async function (assert) {
    await visit("/collections/6");

    assert.dom(".collection-detail__name").hasText("Collection 6");
    assert.dom(".collection-detail__role").hasText(i18n("collections.teamworker_badge"));
  });

  test("renders an ownerless collection as unclaimed", async function (assert) {
    await visit("/collections/7");

    assert.dom(".collection-detail__name").hasText("Collection 7");
    assert.dom(".collection-detail__owner").hasText(i18n("collections.no_owner"));
    assert.dom(".collection-detail__role").doesNotExist("no role chip for a visitor");
  });

  test("subscribing from the detail page optimistically flips the button and POSTs", async function (assert) {
    await visit("/collections/8");

    const subscribeLabel = i18n("collections.detail.subscribe");
    const unsubscribeLabel = i18n("collections.detail.unsubscribe");

    assert.dom(".collection-detail__subscribe").containsText(subscribeLabel);
    await click(".collection-detail__subscribe");

    assert.strictEqual(calls.subscribe, 1, "POST /subscription fires once");
    assert.dom(".collection-detail__subscribe").containsText(unsubscribeLabel);
  });

  test("the subscriber entry opens the roster", async function (assert) {
    await visit("/collections/5");

    assert
      .dom(".collection-detail__subscribers")
      .containsText(i18n("collections.detail.view_subscribers"));
    await click(".collection-detail__subscribers");
    await settled();

    assert.dom(".d-modal").containsText(i18n("collections.detail.subscribers_title"));
    assert
      .dom(".collection-subscribers__subscriber")
      .exists({ count: 2 }, "one row per subscriber the endpoint returned");
    assert.dom(".collection-subscribers__subscriber").containsText("river");
    // Face and name lead to the same profile, so each row is one target: a second link
    // beside the first would only send the same click two ways.
    assert
      .dom(".collection-subscribers__subscriber a")
      .exists({ count: 2 }, "each row links face and name once");
    assert
      .dom(".collection-subscribers__subscriber a img.avatar")
      .exists({ count: 2 }, "with the faces riding inside them");
  });

  test("hides the subscriber entry when nobody subscribes", async function (assert) {
    await visit("/collections/10");

    assert.dom(".collection-detail__subscribe").exists("the page rendered");
    assert
      .dom(".collection-detail__subscribers")
      .doesNotExist("an empty roster has nothing to open");
  });

  test("unsubscribing DELETEs and flips the button back", async function (assert) {
    await visit("/collections/9");

    const unsubscribeLabel = i18n("collections.detail.unsubscribe");
    const subscribeLabel = i18n("collections.detail.subscribe");

    assert.dom(".collection-detail__subscribe").containsText(unsubscribeLabel);
    await click(".collection-detail__subscribe");

    assert.strictEqual(calls.unsubscribe, 1, "DELETE /subscription fires once");
    assert.dom(".collection-detail__subscribe").containsText(subscribeLabel);
  });
});

acceptance("Collections detail page anonymous, guest reading off", function (needs) {
  needs.settings({ collection_allow_anonymous: false });
  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    server.get("/collections.json", () => helper.response(listResponse()));
  });

  test("redirects an anonymous visitor away", async function (assert) {
    await visit("/collections/5");

    assert.strictEqual(currentURL(), "/collections");
  });
});

acceptance("Collections detail page anonymous, guest reading on", function (needs) {
  needs.settings({ collection_allow_anonymous: true });
  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    server.get("/collections.json", () => helper.response(listResponse()));
    server.get("/collections/5.json", () => helper.response(fullShape(5)));
    server.get("/collections/5/topics.json", () => helper.response(emptyTopics()));
  });

  test("lets a guest read but hides the subscribe button", async function (assert) {
    await visit("/collections/5");

    assert.dom(".collection-detail__name").hasText("Collection 5");
    assert.dom(".collection-detail__subscribe").doesNotExist("guests cannot subscribe");
  });

  test("hides the subscriber entry from a guest, whose count still shows", async function (assert) {
    // The fixture counts two subscribers: the number is part of the collection a guest
    // may read, the roster behind it is not (docs/01 §2).
    await visit("/collections/5");

    assert.dom(".collection-detail__name").hasText("Collection 5");
    assert
      .dom(".collection-detail__subscribers")
      .doesNotExist("a user list stays logged in only");
  });
});

acceptance("Collections detail page with the roster narrowed to the collection's team", function (needs) {
  // One level, two collections: 5 belongs to someone else and the viewer holds no role on
  // it, while 6 lists the viewer as a co-maintainer (docs/02 §5).
  needs.user(NON_STAFF);
  needs.settings({ collection_subscribers_visibility: "staff_owner_teamworker" });
  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    server.get("/collections.json", () => helper.response(listResponse()));
    // Owned by river, so this viewer is neither owner nor co-maintainer here.
    server.get("/collections/5.json", () => helper.response(fullShape(5)));
    server.get("/collections/6.json", () =>
      helper.response(fullShape(6, { teamworkers: [CURRENT_USER] }))
    );
    server.get("/collections/:id/topics.json", () => helper.response(emptyTopics()));
  });

  test("hides the subscriber entry where the viewer holds no role", async function (assert) {
    await visit("/collections/5");

    assert
      .dom(".collection-detail__subscribe")
      .exists("the page rendered for a signed-in viewer");
    assert
      .dom(".collection-detail__subscribers")
      .doesNotExist("the level does not reach a visitor with no role here");
  });

  test("shows it where the same level names the viewer's role here", async function (assert) {
    await visit("/collections/6");

    assert
      .dom(".collection-detail__subscribers")
      .containsText(i18n("collections.detail.view_subscribers"));
  });
});
