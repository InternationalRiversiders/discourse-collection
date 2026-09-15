import { click, currentURL, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import userFixtures from "discourse/tests/fixtures/user-fixtures";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

const CURRENT_USER = { id: 19, username: "eviltrout", name: "Robin Ward" };

function user(id, username) {
  return {
    id,
    username,
    name: username,
    avatar_template: "/images/avatar.png",
  };
}

// The feed's author source (the responses' top-level `users` map, docs/04 §1). Id
// 42 is the author of topic 101; every reply author is in here too. Topic 102's
// author is deliberately absent — a deleted account — so the row draws no author.
const USERS = {
  42: user(42, "river"),
  77: user(77, "ana"),
  78: user(78, "bob"),
  79: user(79, "chen"),
};

function fullShape(id, overrides = {}) {
  return {
    id,
    name: `Collection ${id}`,
    description: `Description ${id}`,
    topic_count: 0,
    owner: CURRENT_USER,
    teamworkers: [],
    subscriber_count: 1,
    is_subscribed: false,
    created_at: "2026-01-02T03:04:05.000Z",
    updated_at: "2026-01-02T03:04:05.000Z",
    last_topic_added_at: "2026-06-01T01:00:00.000Z",
    ...overrides,
  };
}

function reply(postNumber, userId) {
  return {
    post_id: 300 + postNumber,
    post_number: postNumber,
    user_id: userId,
    created_at: "2026-05-02T00:00:00.000Z",
    excerpt: `Reply ${postNumber} featured reply`,
  };
}

function topicRow(id, addedAt, { topic: topicOverrides, ...overrides } = {}) {
  return {
    added_at: addedAt,
    note: "",
    topic: {
      id,
      slug: `river-topic-${id}`,
      fancy_title: `Riverside topic ${id}`,
      category_id: 3,
      user_id: 42,
      excerpt: `Excerpt ${id}`,
      created_at: "2026-04-01T00:00:00.000Z",
      bumped_at: "2026-04-02T00:00:00.000Z",
      posts_count: 5,
      ...topicOverrides,
    },
    ...overrides,
  };
}

// Newest-added topic: card fields only, no selected replies key. Unlisted, so it
// carries the conditional key and the marker core draws for one.
const rowNew = topicRow(101, "2026-06-01T08:00:00.000Z", {
  note: "Editor's note",
  topic: { unlisted: true },
});

// Older topic: two inline selected replies plus an overflow beyond the window, so
// the row carries has_more_selected_replies=true and a "view all" entry. Its author
// (user_id 999) is not in USERS, standing in for a deleted account.
const inlineReplies = [reply(4, 77), reply(5, 78)];
const overflowReplies = [...inlineReplies, reply(6, 78), reply(7, 79)];
const rowOld = topicRow(102, "2026-05-10T08:00:00.000Z", {
  topic: { user_id: 999 },
  selected_replies: inlineReplies,
  has_more_selected_replies: true,
});

function readingFeed(order) {
  const rows = order === "asc" ? [rowOld, rowNew] : [rowNew, rowOld];
  return {
    topics: rows,
    users: USERS,
    meta: { page: 0, page_size: 30, more: false, total: rows.length },
  };
}

acceptance("Collections reading feed", function (needs) {
  const orders = [];
  needs.user();
  needs.pretender((server, helper) => {
    // Card behind every author link (core fetches this when one is clicked).
    server.get("/u/ana/card.json", () =>
      helper.response(cloneJSON(userFixtures["/u/charlie/card.json"]))
    );
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
    server.get("/collections/12/topics.json", (request) => {
      const order = request.queryParams.order || "desc";
      orders.push(order);
      return helper.response(readingFeed(order));
    });
    server.get("/collections/12/topics/102/selected_replies.json", () =>
      helper.response({
        selected_replies: overflowReplies,
        users: USERS,
        meta: { page: 0, page_size: 30, more: false, total: overflowReplies.length },
      })
    );
    server.get("/collections/13.json", () =>
      helper.response(fullShape(13, { name: "Empty reads", topic_count: 0 }))
    );
    server.get("/collections/13/topics.json", () =>
      helper.response({
        topics: [],
        users: {},
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    // A collected topic core later turned into a personal message: its category_id
    // is null (archetype private_message, TopicConverter), so the row has no
    // category to draw.
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { name: "Uncategorised reads", topic_count: 1 }))
    );
    server.get("/collections/14/topics.json", () =>
      helper.response({
        topics: [
          topicRow(103, "2026-06-02T08:00:00.000Z", { topic: { category_id: null } }),
        ],
        users: USERS,
        meta: { page: 0, page_size: 30, more: false, total: 1 },
      })
    );
    // Excerpts travel as plain text (docs/04 §1), emoji reduced to their shortcode by
    // the server's own excerpting — so the row is what puts the image back. Titles
    // arrive carrying a code too: core's fancy_title escapes the emoji, it does not
    // draw it.
    server.get("/collections/15.json", () =>
      helper.response(fullShape(15, { name: "Emoji reads", topic_count: 1 }))
    );
    server.get("/collections/15/topics.json", () =>
      helper.response({
        topics: [
          topicRow(104, "2026-06-03T08:00:00.000Z", {
            topic: { fancy_title: "Reads :smile:", excerpt: "Excerpt :smile:" },
            selected_replies: [{ ...reply(2, 77), excerpt: "Reply :smile:" }],
          }),
        ],
        users: USERS,
        meta: { page: 0, page_size: 30, more: false, total: 1 },
      })
    );
  });

  test("renders the reading feed under the detail header", async function (assert) {
    await visit("/collections/12");
    await settled();

    assert.dom(".collection-topics__heading").hasText(i18n("collections.reading.heading"));
    assert.dom(".collection-topic").exists({ count: 2 });
    assert.dom(".collection-topic__excerpt").containsText("Excerpt 101");
    assert.dom(".collection-topic__note").containsText("Editor's note");
    assert.dom(".collection-topic__reply-user").exists({ count: 2 }, "inline replies render");
    assert.dom(".collection-topic__view-all").exists("overflow entry shows for a flagged topic");
  });

  test("gives every row its author, its category and a clickable lead text", async function (assert) {
    await visit("/collections/12");
    await settled();

    const first = ".collection-topics__list .collection-topic:first-child";
    const last = ".collection-topics__list .collection-topic:last-child";

    assert
      .dom(`${first} .collection-topic__author .collection-user__username`)
      .hasText("river", "the topic author is named from the users map");
    assert.dom(`${first} .collection-topic__author img.avatar`).exists("with their avatar");
    assert
      .dom(`${last} .collection-topic__author`)
      .doesNotExist("an author missing from the users map draws nothing");

    assert
      .dom(`${first} .collection-topic__category .badge-category__name`)
      .hasText("meta", "the category badge is core's, built from category_id");

    const excerpt = document.querySelector(`${first} .collection-topic__excerpt`);
    assert.true(
      excerpt.getAttribute("href").endsWith("/t/river-topic-101/101"),
      "the excerpt is a second link into the topic"
    );
    assert.false(
      excerpt.getAttribute("href").includes("/p/"),
      "the excerpt does not detour through the post permalink route"
    );
  });

  test("draws no category for a topic that has no category_id", async function (assert) {
    await visit("/collections/14");
    await settled();

    const row = ".collection-topics__list .collection-topic:first-child";

    assert
      .dom(`${row} .collection-topic__title`)
      .containsText("Riverside topic 103", "the rest of the row still renders");
    assert
      .dom(`${row} .collection-topic__category`)
      .doesNotExist("a null category_id drops the whole category block");
  });

  test("marks an unlisted topic the way core does", async function (assert) {
    await visit("/collections/12");
    await settled();

    const first = ".collection-topics__list .collection-topic:first-child";
    const last = ".collection-topics__list .collection-topic:last-child";

    assert.dom(`${first} .topic-status.--invisible`).exists("the unlisted row is marked");
    assert
      .dom(`${first} .topic-status.--invisible use[href='#far-eye-slash']`)
      .exists("with core's own icon");
    assert.dom(`${first} .topic-status.--invisible`).hasAttribute("title");
    assert
      .dom(`${last} .topic-status.--invisible`)
      .doesNotExist("a public topic carries no marker");
  });

  test("links each reply straight to its post inside the topic", async function (assert) {
    await visit("/collections/12");
    await settled();

    const links = document.querySelectorAll(
      ".collection-topics__list .collection-topic:last-child .collection-topic__reply-link"
    );

    assert.strictEqual(links.length, 2);
    assert.true(
      links[0].getAttribute("href").endsWith("/t/river-topic-102/102/4"),
      "the link is topic + post number, not /p/:id"
    );
    assert
      .dom(".collection-topics__list .collection-topic:last-child .collection-topic__reply-user img.avatar")
      .exists({ count: 2 }, "reply authors get an avatar next to the name");
  });

  test("opens a reply author's card rather than the post behind it", async function (assert) {
    await visit("/collections/12");
    await settled();

    const author = document.querySelector(
      ".collection-topics__list .collection-topic:last-child .collection-topic__reply-user"
    );

    assert.true(
      author.matches("a[data-user-card]"),
      "the reply author is its own user-card anchor"
    );
    assert.true(
      author.getAttribute("href").endsWith("/u/ana"),
      "pointing at the author's profile"
    );
    assert.strictEqual(
      document.querySelector(
        ".collection-topic__reply-link .collection-topic__reply-user"
      ),
      null,
      "and sits outside the post link — nested, core's card handler never sees the click"
    );

    await click(author);
    await settled();

    assert.dom(".user-card .card-content").exists("the author link opens the card");
    assert.strictEqual(
      currentURL(),
      "/collections/12",
      "leaving the reading page alone"
    );
  });

  test("toggles the feed order between desc and asc", async function (assert) {
    await visit("/collections/12");
    await settled();
    const before = orders.length;

    assert
      .dom(".collection-topics__list .collection-topic:first-child")
      .containsText("Riverside topic 101");

    await click(".collection-topics__order-toggle");
    await settled();

    assert.strictEqual(orders.length, before + 1, "the toggle refetches page 0");
    assert.strictEqual(orders[orders.length - 1], "asc", "asc is requested after the toggle");
    assert
      .dom(".collection-topics__list .collection-topic:first-child")
      .containsText("Riverside topic 102");
  });

  test("opens the full selected-replies list for a topic that has more", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-topic__view-all");
    await settled();

    assert.dom(".topic-selected-replies__topic").hasText("Riverside topic 102");
    assert.dom(".topic-selected-replies__reply").exists({ count: overflowReplies.length });
    assert.dom(".topic-selected-replies__reply-user").containsText("bob", "overflow rows beyond the inline window load");

    const author = document.querySelector(
      ".topic-selected-replies__reply .topic-selected-replies__reply-user"
    );
    assert.true(
      author.matches("a[data-user-card]"),
      "overflow rows carry the same user-card anchor as the inline ones"
    );
    assert.strictEqual(
      document.querySelector(
        ".topic-selected-replies__reply-link .topic-selected-replies__reply-user"
      ),
      null,
      "and it is not nested inside the post link either"
    );
  });

  test("puts back the emoji a title and an excerpt carry", async function (assert) {
    await visit("/collections/15");
    await settled();

    assert
      .dom(".collection-topic__title img.emoji")
      .exists("the topic's title draws its emoji");
    assert
      .dom(".collection-topic__excerpt img.emoji")
      .exists("and so does its lead text");
    assert
      .dom(".collection-topic__reply-excerpt img.emoji")
      .exists("and a featured reply's");
  });

  test("shows the empty state when the collection has no topics", async function (assert) {
    await visit("/collections/13");
    await settled();

    assert.dom(".empty-state__title").hasText(i18n("collections.no_topics_yet"));
    assert.dom(".collection-topic").doesNotExist();
  });
});
