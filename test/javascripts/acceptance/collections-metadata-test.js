import { click, currentURL, fillIn, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

// needs.user() makes the viewer eviltrout / id 19.
const VIEWER = { id: 19, username: "eviltrout", name: "Robin Ward" };
const OTHER_OWNER = { id: 20, username: "ana", name: "Ana" };

const DIALOG = ".dialog-body";
const DIALOG_CONFIRM = ".dialog-footer .btn-danger";

const EMPTY_FEED = {
  topics: [],
  meta: { page: 0, page_size: 30, more: false, total: 0 },
};

function fullShape(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 0,
    owner: VIEWER,
    teamworkers: [],
    subscriber_count: 5,
    is_subscribed: false,
    created_at: "2026-01-02T03:04:05.000Z",
    updated_at: "2026-01-02T03:04:05.000Z",
    last_topic_added_at: null,
    ...overrides,
  };
}

function parseBody(request) {
  return new URLSearchParams(request.requestBody);
}

acceptance("Collections metadata — owner", function (needs) {
  const requests = { deleted: [], updated: [] };

  needs.hooks.beforeEach(() => {
    requests.deleted = [];
    requests.updated = [];
  });

  needs.user();
  needs.settings({
    collection_enabled: true,
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
    const collection = fullShape(12, { topic_count: 0 });
    server.get("/collections/12.json", () => helper.response(collection));
    server.get("/collections/12/topics.json", () => helper.response(EMPTY_FEED));
    server.get("/collections.json", () =>
      helper.response({
        collections: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    server.put("/collections/12.json", (request) => {
      const body = parseBody(request);
      requests.updated.push({
        name: body.get("name"),
        description: body.get("description"),
      });
      return helper.response({
        ...collection,
        name: body.get("name"),
        description: body.get("description"),
      });
    });
    server.delete("/collections/12.json", () => {
      requests.deleted.push(12);
      return helper.response({ success: "OK" });
    });
  });

  test("offers the metadata edit and the delete to the owner, and nothing else", async function (assert) {
    await visit("/collections/12");
    await settled();

    assert.dom(".collection-detail__role.-owner").exists("the owner chip renders");
    assert.dom(".collection-detail__edit").exists();
    assert.dom(".collection-detail__delete").exists();
  });

  test("renames the collection from the edit modal", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__edit");
    assert
      .dom("#collection-form-name")
      .hasValue("Collection 12", "the modal opens on the stored name");
    assert.dom("#collection-form-description").hasValue("Description 12");

    await fillIn("#collection-form-name", "Riverside reads");
    await fillIn("#collection-form-description", "What I kept");
    await click(".collection-form__submit");
    await settled();

    assert.deepEqual(requests.updated, [
      { name: "Riverside reads", description: "What I kept" },
    ]);
    assert.dom(".collection-detail__name").hasText("Riverside reads");
    assert.dom(".collection-detail__description").hasText("What I kept");
    assert.dom("#collection-form-name").doesNotExist("the modal closes on save");
    assert.strictEqual(
      document.title,
      `Riverside reads - ${i18n("collections.nav_name")} - ${this.siteSettings.title}`,
      "the tab picks the new name up without a reload"
    );
  });

  test("rejects a too-short name without sending the write", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__edit");
    await fillIn("#collection-form-name", "ab");
    await click(".collection-form__submit");

    assert.dom(".collection-form__error").exists("a validation error is shown");
    assert.strictEqual(requests.updated.length, 0);
  });

  test("deletes the collection after confirming, and leaves the page", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__delete");
    assert.dom(DIALOG).exists("deletion asks first");
    assert
      .dom(DIALOG_CONFIRM)
      .hasText(
        i18n("collections.detail.delete"),
        "the confirm button is labelled, not a raw key"
      );
    assert.strictEqual(requests.deleted.length, 0, "nothing is sent before the confirm");

    await click(DIALOG_CONFIRM);
    await settled();

    assert.deepEqual(requests.deleted, [12]);
    assert.strictEqual(currentURL(), "/collections", "the deleted page is left behind");
  });

  test("keeps the collection when the delete confirm is dismissed", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__delete");
    await click(".dialog-footer .btn-default");
    await settled();

    assert.strictEqual(requests.deleted.length, 0);
    assert.strictEqual(currentURL(), "/collections/12");
  });
});

