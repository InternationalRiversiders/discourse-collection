import { click, currentURL, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import stubIntersectionObserver from "discourse/tests/helpers/stub-intersection-observer";
import {
  disableLoadMoreObserver,
  enableLoadMoreObserver,
} from "discourse/ui-kit/d-load-more";
import { i18n } from "discourse-i18n";

const OWNER = {
  id: 1,
  username: "river",
  name: "River",
  avatar_template: "/user_avatar/test/river/{size}/1.png",
};

// The owner's other collections as the detail endpoint hands them over (docs/03 §4): id
// and name only, already ordered and capped server-side.
const OTHER_COLLECTIONS = [
  { id: 13, name: "Riverside reads" },
  { id: 14, name: "Quotes" },
];

function fullShape(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 3,
    owner: OWNER,
    teamworkers: [],
    owner_collections: OTHER_COLLECTIONS,
    has_more_owner_collections: true,
    subscriber_count: 2,
    is_subscribed: false,
    created_at: "2026-01-02T03:04:05.000Z",
    updated_at: "2026-01-02T03:04:05.000Z",
    last_topic_added_at: "2026-02-01T01:00:00.000Z",
    ...overrides,
  };
}

// The list shape the /collections tiles read (docs/03 §1).
function tileShape(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 3,
    owner: OWNER,
    teamworker_count: 0,
    subscriber_count: 2,
    is_teamworker: false,
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

const requests = [];
let observations;

acceptance("Collections owner other collections", function (needs) {
  needs.user();
  needs.hooks.beforeEach(() => {
    requests.length = 0;
    // Infinite scroll only fires through the sentinel, and the test container has no
    // viewport for a real observer — so the stub stands in and the observer is turned
    // back on for this module.
    observations = stubIntersectionObserver();
    enableLoadMoreObserver();
  });
  needs.hooks.afterEach(() => {
    disableLoadMoreObserver();
  });
  needs.pretender((server, helper) => {
    server.get("/collections/12.json", () => helper.response(fullShape(12)));

    // Nothing held back, so the endpoint omits the flag entirely (docs/03 §4).
    const fits = fullShape(13, {
      owner_collections: [{ id: 12, name: "Collection 12" }],
    });
    delete fits.has_more_owner_collections;
    server.get("/collections/13.json", () => helper.response(fits));

    // An ownerless collection has no owner to list from, so the endpoint sends neither
    // key at all.
    const ownerless = fullShape(15, { owner: null });
    delete ownerless.owner_collections;
    delete ownerless.has_more_owner_collections;
    server.get("/collections/15.json", () => helper.response(ownerless));

    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    // The detail page loads the reading feed (docs/04 §1) for every opened collection.
    server.get("/collections/:id/topics.json", () =>
      helper.response(emptyTopics())
    );

    // The modal's endpoint (docs/03 §3): one handler for both pages, since a path match
    // ignores the query string.
    server.get("/collections.json", (request) => {
      requests.push(request.queryParams);
      const page = Number(request.queryParams.page ?? 0);

      return helper.response({
        collections:
          page === 0 ? [tileShape(13), tileShape(14)] : [tileShape(20)],
        meta: { page, page_size: 30, more: page === 0, total: 3 },
      });
    });
  });

  test("titles the owner's other collections and lists them as chips", async function (assert) {
    await visit("/collections/12");

    const chips =
      ".collection-detail__owner-collections a.collection-chips__chip";

    // The heading names the list; the chips beside it stay names only, so each one is
    // read on its own — a selector catching both would answer with the first every
    // time. `:first-of-type`/`:last-of-type` count anchors, leaving the row's trailing
    // button out of it.
    assert
      .dom(
        ".collection-detail__owner-collections .collection-detail__subheading"
      )
      .hasText(
        i18n("collections.owner_collections.heading", { username: "river" })
      );
    assert.dom(chips).exists({ count: 2 }, "one chip per collection");
    assert.dom(`${chips}:first-of-type`).hasText("Riverside reads");
    assert.dom(`${chips}:last-of-type`).hasText("Quotes");
  });

  test("links each chip to its collection", async function (assert) {
    await visit("/collections/12");

    assert
      .dom(".collection-detail__owner-collections a.collection-chips__chip")
      .hasAttribute("href", "/collections/13", "links to the collection");

    await click(
      ".collection-detail__owner-collections a.collection-chips__chip"
    );

    assert.strictEqual(currentURL(), "/collections/13");
  });

  test("reads More when the server held collections back and Details when it did not", async function (assert) {
    await visit("/collections/12");

    assert
      .dom(".collection-detail__owner-collections button.collection-chips__chip")
      .hasText(i18n("collections.owner_collections.more"));

    await visit("/collections/13");

    assert
      .dom(".collection-detail__owner-collections button.collection-chips__chip")
      .hasText(i18n("collections.owner_collections.details"));
  });

  test("opens the full list filtered by the owner", async function (assert) {
    await visit("/collections/12");

    await click(
      ".collection-detail__owner-collections button.collection-chips__chip"
    );
    await settled();

    // The modal lists every collection of that user, the one being read included, so its
    // title says so rather than repeating the heading above.
    assert
      .dom(".d-modal .d-modal__title-text")
      .hasText(
        i18n("collections.owner_collections.title", { username: "river" })
      );
    assert.strictEqual(requests.length, 1, "one page requested");
    assert.strictEqual(requests[0].username, "river", "filtered by the owner");
    assert
      .dom(".d-modal .collection-list__grid .collection-tile")
      .exists({ count: 2 }, "rendered with the list page's tiles");
    assert
      .dom(".d-modal .collection-role-hint")
      .containsText(
        i18n("collections.role_hint"),
        "the role badge is the viewer's, and the modal says so"
      );
  });

  test("pages the modal list as the sentinel comes into view", async function (assert) {
    await visit("/collections/12");

    await click(
      ".collection-detail__owner-collections button.collection-chips__chip"
    );
    await settled();

    await observations
      .find(({ element }) =>
        element.closest(".collection-owner-collections")
      )
      .trigger();

    assert.strictEqual(requests.at(-1).page, "1", "asked for the next page");
    assert
      .dom(".d-modal .collection-list__grid .collection-tile")
      .exists({ count: 3 }, "the page is appended");
  });

  test("renders nothing at all for a collection with no owner", async function (assert) {
    await visit("/collections/15");

    assert
      .dom(".collection-detail__owner-collections")
      .doesNotExist("no owner, no list");
  });
});
