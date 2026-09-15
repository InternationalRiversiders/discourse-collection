import { currentURL, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import stubIntersectionObserver from "discourse/tests/helpers/stub-intersection-observer";
import {
  disableLoadMoreObserver,
  enableLoadMoreObserver,
} from "discourse/ui-kit/d-load-more";
import { i18n } from "discourse-i18n";

function collectionTile(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 1,
    owner: { id: 100 + id, username: "river", name: "River", avatar_template: "/user_avatar/test/river/{size}/1.png" },
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

function listResponse(collections, meta = {}) {
  return {
    collections,
    meta: { page: 0, page_size: 30, more: false, total: collections.length, ...meta },
  };
}

const requests = [];
let observations;

acceptance("Collections profile activity tab", function (needs) {
  needs.user();
  needs.hooks.beforeEach(() => {
    requests.length = 0;
    // Infinite scroll only fires through the sentinel, and the test container has no
    // viewport for a real observer.
    observations = stubIntersectionObserver();
    enableLoadMoreObserver();
  });
  needs.hooks.afterEach(() => {
    disableLoadMoreObserver();
  });
  needs.pretender((server, helper) => {
    // One handler for both pages: a path match ignores the query string (docs/03 §3).
    server.get("/collections.json", (request) => {
      requests.push(request.queryParams);
      const page = Number(request.queryParams.page ?? 0);

      return helper.response(
        page === 0
          ? listResponse([collectionTile(1, { name: "Owned gems" })], {
              more: true,
              total: 2,
            })
          : listResponse([collectionTile(2, { name: "Co-maintained box" })], {
              page: 1,
              total: 2,
            })
      );
    });
  });

  test("appends the tab to the profile's activity navigation", async function (assert) {
    await visit("/u/eviltrout/activity");

    assert
      .dom(".user-nav__activity-collections a")
      .hasText(i18n("collections.nav_name"), "the tab carries the product name");

    await visit("/u/eviltrout/activity/collections");

    assert.strictEqual(currentURL(), "/u/eviltrout/activity/collections");
  });

  test("renders the user's collections with the list page's tiles", async function (assert) {
    await visit("/u/eviltrout/activity/collections");

    assert.strictEqual(
      document.title,
      [
        i18n("collections.nav_name"),
        i18n("user.activity_stream"),
        "eviltrout",
        this.siteSettings.title,
      ].join(" - "),
      "our segment opens the title, and core's ancestors supply the rest"
    );
    assert.strictEqual(requests.length, 1, "one page requested");
    assert.strictEqual(requests[0].username, "eviltrout", "filtered by the profile's user");
    assert.strictEqual(requests[0].sort, undefined, "the order is fixed server-side");
    assert.strictEqual(requests[0].order, undefined, "no order override either");

    assert
      .dom(".collection-list__title")
      .hasText(i18n("collections.user_activity.title", { username: "eviltrout" }));
    assert.dom(".collection-list__grid .collection-tile").exists({ count: 1 });
    assert.dom(".collection-tile").containsText("Owned gems");
    assert.dom(".collection-list__total").containsText("2");
    // Every tile here is this user's, so the role badge would read as theirs; the page
    // spells out that it is the viewer's instead.
    assert
      .dom(".collection-role-hint")
      .containsText(i18n("collections.role_hint"));
  });

  test("hides the list tabs and the sort controls", async function (assert) {
    await visit("/u/eviltrout/activity/collections");

    assert
      .dom(".collection-list__tabs")
      .doesNotExist("the collection list views are elsewhere");
    assert.dom(".collection-sort__button").doesNotExist("the order is not up to the viewer");
    assert.dom(".collection-list__new-button").doesNotExist("collections are created on the mine page");
  });

  test("pages the list as the sentinel comes into view", async function (assert) {
    await visit("/u/eviltrout/activity/collections");

    await observations
      .find(({ element }) => element.closest(".collection-list"))
      .trigger();

    assert.strictEqual(requests.at(-1).page, "1", "asked for the next page");
    assert
      .dom(".collection-list__grid .collection-tile")
      .exists({ count: 2 }, "the page is appended");
  });
});

acceptance("Collections profile activity tab empty", function (needs) {
  needs.user();
  needs.pretender((server, helper) => {
    server.get("/collections.json", () => helper.response(listResponse([])));
  });

  test("names the user who has nothing to show", async function (assert) {
    await visit("/u/eviltrout/activity/collections");

    assert
      .dom(".empty-state__title")
      .hasText(i18n("collections.user_activity.empty_title"));
    assert
      .dom(".empty-state__body")
      .hasText(i18n("collections.user_activity.empty", { username: "eviltrout" }));
    assert.dom(".collection-tile").doesNotExist();
  });
});

acceptance("Collections profile activity tab, guest reading on", function (needs) {
  needs.settings({
    collection_enabled: true,
    collection_allow_anonymous: true,
  });
  needs.pretender((server, helper) => {
    server.get("/collections.json", () =>
      helper.response(listResponse([collectionTile(2, { name: "Unclaimed box" })]))
    );
  });

  test("shows a guest the tab and the list behind it", async function (assert) {
    await visit("/u/eviltrout/activity/collections");

    assert.strictEqual(currentURL(), "/u/eviltrout/activity/collections");
    assert.dom(".user-nav__activity-collections a").exists();
    assert.dom(".collection-tile").containsText("Unclaimed box");
    // A guest holds no role and sees no badge, so there is nothing to explain.
    assert.dom(".collection-role-hint").doesNotExist();
  });
});

acceptance("Collections profile activity tab, guest reading off", function (needs) {
  test("hides the tab from a guest and turns the direct URL back", async function (assert) {
    await visit("/u/eviltrout/activity");

    assert
      .dom(".user-nav__activity-collections")
      .doesNotExist("a guest only gets the tab when anonymous reading is on");

    await visit("/u/eviltrout/activity/collections");

    assert.strictEqual(currentURL(), "/u/eviltrout/activity");
  });
});

acceptance("Collections profile activity tab disabled", function (needs) {
  needs.user();
  needs.settings({ collection_enabled: false });

  test("hides the tab when the plugin is disabled", async function (assert) {
    await visit("/u/eviltrout/activity");

    assert.dom(".user-nav__activity-collections").doesNotExist();
  });
});
