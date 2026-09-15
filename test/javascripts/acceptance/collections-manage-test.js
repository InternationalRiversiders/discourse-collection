import { click, fillIn, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

const OWNER = { id: 19, username: "eviltrout", name: "Robin Ward" };
// A second user, so a collection can be owned by someone other than the viewer
// (needs.user() makes the viewer eviltrout / id 19).
const OTHER_OWNER = { id: 20, username: "ana", name: "Ana" };

const FIRST_ROW = ".collection-topics__list .collection-topic:first-child";
// The second row is the one carrying inline replies, so it owns the unfeature entry.
const SECOND_ROW = ".collection-topics__list .collection-topic:nth-child(2)";
// The cascade warning is a modal of its own rather than a dialog, because it carries the
// count and a way to look at what is about to go.
const REMOVE_MODAL = ".remove-topic-modal";
const REMOVE_CONFIRM = ".remove-topic__confirm";

function fullShape(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 0,
    owner: OWNER,
    teamworkers: [],
    subscriber_count: 5,
    is_subscribed: false,
    created_at: "2026-01-02T03:04:05.000Z",
    updated_at: "2026-01-02T03:04:05.000Z",
    last_topic_added_at: "2026-06-01T01:00:00.000Z",
    ...overrides,
  };
}

// The responses' top-level `users` map (docs/04 §1): rows reference authors by id
// only, so this is where every avatar and username on the feed comes from.
const USERS = {
  42: { id: 42, username: "river", name: "River", avatar_template: "/images/avatar.png" },
  77: { id: 77, username: "ana", name: "Ana", avatar_template: "/images/avatar.png" },
};

function reply(postNumber, userId) {
  return {
    post_id: 300 + postNumber,
    post_number: postNumber,
    user_id: userId,
    created_at: "2026-05-02T00:00:00.000Z",
    excerpt: `Reply ${postNumber} featured reply`,
  };
}

function topicRow(id, addedAt, overrides = {}) {
  return {
    added_at: addedAt,
    note: "",
    topic: {
      id,
      slug: `river-topic-${id}`,
      fancy_title: `Riverside topic ${id}`,
      category_id: 1,
      user_id: 42,
      excerpt: `Excerpt ${id}`,
      created_at: "2026-04-01T00:00:00.000Z",
      bumped_at: "2026-04-02T00:00:00.000Z",
      posts_count: 5,
    },
    ...overrides,
  };
}

const ROW_WITH_NOTE = topicRow(101, "2026-06-01T08:00:00.000Z", {
  note: "Editor's note",
});

// Carries two inline replies plus an overflow, so the row also exercises the
// per-reply entry and the recomputed has_more flag coming back from a write.
const ROW_WITH_REPLIES = topicRow(102, "2026-05-10T08:00:00.000Z", {
  selected_replies: [reply(4, 42), reply(5, 77)],
  has_more_selected_replies: true,
});

const FEED = {
  topics: [ROW_WITH_NOTE, ROW_WITH_REPLIES],
  users: USERS,
  meta: { page: 0, page_size: 30, more: false, total: 2 },
};

function patchNote(request) {
  return new URLSearchParams(request.requestBody).get("note");
}

