import { click, currentURL, fillIn, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import topicFixtures from "discourse/tests/fixtures/topic";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

const TOPIC_URL = "/t/internationalization-localization/280";

const COLLECTED = ".collection-topic-chips:not(.-featured)";
const FEATURED = ".collection-topic-chips.-featured";
const CHIP = ".collection-chips__chip";
const LABEL = ".collection-chips__label";
const MENU_BUTTON = ".post-action-menu__collection";
const SHOW_MORE = ".post-controls .show-more-actions";

// The reverse lookup the server injects onto /t/:id.json (docs/07): the
// topic level `collections` (id+name) plus `selected_by_collection_ids` on the
// posts some collection features. Names live on the topic level only.
const COLLECTIONS = [
  { id: 12, name: "Riverside reads" },
  { id: 30, name: "Quotes" },
];

function collectionShape(id, name, overrides = {}) {
  return {
    id,
    name,
    description: "",
    topic_count: 3,
    owner: { id: 19, username: "eviltrout", name: "Robin Ward" },
    teamworker_count: 0,
    subscriber_count: 0,
    is_teamworker: false,
    is_subscribed: false,
    created_at: "2026-01-02T03:04:05.000Z",
    updated_at: "2026-01-02T03:04:05.000Z",
    last_topic_added_at: "2026-06-01T01:00:00.000Z",
    ...overrides,
  };
}

function replyId() {
  return topicFixtures["/t/280/1.json"].post_stream.posts.find(
    (post) => post.post_number === 2
  ).id;
}

function topicPayload() {
  const topic = cloneJSON(topicFixtures["/t/280/1.json"]);
  topic.collections = COLLECTIONS;

  const reply = topic.post_stream.posts.find((post) => post.post_number === 2);
  reply.selected_by_collection_ids = [30];

  return topic;
}

async function openManager(postNumber) {
  await click(`#post_${postNumber} ${SHOW_MORE}`);
  await click(`#post_${postNumber} ${MENU_BUTTON}`);
  await settled();
}

async function clickRowAction(collectionId) {
  await click(
    `[data-collection-id="${collectionId}"] .add-to-collection__action`
  );
  await settled();
}

acceptance("Collections topic page reverse lookup", function (needs) {
  const requests = { posted: [], removed: [], patched: [], created: [] };
  let createdCollection = null;

  needs.hooks.beforeEach(() => {
    requests.posted = [];
    requests.removed = [];
    requests.patched = [];
    requests.created = [];
    createdCollection = null;
  });

  needs.user();
  needs.settings({
    collection_enabled: true,
    // The entry leans on a populated collapsed region, which is what core's
    // default ships; spelled out so the dependency is visible here.
    post_menu_hidden_items: "flag|bookmark|edit|delete|admin",
  });

  needs.pretender((server, helper) => {
    const payload = () => helper.response(topicPayload());

    server.get("/t/280.json", payload);
    server.get("/t/280/:post_number.json", payload);

    server.get("/collections/mine.json", () => {
      const collections = [
        collectionShape(12, "Riverside reads"),
        // Also holds this topic, and features the reply below.
        collectionShape(30, "Quotes"),
        collectionShape(40, "Morning links", { topic_count: 0 }),
      ];

      // Un-collecting reopens the picker, which refetches this list, so the count of a
      // collection that was just freed comes from here on the second pass.
      if (requests.removed.includes("30")) {
        collections[1].topic_count = 2;
      }

      // A collection that was just created holds no topics, so the endpoint's ordering
      // (last topic added, newest first) really does put it last; the picker is expected
      // to lift it to the top all the same.
      if (createdCollection) {
        collections.push(createdCollection);
      }

      return helper.response({
        collections,
        meta: {
          page: 0,
          page_size: 30,
          more: false,
          total: collections.length,
        },
      });
    });

    // Following a row's name lands on the collection detail page, which loads the
    // collection, its reading feed and its record of invitations.
    server.get("/collections/12.json", () =>
      helper.response(collectionShape(12, "Riverside reads", { teamworkers: [] }))
    );

    server.get("/collections/12/topics.json", () =>
      helper.response({
        topics: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );

    server.get("/collections/12/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );

    server.post("/collections.json", (request) => {
      const body = new URLSearchParams(request.requestBody);
      requests.created.push(body.get("name"));
      createdCollection = collectionShape(41, body.get("name"), {
        topic_count: 0,
        last_topic_added_at: null,
      });

      return helper.response(createdCollection);
    });

    // Both writes answer with the collection's full shape (docs/04 §3 / §5), counters
    // included; the picker row reads its count back from here rather than counting.
    server.post("/collections/:id/topics.json", (request) => {
      requests.posted.push(request.params.id);
      return helper.response(
        collectionShape(Number(request.params.id), "Morning links", {
          topic_count: 1,
        })
      );
    });

    // The un-collect entry asks how many selected replies the removal would cascade away
    // before it bothers anyone (docs/04 §7): 30 features the reply above, the rest hold
    // none.
    server.get(
      "/collections/:id/topics/:topic_id/selected_replies/count.json",
      (request) =>
        helper.response({
          selected_reply_count: request.params.id === "30" ? 2 : 0,
        })
    );

    server.delete("/collections/:id/topics/:topic_id.json", (request) => {
      requests.removed.push(request.params.id);
      return helper.response(
        collectionShape(Number(request.params.id), "Quotes", { topic_count: 2 })
      );
    });

    server.patch("/collections/:id/topics/:topic_id.json", (request) => {
      const body = new URLSearchParams(request.requestBody);
      const mode = body.has("selected_replies[add][]") ? "add" : "remove";

      requests.patched.push({
        id: request.params.id,
        mode,
        postIds: body.getAll(`selected_replies[${mode}][]`),
      });

      return helper.response({
        added_at: "2026-06-01T01:00:00.000Z",
        note: "",
        topic: { id: Number(request.params.topic_id) },
        selected_replies: [],
      });
    });
  });

  test("lists the collections holding the topic", async function (assert) {
    await visit(TOPIC_URL);
    await settled();

    assert
      .dom(`div.post__contents > ${COLLECTED}`)
      .exists("the chips sit inside the first post's contents");
    assert
      .dom(`${COLLECTED} ${LABEL}`)
      .hasText(i18n("collections.topic.collected_in"));
    assert
      .dom(`${COLLECTED} ${CHIP}`)
      .exists({ count: 2 }, "one chip per collection");
    assert
      .dom(`${COLLECTED} ${CHIP}`)
      .hasText("Riverside reads Quotes", "chips carry names only");
    assert
      .dom(".collection-topic-chips__add")
      .doesNotExist("the chips carry no inline action");
  });

  test("links each chip to its collection", async function (assert) {
    await visit(TOPIC_URL);
    await settled();

    assert
      .dom(`${COLLECTED} ${CHIP}`)
      .hasAttribute("href", "/collections/12", "links to the collection");
  });

  test("lists the featuring collections on the reply", async function (assert) {
    await visit(TOPIC_URL);
    await settled();

    assert.dom(FEATURED).exists("the featured set renders on its own");
    assert
      .dom(`${FEATURED} ${LABEL}`)
      .hasText(i18n("collections.topic.featured_in"));
    assert
      .dom(`${FEATURED} ${CHIP}`)
      .exists({ count: 1 }, "resolved against the topic level name table");
    assert.dom(`${FEATURED} ${CHIP}`).hasText("Quotes");
  });

  test("keeps the entry behind the more toggle on every post", async function (assert) {
    await visit(TOPIC_URL);
    await settled();

    assert
      .dom(`#post_1 ${MENU_BUTTON}`)
      .doesNotExist("the first post starts without it");
    assert
      .dom(`#post_2 ${MENU_BUTTON}`)
      .doesNotExist("a reply starts without it");

    await click(`#post_1 ${SHOW_MORE}`);

    assert.dom(`#post_1 ${MENU_BUTTON}`).exists("the first post reveals it");
    assert
      .dom(`#post_1 ${MENU_BUTTON} use`)
      .hasAttribute("href", "#collection", "it wears the plugin's own icon");

    await click(`#post_2 ${SHOW_MORE}`);

    assert.dom(`#post_2 ${MENU_BUTTON}`).exists("a reply reveals it");
  });

  test("collects the topic without asking", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(1);

    assert
      .dom(".add-to-collection__row")
      .exists({ count: 3 }, "lists my collections");
    assert
      .dom('[data-collection-id="12"] .add-to-collection__action')
      .hasText(i18n("collections.topic.uncollect"), "a held topic can be freed");
    // 30 also features one of the topic's replies, which must not turn the row into
    // a feature toggle: the first post only ever manages its topic.
    assert
      .dom('[data-collection-id="30"] .add-to-collection__action')
      .hasText(i18n("collections.topic.uncollect"));
    assert
      .dom('[data-collection-id="40"] .add-to-collection__action')
      .hasText(i18n("collections.topic.collect"));
    assert
      .dom('[data-collection-id="40"] .add-to-collection__count')
      .hasText("0", "the row carries the collection's topic count");

    await clickRowAction(40);

    // Collecting is reversible — the same row frees the topic again — so it goes through
    // on the click.
    assert.dom(".dialog-body").doesNotExist("no confirmation to sit through");
    assert.deepEqual(requests.posted, ["40"], "posts the picked collection");
    assert.dom(".add-to-collection").exists("the manager stays open");
    assert
      .dom('[data-collection-id="40"] .add-to-collection__count')
      .hasText("1", "the row takes the count the write answered with");
    assert
      .dom(`${COLLECTED} ${CHIP}`)
      .exists({ count: 3 }, "the new chip appears without reloading the topic");
    assert.dom(COLLECTED).containsText("Morning links");
  });

  test("un-collects the topic and drops its featured replies", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(1);

    await clickRowAction(30);

    // This one takes the featured reply down with it and cannot be undone, so it warns
    // with the count it would drop (docs/04 §7).
    assert.dom(".remove-topic-modal").exists("the cascade warns first");
    assert
      .dom(".remove-topic__message")
      .hasText(i18n("collections.topic.confirm_uncollect", { name: "Quotes", count: 2 }));
    assert.deepEqual(requests.removed, [], "nothing is sent before the confirm");

    await click(".remove-topic__confirm");
    await settled();

    assert.deepEqual(requests.removed, ["30"], "deletes the membership");
    assert
      .dom('[data-collection-id="30"] .add-to-collection__count')
      .hasText("2", "the picker comes back showing what the list now reports");
    assert
      .dom(`${COLLECTED} ${CHIP}`)
      .exists({ count: 1 }, "the chip goes from the first post");
    assert
      .dom(FEATURED)
      .doesNotExist("the reply loses the collection featuring it");
  });

  test("un-collects a topic holding no selected replies without asking", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(1);

    await clickRowAction(12);

    assert
      .dom(".remove-topic-modal")
      .doesNotExist("nothing would be lost, so nothing to warn about");
    assert.deepEqual(requests.removed, ["12"], "deletes the membership");
    assert
      .dom('[data-collection-id="12"] .add-to-collection__action')
      .hasText(i18n("collections.topic.collect"), "the row flips in place");
  });

  test("features and unfeatures a reply", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(2);

    assert
      .dom('[data-collection-id="40"] .add-to-collection__hint')
      .hasText(i18n("collections.topic.feature_requires_topic"));
    assert
      .dom('[data-collection-id="40"] .add-to-collection__action')
      .isDisabled("a topic that is not collected cannot be featured");
    assert
      .dom('[data-collection-id="30"] .add-to-collection__action')
      .hasText(i18n("collections.topic.unfeature"));

    await clickRowAction(12);

    assert.deepEqual(
      requests.patched,
      [{ id: "12", mode: "add", postIds: [String(replyId())] }],
      "patches the reply into the collection"
    );
    assert
      .dom(`${FEATURED} ${CHIP}`)
      .exists({ count: 2 }, "the reply gains a chip without a refetch");

    await clickRowAction(30);

    // Featuring is reversible — the same row takes it back — so neither direction asks.
    assert.dom(".dialog-body").doesNotExist("no confirmation in either direction");
    assert.deepEqual(requests.patched[1], {
      id: "30",
      mode: "remove",
      postIds: [String(replyId())],
    });
    assert
      .dom(`${FEATURED} ${CHIP}`)
      .exists({ count: 1 }, "the reply loses the chip again");
  });

  test("opens a collection from its row", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(1);

    assert
      .dom('[data-collection-id="12"] .add-to-collection__name')
      .containsText("Riverside reads", "the row carries the name");
    assert
      .dom('[data-collection-id="12"] .add-to-collection__name a')
      .hasAttribute("href", "/collections/12", "linked to the collection");

    await click('[data-collection-id="12"] .add-to-collection__name a');
    await settled();

    assert.equal(currentURL(), "/collections/12", "the link opens the collection");
    assert
      .dom(".add-to-collection")
      .doesNotExist("and the picker goes away with the topic page");
  });

  test("creates a collection from the picker and comes back to it", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(1);

    await click(".add-to-collection__new");
    await settled();

    assert
      .dom(".collection-form")
      .exists("the create form takes the picker's place");
    assert
      .dom(".add-to-collection")
      .doesNotExist("the picker is replaced, not stacked on");

    await fillIn("#collection-form-name", "Reading list");
    await click(".collection-form__submit");
    await settled();

    assert.deepEqual(requests.created, ["Reading list"], "creates it");
    assert.dom(".add-to-collection").exists("the picker comes back");
    assert
      .dom(".add-to-collection__row")
      .exists({ count: 4 }, "the new collection is listed, and only once");
    assert
      .dom(".add-to-collection__row:first-child .add-to-collection__name")
      .hasText("Reading list", "it leads the list it would have sorted last in");
  });

  test("comes back to the picker when the form is dismissed", async function (assert) {
    await visit(TOPIC_URL);
    await settled();
    await openManager(1);

    await click(".add-to-collection__new");
    await settled();
    await click(".collection-form__cancel");
    await settled();

    assert.deepEqual(requests.created, [], "nothing is created");
    assert
      .dom(".add-to-collection__row")
      .exists({ count: 3 }, "the picker is back as it was");
  });
});

