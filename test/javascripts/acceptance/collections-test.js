import { click, currentURL, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import userFixtures from "discourse/tests/fixtures/user-fixtures";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
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

function listResponse(collections) {
  return {
    collections,
    meta: { page: 0, page_size: 30, more: false, total: collections.length },
  };
}

function emptyTopics() {
  return { topics: [], meta: { page: 0, page_size: 30, more: false, total: 0 } };
}

acceptance("Collections list", function (needs) {
  needs.user();
  needs.pretender((server, helper) => {
    // Card behind the tile's owner link (core fetches this when one is clicked).
    server.get("/u/river/card.json", () =>
      helper.response(cloneJSON(userFixtures["/u/charlie/card.json"]))
    );
    server.get("/collections.json", () =>
      helper.response(
        listResponse([
          collectionTile(1, { name: "Riverside gems", teamworker_count: 2 }),
          collectionTile(2, { name: "Unclaimed box", owner: null, description: "", topic_count: 0, subscriber_count: 0, last_topic_added_at: null }),
        ])
      )
    );
    server.get("/collections/1.json", () =>
      helper.response(
        collectionTile(1, {
          name: "Riverside gems",
          teamworkers: [],
        })
      )
    );
    // The detail page loads the reading feed (docs/04 §1) for any opened collection.
    server.get("/collections/:id/topics.json", () => helper.response(emptyTopics()));
  });

  test("clicking a tile opens the collection detail page", async function (assert) {
    await visit("/collections");

    await click(".collection-tile");

    assert.strictEqual(currentURL(), "/collections/1");
    assert.dom(".collection-detail__name").hasText("Riverside gems");
  });

  test("opens the owner's card from a tile without leaving the list", async function (assert) {
    await visit("/collections");

    const owner = document.querySelector(".collection-tile__owner-link");

    assert.true(
      owner.matches("a[data-user-card]"),
      "the tile owner is its own user-card anchor"
    );
    assert.true(
      owner.getAttribute("href").endsWith("/u/river"),
      "pointing at the owner's profile"
    );

    await click(owner);
    await settled();

    assert.dom(".user-card .card-content").exists("the owner link opens the card");
    assert.strictEqual(
      currentURL(),
      "/collections",
      "and the tile around it does not navigate"
    );
  });

  test("renders a tile per collection returned by the endpoint", async function (assert) {
    await visit("/collections");

    assert.dom(".collection-tile").exists({ count: 2 });
    assert.dom(".collection-tile").containsText("Riverside gems");
    assert.dom(".collection-tile").containsText("Unclaimed box");
    assert.dom(".collection-list__total").containsText("2");
    // The note belongs to the pages that list a single user's collections, where a role
    // badge could be read as that user's.
    assert.dom(".collection-role-hint").doesNotExist();
  });

  test("shows topic, subscriber and maintainer counts plus both timestamps", async function (assert) {
    await visit("/collections");

    assert
      .dom(".collection-tile:first-child .collection-tile__stat")
      .exists({ count: 3 });
    const maintainerTitle = i18n("collections.stats.teamworker_count");
    assert
      .dom(`.collection-tile:first-child [title="${maintainerTitle}"]`)
      .exists();
    assert
      .dom(".collection-tile:first-child .collection-tile__activity")
      .exists({ count: 2 })
      .includesText(i18n("collections.tile.created_at"))
      .includesText(i18n("collections.tile.last_topic_added_at"));
  });

  test("marks an ownerless collection as unclaimed", async function (assert) {
    await visit("/collections");

    assert.dom(".collection-tile").containsText(i18n("collections.no_owner"));
  });

  test("adds a community sidebar link", async function (assert) {
    await visit("/");

    assert.dom('[data-link-name="collections"]').exists();
  });
});

acceptance("Collections list empty state", function (needs) {
  needs.user();
  needs.pretender((server, helper) => {
    server.get("/collections.json", () => helper.response(listResponse([])));
  });

  test("shows the empty state when the endpoint returns nothing", async function (assert) {
    await visit("/collections");

    assert.dom(".empty-state__title").hasText(i18n("collections.empty_title"));
    assert.dom(".collection-tile").doesNotExist();
  });
});

acceptance("Collections list anonymous, guest reading on", function (needs) {
  needs.settings({
    collection_enabled: true,
    collection_allow_anonymous: true,
  });
  needs.pretender((server, helper) => {
    server.get("/collections.json", () =>
      helper.response(
        listResponse([collectionTile(2, { name: "Unclaimed box", owner: null })])
      )
    );
  });

  test("does not read a guest as the owner of an unclaimed collection", async function (assert) {
    await visit("/collections");

    assert.dom(".collection-tile__name").hasText("Unclaimed box");
    // A guest has no id and an unclaimed collection has no owner, so a bare
    // `owner?.id === currentUser?.id` would compare undefined with undefined and
    // hand the guest the owner chip.
    assert.dom(".collection-tile__role").doesNotExist();
    assert.dom(".collection-list__tab").exists({ count: 1 }, "only the public tab");
  });
});

acceptance("Collections disabled", function (needs) {
  needs.user();
  needs.settings({ collection_enabled: false });

  test("hides the community sidebar link when the plugin is disabled", async function (assert) {
    await visit("/");

    assert.dom('[data-link-name="collections"]').doesNotExist();
  });
});
