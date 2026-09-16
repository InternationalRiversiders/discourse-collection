import { click, currentURL, fillIn, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

function listResponse(collections) {
  return {
    collections,
    meta: { page: 0, page_size: 30, more: false, total: collections.length },
  };
}

const OWNER = {
  id: 1,
  username: "river",
  name: "River",
  avatar_template: "/user_avatar/test/river/{size}/1.png",
};

const calls = { create: 0 };

const CREATED = {
  id: 9,
  name: "Riverside Reads",
  description: "",
  topic_count: 0,
  owner: OWNER,
  teamworkers: [],
  subscriber_count: 0,
  is_subscribed: true,
  created_at: "2026-01-02T03:04:05.000Z",
  updated_at: "2026-01-02T03:04:05.000Z",
  last_topic_added_at: null,
};

acceptance("Collections create modal", function (needs) {
  needs.user({ can_create_collection: true });
  needs.settings({
    collection_name_min_length: 3,
    collection_name_max_length: 20,
    collection_description_max_length: 200,
  });

  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    calls.create = 0;
    server.get("/collections.json", () => helper.response(listResponse([])));
    server.get("/collections/mine.json", () => helper.response(listResponse([])));
    server.get("/collections/9.json", () => helper.response(CREATED));
    server.get("/collections/9/topics.json", () =>
      helper.response({ topics: [], meta: { page: 0, page_size: 30, more: false, total: 0 } })
    );
    server.post("/collections.json", () => {
      calls.create += 1;
      return helper.response(CREATED);
    });
  });

  test("carries the create button on the public list too", async function (assert) {
    await visit("/collections");

    assert.dom(".collection-list__new-button").exists();
    await click(".collection-list__new-button");

    assert.dom("#collection-form-name").exists("the same form opens from every list");
  });

  test("opens the create modal from the mine page and rejects a short name", async function (assert) {
    await visit("/collections/mine");
    await click(".collection-list__new-button");

    assert.dom("#collection-form-name").exists("the create modal opens");
    await fillIn("#collection-form-name", "ab");
    await click(".collection-form__submit");

    assert.dom(".collection-form__error").exists("a validation error is shown");
    assert.strictEqual(calls.create, 0, "no create request is sent while the name is invalid");
  });

  test("creates a collection and lands on its page", async function (assert) {
    await visit("/collections/mine");
    await click(".collection-list__new-button");
    await fillIn("#collection-form-name", "Riverside Reads");
    await click(".collection-form__submit");

    assert.strictEqual(currentURL(), "/collections/9");
    assert.dom(".collection-detail__name").hasText("Riverside Reads");
    assert.dom("#collection-form-name").doesNotExist("the modal is gone after success");
  });
});

acceptance("Collections create entry gate", function (needs) {
  // Who may create is the server's answer (docs/01 §3), so a list must not offer an
  // entry the create endpoint would refuse.
  needs.user({ can_create_collection: false });
  needs.settings({ collection_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/collections.json", () => helper.response(listResponse([])));
    server.get("/collections/mine.json", () => helper.response(listResponse([])));
  });

  test("leaves the create button off the lists", async function (assert) {
    await visit("/collections");
    assert
      .dom(".collection-list__new-button")
      .doesNotExist("the public list offers no way in");

    await visit("/collections/mine");
    assert.dom(".collection-list__new-button").doesNotExist("nor does the mine list");
  });
});
