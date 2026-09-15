import { currentURL, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

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

acceptance("Collections mine and subscribed lists", function (needs) {
  needs.user();
  needs.pretender((server, helper) => {
    server.get("/collections/mine.json", () =>
      helper.response(listResponse([collectionTile(1, { name: "Owned gems :smile:" })]))
    );
    server.get("/collections/subscribed.json", () =>
      helper.response(
        listResponse([collectionTile(2, { name: "Followed box", is_subscribed: true })])
      )
    );
    server.get("/collections.json", () => helper.response(listResponse([collectionTile(3)])));
  });

  test("shows the collections the user owns or co-maintains", async function (assert) {
    await visit("/collections/mine");

    assert.dom(".collection-tile").exists({ count: 1 });
    assert.dom(".collection-tile").containsText("Owned gems");
    assert
      .dom(".collection-tile__name img.emoji")
      .exists("a name carrying an emoji draws the image, not the shortcode");
    assert.dom(".collection-list__new-button").exists("the create button lives here too");
    assert.dom('[data-link-name="collections-all"]').exists("the all-collections tab is present");
  });

  test("shows the collections the user subscribes to", async function (assert) {
    await visit("/collections/subscribed");

    assert.dom(".collection-tile").exists({ count: 1 });
    assert.dom(".collection-tile").containsText("Followed box");
    assert.dom(".collection-list__new-button").exists("every list tab carries the create button");
    assert.dom(".collection-sort__button").exists({ count: 4 }, "same four sort keys as the other lists");
    assert
      .dom(".collection-sort__button.-active")
      .containsText("Recently updated", "defaults to last_topic_added_at desc");
  });
});

acceptance("Collections personal pages anonymous", function (needs) {
  needs.pretender((server, helper) => {
    server.get("/collections.json", () => helper.response(listResponse([collectionTile(3)])));
  });

  test("redirects an anonymous visitor away from the mine route", async function (assert) {
    await visit("/collections/mine");

    assert.strictEqual(currentURL(), "/collections");
    assert.dom(".collection-list__new-button").doesNotExist();
    assert.dom('[data-link-name="collections-all"]').exists();
  });
});