acceptance("Collections metadata — plain reader", function (needs) {
  needs.user();
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    // Owned by someone else and the viewer is not staff: no management entry at all.
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { owner: OTHER_OWNER }))
    );
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("hides the metadata entries from a reader with no role", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-detail__role").doesNotExist();
    assert.dom(".collection-detail__edit").doesNotExist();
    assert.dom(".collection-detail__delete").doesNotExist();
  });
});

acceptance("Collections metadata — guest", function (needs) {
  needs.settings({
    collection_enabled: true,
    collection_allow_anonymous: true,
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
    // Guest + unclaimed: nobody owns this collection, and the guest must not be
    // mistaken for the owner (undefined === undefined).
    server.get("/collections/15.json", () =>
      helper.response(fullShape(15, { owner: null }))
    );
    server.get("/collections/15/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("hides the owner entries from a guest on an unclaimed collection", async function (assert) {
    await visit("/collections/15");
    await settled();

    assert.dom(".collection-detail__owner.-unclaimed").exists();
    assert.dom(".collection-detail__edit").doesNotExist();
    assert.dom(".collection-detail__delete").doesNotExist();
  });
});

acceptance("Collections metadata — admin", function (needs) {
  const requests = { updated: [] };

  needs.hooks.beforeEach(() => {
    requests.updated = [];
  });

  needs.user({ admin: true });
  needs.settings({
    collection_enabled: true,
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
    const collection = fullShape(14, { owner: OTHER_OWNER });
    server.get("/collections/14.json", () => helper.response(collection));
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
    server.put("/collections/14.json", (request) => {
      const body = parseBody(request);
      requests.updated.push({
        name: body.get("name"),
        description: body.get("description"),
      });
      return helper.response({
        ...collection,
        name: body.get("name"),
        description: body.get("description"),
      });
    });
  });

  test("lets an admin edit someone else's collection but not delete it", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert
      .dom(".collection-detail__role")
      .doesNotExist("managing someone else's collection is not a role on it");
    assert.dom(".collection-detail__edit").exists();
    assert.dom(".collection-detail__delete").doesNotExist("deleting stays owner-only");

    await click(".collection-detail__edit");
    await fillIn("#collection-form-name", "Curated by staff");
    await click(".collection-form__submit");
    await settled();

    assert.deepEqual(requests.updated, [
      { name: "Curated by staff", description: "Description 14" },
    ]);
    assert.dom(".collection-detail__name").hasText("Curated by staff");
  });
});

acceptance("Collections metadata — unclaimed", function (needs) {
  needs.user({ admin: true });
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    // The detail page also loads the invitation record (docs/05 §2.3) for a viewer
    // who may read it, so every module needs the stub whether or not it asserts on it.
    server.get("/collections/:id/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    // owner: null — nobody holds the collection; staff carry the metadata edit.
    server.get("/collections/15.json", () =>
      helper.response(fullShape(15, { owner: null }))
    );
    server.get("/collections/15/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("offers the edit on an unclaimed collection to staff", async function (assert) {
    await visit("/collections/15");
    await settled();

    assert.dom(".collection-detail__owner.-unclaimed").exists();
    assert.dom(".collection-detail__edit").exists();
    assert.dom(".collection-detail__delete").doesNotExist();
  });
});

acceptance("Collections metadata — moderator", function (needs) {
  needs.user({ moderator: true });
  needs.settings({
    collection_enabled: true,
    collection_moderators_can_manage_collections: false,
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
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { owner: OTHER_OWNER }))
    );
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("withholds the edit while the site setting is off", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-detail__edit").doesNotExist();
    assert.dom(".collection-detail__role").doesNotExist();
  });
});

acceptance("Collections metadata — moderator with the setting on", function (needs) {
  needs.user({ moderator: true });
  needs.settings({
    collection_enabled: true,
    collection_moderators_can_manage_collections: true,
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
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { owner: OTHER_OWNER }))
    );
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("grants the edit once the site setting is on", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-detail__edit").exists();
    assert.dom(".collection-detail__role").doesNotExist();
    assert.dom(".collection-detail__delete").doesNotExist();
  });
});