acceptance("Collections topic page — entry gates", function (needs) {
  // Staff so the whisper below renders at all, and so the post menu is fully built
  // for every post in the stream.
  needs.user({ admin: true, staff: true });
  needs.settings({
    collection_enabled: true,
    post_menu_hidden_items: "flag|bookmark|edit|delete|admin",
  });

  needs.pretender((server, helper) => {
    const whisperPayload = () => {
      const topic = topicPayload();
      // Post types are regular 1 / moderator action 2 / small action 3 / whisper 4.
      // The write endpoints only take regular posts, so no other type gets an entry.
      topic.post_stream.posts.find(
        (post) => post.post_number === 2
      ).post_type = 4;
      return helper.response(topic);
    };

    server.get("/t/280.json", whisperPayload);
    server.get("/t/280/:post_number.json", whisperPayload);

    const pmPayload = () =>
      helper.response(cloneJSON(topicFixtures["/t/130.json"]));

    server.get("/t/130.json", pmPayload);
    server.get("/t/130/:post_number.json", pmPayload);
  });

  test("hides the entry on a non-regular post", async function (assert) {
    await visit(TOPIC_URL);
    await settled();

    assert.dom(`#post_2 .post-controls`).hasClass("collapsed");

    await click(`#post_2 ${SHOW_MORE}`);

    assert
      .dom(`#post_2 .post-controls`)
      .hasClass("expanded", "the action bar really did expand");
    assert
      .dom(`#post_2 ${MENU_BUTTON}`)
      .doesNotExist("a whisper is never offered for featuring");

    await click(`#post_1 ${SHOW_MORE}`);

    assert.dom(`#post_1 ${MENU_BUTTON}`).exists("a regular post still gets it");
  });

  test("hides the entry on a private message", async function (assert) {
    await visit("/t/130");
    await settled();

    assert.dom("#post_1 .post__menu-area").exists("the post menu renders");
    assert
      .dom(`#post_1 ${MENU_BUTTON}`)
      .doesNotExist("a private message is not offered before expanding");

    await click(`#post_1 ${SHOW_MORE}`);

    assert
      .dom(`#post_1 ${MENU_BUTTON}`)
      .doesNotExist("and not after expanding either");
  });
});

acceptance("Collections topic page — guests", function (needs) {
  needs.settings({
    collection_enabled: true,
    collection_allow_anonymous: false,
  });

  needs.pretender((server, helper) => {
    const payload = () => helper.response(topicPayload());

    server.get("/t/280.json", payload);
    server.get("/t/280/:post_number.json", payload);
  });

  test("injects nothing for a guest", async function (assert) {
    await visit(TOPIC_URL);
    await settled();

    assert.dom(".collection-topic-chips").doesNotExist();
    assert
      .dom(MENU_BUTTON)
      .doesNotExist("and no action bar entry either");
  });
});