acceptance("Collections reading management — maintainer", function (needs) {
  const requests = { deleted: [], patched: [] };

  needs.hooks.beforeEach(() => {
    requests.deleted = [];
    requests.patched = [];
  });

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
    server.get("/collections/12.json", () =>
      helper.response(fullShape(12, { name: "Riverside reads", topic_count: 2 }))
    );
    server.get("/collections/12/topics.json", () => helper.response(FEED));

    // How many selected replies a removal would cascade away (docs/04 §7): only the row
    // that carries them has anything to warn about.
    server.get(
      "/collections/:id/topics/:topic_id/selected_replies/count.json",
      (request) =>
        helper.response({
          selected_reply_count: request.params.topic_id === "102" ? 2 : 0,
        })
    );

    // The overflow pager behind the warning's "view" entry.
    server.get("/collections/12/topics/102/selected_replies.json", () =>
      helper.response({
        selected_replies: [reply(4, 42), reply(5, 77)],
        users: USERS,
        meta: { page: 0, page_size: 30, more: false, total: 2 },
      })
    );

    server.delete("/collections/12/topics/101.json", () => {
      requests.deleted.push(101);
      return helper.response(
        fullShape(12, {
          name: "Riverside reads",
          topic_count: 1,
          last_topic_added_at: ROW_WITH_REPLIES.added_at,
        })
      );
    });
    server.delete("/collections/12/topics/102.json", () => {
      requests.deleted.push(102);
      return helper.response(
        fullShape(12, {
          name: "Riverside reads",
          topic_count: 1,
          last_topic_added_at: ROW_WITH_NOTE.added_at,
        })
      );
    });
    server.patch("/collections/12/topics/102.json", (request) => {
      requests.patched.push({ topicId: 102, body: request.requestBody });
      return helper.response({
        ...ROW_WITH_REPLIES,
        selected_replies: [reply(5, 77)],
        users: USERS,
        has_more_selected_replies: false,
      });
    });
    server.patch("/collections/12/topics/101.json", (request) => {
      requests.patched.push({ topicId: 101, body: request.requestBody });
      return helper.response({
        ...ROW_WITH_NOTE,
        note: patchNote(request),
        users: USERS,
      });
    });
  });

  test("shows the row entries to a maintainer and nothing that adds", async function (assert) {
    await visit("/collections/12");
    await settled();

    assert.dom(".collection-topic__edit-note").exists({ count: 2 }, "every row is editable");
    assert.dom(".collection-topic__remove").exists({ count: 2 });
    assert.dom(".collection-topic__unfeature").exists(
      { count: 2 },
      "one unfeature entry per inline reply"
    );
    assert.dom(".collection-topic__view-all").exists("the overflow entry survives");
  });

  test("removes a topic holding selected replies after confirming", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${SECOND_ROW} .collection-topic__remove`);

    // This is the one entry whose cascade cannot be undone, so it says how many rows go
    // with it rather than asking blindly.
    assert.dom(REMOVE_MODAL).exists("the removal asks first");
    assert
      .dom(".remove-topic__message")
      .hasText(
        i18n("collections.reading.confirm_remove_topic", { count: 2 }),
        "the warning carries the count"
      );
    assert
      .dom(REMOVE_CONFIRM)
      .hasText(i18n("collections.topic.uncollect"), "the confirm button is labelled, not a raw key");
    assert.strictEqual(requests.deleted.length, 0, "nothing is sent before the confirm");

    await click(REMOVE_CONFIRM);
    await settled();

    assert.deepEqual(requests.deleted, [102]);
    assert.dom(".collection-topic").exists({ count: 1 });
    assert.dom(".collection-topics__list").containsText("Riverside topic 101");
    assert
      .dom(".collection-detail__stat:first-of-type dd")
      .hasText("1", "the header topic count follows the write");
  });

  test("removes a topic holding no selected replies without asking", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${FIRST_ROW} .collection-topic__remove`);
    await settled();

    assert
      .dom(REMOVE_MODAL)
      .doesNotExist("nothing would be lost, so nothing to warn about");
    assert.deepEqual(requests.deleted, [101]);
    assert.dom(".collection-topic").exists({ count: 1 });
  });

  test("returns to the removal confirm after looking at the replies", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${SECOND_ROW} .collection-topic__remove`);
    await click(".remove-topic__view");
    await settled();

    assert
      .dom(".topic-selected-replies")
      .exists("the view entry opens the overflow pager");
    assert.dom(REMOVE_MODAL).doesNotExist("which takes the confirm down with it");

    await click(".modal-close");
    await settled();

    assert.dom(REMOVE_MODAL).exists("and the confirm is back once the look is over");
    assert.strictEqual(requests.deleted.length, 0);
  });

  test("keeps the topic when the removal confirm is dismissed", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${SECOND_ROW} .collection-topic__remove`);
    await click(".remove-topic__cancel");
    await settled();

    assert.strictEqual(requests.deleted.length, 0);
    assert.dom(".collection-topic").exists({ count: 2 });
  });

  test("unfeatures an inline reply without asking", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${SECOND_ROW} .collection-topic__unfeature`);
    await settled();

    // Featuring the reply again restores the row, so this one doesn't stop to ask.
    assert.dom(".dialog-body").doesNotExist("no confirmation to sit through");
    assert.strictEqual(requests.patched.length, 1);
    assert.true(
      requests.patched[0].body.includes("selected_replies"),
      "the write is the incremental selected-replies removal"
    );
    // The write response replaces the whole row, so the surviving reply and the
    // recomputed overflow flag both come from the server.
    assert.dom(`${SECOND_ROW} .collection-topic__reply`).exists({ count: 1 });
    assert.dom(`${SECOND_ROW} .collection-topic__reply-user`).containsText("ana");
    assert.dom(`${SECOND_ROW} .collection-topic__view-all`).doesNotExist();
  });

  test("edits a note inline", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${FIRST_ROW} .collection-topic__edit-note`);
    assert
      .dom(".collection-topic__note-input")
      .hasValue("Editor's note", "the editor opens on the stored note");

    await fillIn(".collection-topic__note-input", "Updated note");
    await click(".collection-topic__note-save");
    await settled();

    assert.strictEqual(requests.patched.length, 1);
    assert.true(requests.patched[0].body.includes("note"), "the note rides on docs/04 §4");
    assert.dom(".collection-topic__note-input").doesNotExist("the editor closes on save");
    assert.dom(`${FIRST_ROW} .collection-topic__note`).containsText("Updated note");
  });

  test("clears a note with an empty editor", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${FIRST_ROW} .collection-topic__edit-note`);
    await fillIn(".collection-topic__note-input", "");
    await click(".collection-topic__note-save");
    await settled();

    assert.strictEqual(requests.patched.length, 1);
    assert.dom(`${FIRST_ROW} .collection-topic__note`).doesNotExist("the note is gone");
  });

  test("discards the draft when the editor is cancelled", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(`${FIRST_ROW} .collection-topic__edit-note`);
    await fillIn(".collection-topic__note-input", "Never saved");
    await click(".collection-topic__note-cancel");

    assert.strictEqual(requests.patched.length, 0);
    assert.dom(`${FIRST_ROW} .collection-topic__note`).containsText("Editor's note");
  });
});

acceptance("Collections reading management — reader", function (needs) {
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
    // Owned by someone else: the viewer has no role here, so no entry may render.
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { owner: OTHER_OWNER, topic_count: 2 }))
    );
    server.get("/collections/14/topics.json", () => helper.response(FEED));
  });

  test("hides every management entry from a plain reader", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-topic").exists({ count: 2 });
    assert.dom(".collection-topic__actions").doesNotExist();
    assert.dom(".collection-topic__edit-note").doesNotExist();
    assert.dom(".collection-topic__remove").doesNotExist();
    assert.dom(".collection-topic__unfeature").doesNotExist();
  });
});

acceptance("Collections reading management — staff", function (needs) {
  const requests = { patched: [] };

  needs.hooks.beforeEach(() => {
    requests.patched = [];
  });

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
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { owner: OTHER_OWNER, topic_count: 2 }))
    );
    server.get("/collections/14/topics.json", () => helper.response(FEED));
    server.put("/collections/14/topics/101/note.json", (request) => {
      requests.patched.push(request.requestBody);
      return helper.response({
        ...ROW_WITH_NOTE,
        note: patchNote(request),
        users: USERS,
      });
    });
  });

  test("lets staff rewrite a note without granting content management", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-topic__edit-note").exists({ count: 2 });
    assert.dom(".collection-topic__remove").doesNotExist("staff cannot remove topics");
    assert.dom(".collection-topic__unfeature").doesNotExist();

    await click(`${FIRST_ROW} .collection-topic__edit-note`);
    await fillIn(".collection-topic__note-input", "Moderated note");
    await click(".collection-topic__note-save");
    await settled();

    assert.strictEqual(requests.patched.length, 1, "the staff rewrite goes to docs/06 §1");
    assert.dom(`${FIRST_ROW} .collection-topic__note`).containsText("Moderated note");
    assert.dom(".collection-topic__note-input").doesNotExist();
  });
});
