import { click, currentURL, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { longDate } from "discourse/lib/formatter";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

// needs.user() makes the viewer eviltrout / id 19.
const ANA = { id: 20, username: "ana", name: "Ana", avatar_template: "/a/{size}.png" };
const RIVER = { id: 2, username: "river", name: "River", avatar_template: "/r/{size}.png" };

// A pending invitation only is one while its window is open, so the fixture expires
// ahead of the run — the one place a date lies in the future, and the reason the
// expiry cannot go through the relative formatter (see the assertion below).
const EXPIRES_AT = new Date(Date.now() + 10 * 24 * 3600 * 1000).toISOString();

const DIALOG = ".dialog-body";
const DIALOG_CONFIRM = ".dialog-footer .btn-primary";
const DIALOG_CANCEL = ".dialog-footer .btn-default";

// One inbox row (docs/05 §2.4). The invitee's shape carries no invitee field —
// every row is "mine" — and a transfer carries the sitting owner so the invitee can
// judge it without opening the collection.
function invite(id, overrides = {}) {
  return {
    id,
    action_type: 0,
    status: "pending",
    inviter: ANA,
    collection: { id: 12, name: `Collection ${id}`, owner: ANA },
    created_at: "2026-02-01T01:00:00.000Z",
    expires_at: EXPIRES_AT,
    ...overrides,
  };
}

acceptance("Collections invites inbox", function (needs) {
  const requests = { accepted: [], rejected: [] };

  needs.hooks.beforeEach(() => {
    requests.accepted = [];
    requests.rejected = [];
  });

  needs.user({ can_create_collection: true });
  needs.settings({
    collection_enabled: true,
    // Read by the create form the inbox's own button opens.
    collection_name_min_length: 3,
    collection_name_max_length: 20,
    collection_description_max_length: 200,
  });
  needs.pretender((server, helper) => {
    server.get("/collections.json", () =>
      helper.response({
        collections: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
    server.get("/collections/invites.json", () =>
      helper.response({
        invites: [
          invite(1),
          invite(2, {
            action_type: 1,
            collection: { id: 13, name: "Collection 13", owner: RIVER },
          }),
          invite(3, { status: "expired" }),
          invite(4, { status: "accepted" }),
          invite(5, { status: "rejected" }),
          // The inviter's account is gone, which leaves the row without a name to lead
          // the sentence.
          invite(6, { inviter: null }),
        ],
        meta: { page: 0, page_size: 30, more: false, total: 6 },
      })
    );
    server.post("/collections/invites/1/accept.json", () => {
      requests.accepted.push(1);
      return helper.response({ id: 12, name: "Collection 1" });
    });
    server.post("/collections/invites/2/accept.json", () => {
      requests.accepted.push(2);
      return helper.response({ id: 13, name: "Collection 13" });
    });
    server.post("/collections/invites/1/reject.json", () => {
      requests.rejected.push(1);
      return helper.response({ success: "OK" });
    });
  });

  test("lists every invitation with what it asks and where it stands", async function (assert) {
    await visit("/collections/invites");
    await settled();

    assert.strictEqual(
      document.title,
      [
        i18n("collections.nav_name"),
        i18n("collections.tabs.invites"),
        this.siteSettings.title,
      ].join(" - "),
      "the inbox is told apart from the other lists"
    );
    assert.dom(".collection-invite-card").exists({ count: 6 });

    assert
      .dom("[data-invite-id='1'] .collection-invite-card__inviter")
      .hasText("ana", "the row names who is asking");
    assert
      .dom("[data-invite-id='1'] .collection-invite-card__inviter img")
      .exists("the inviter is shown by face, not name alone");
    assert
      .dom("[data-invite-id='1'] .collection-invite-card__inviter a")
      .exists({ count: 1 }, "that face and name are one link, not two");
    assert
      .dom("[data-invite-id='1'] .collection-invite-card__ask")
      .hasText(
        i18n("collections.invites.invited_you", {
          role: i18n("collections.invites.role_name.maintainer"),
        })
      );
    assert
      .dom("[data-invite-id='6'] .collection-invite-card__inviter")
      .hasText(
        i18n("collections.invites.unknown_user"),
        "a deleted inviter still leaves a readable sentence"
      );
    assert
      .dom("[data-invite-id='6'] .collection-invite-card__inviter img")
      .doesNotExist("a deleted account has no face to show");
    assert
      .dom("[data-invite-id='1'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.pending"));
    assert
      .dom("[data-invite-id='1'] .collection-invite-card__expiry")
      .hasText(
        `${i18n("collections.invites.expires")} ${longDate(new Date(EXPIRES_AT))}`,
        "a pending window closes on a date; relative ages would call it 'now'"
      );

    assert
      .dom("[data-invite-id='2'] .collection-invite-card__ask")
      .hasText(
        i18n("collections.invites.invited_you", {
          role: i18n("collections.invites.role_name.owner"),
        })
      );
    assert
      .dom("[data-invite-id='2'] .collection-invite-card__owner")
      .hasText(i18n("collections.invites.current_owner", { username: "river" }));

    assert
      .dom("[data-invite-id='3'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.expired"));
    assert
      .dom("[data-invite-id='4'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.accepted"));
    assert
      .dom("[data-invite-id='5'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.rejected"));

    assert
      .dom("[data-invite-id='1'] .collection-invite-card__accept")
      .exists("a pending invitation can still be answered");
    assert
      .dom("[data-invite-id='3'] .collection-invite-card__accept")
      .doesNotExist("an expired invitation cannot be answered any more");
    assert
      .dom("[data-invite-id='4'] .collection-invite-card__accept")
      .doesNotExist("an answered invitation is history");
  });

  test("the invites tab leads to the inbox", async function (assert) {
    await visit("/collections");
    await click('[data-link-name="collections-invites"]');
    await settled();

    assert.strictEqual(currentURL(), "/collections/invites");
  });

  test("offers the create form from the inbox as well", async function (assert) {
    await visit("/collections/invites");

    assert.dom(".collection-list__new-button").exists();
    await click(".collection-list__new-button");

    assert.dom("#collection-form-name").exists("the inbox is not a dead end");
  });

  test("accepting a co-maintainer invitation asks first, then records it", async function (assert) {
    await visit("/collections/invites");
    await settled();

    await click("[data-invite-id='1'] .collection-invite-card__accept");
    assert
      .dom(DIALOG)
      .hasText(
        i18n("collections.invites.confirm_accept_maintainer", {
          name: "Collection 1",
        })
      );
    assert.strictEqual(
      requests.accepted.length,
      0,
      "nothing is written before the confirmation"
    );

    await click(DIALOG_CONFIRM);
    await settled();

    assert.deepEqual(requests.accepted, [1]);
    assert
      .dom("[data-invite-id='1'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.accepted"));
    assert
      .dom("[data-invite-id='1'] .collection-invite-card__accept")
      .doesNotExist("an answered invitation offers no second answer");
  });

  test("accepting a transfer names what it changes", async function (assert) {
    await visit("/collections/invites");
    await settled();

    await click("[data-invite-id='2'] .collection-invite-card__accept");
    assert
      .dom(DIALOG)
      .hasText(
        i18n("collections.invites.confirm_accept_owner", { name: "Collection 13" })
      );

    await click(DIALOG_CANCEL);
    await settled();

    assert.deepEqual(
      requests.accepted,
      [],
      "cancelling the confirmation writes nothing"
    );
    assert
      .dom("[data-invite-id='2'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.pending"));
  });

  test("declining an invitation confirms and records the decline", async function (assert) {
    await visit("/collections/invites");
    await settled();

    await click("[data-invite-id='1'] .collection-invite-card__reject");
    assert
      .dom(DIALOG)
      .hasText(
        i18n("collections.invites.confirm_reject", { name: "Collection 1" })
      );
    assert
      .dom(".dialog-footer .btn-danger")
      .exists("declining is confirmed on a red button");

    await click(".dialog-footer .btn-danger");
    await settled();

    assert.deepEqual(requests.rejected, [1]);
    assert
      .dom("[data-invite-id='1'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.rejected"));
  });
});

acceptance("Collections invites inbox — empty", function (needs) {
  needs.user();
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    server.get("/collections/invites.json", () =>
      helper.response({
        invites: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
  });

  test("says so when nothing was ever received", async function (assert) {
    await visit("/collections/invites");
    await settled();

    assert
      .dom(".empty-state__title")
      .hasText(i18n("collections.invites.empty_title"));
    assert.dom(".collection-invite-card").doesNotExist();
  });
});

acceptance("Collections invites inbox — anonymous", function (needs) {
  needs.settings({
    collection_enabled: true,
    collection_allow_anonymous: true,
  });
  needs.pretender((server, helper) => {
    server.get("/collections.json", () =>
      helper.response({
        collections: [],
        meta: { page: 0, page_size: 30, more: false, total: 0 },
      })
    );
  });

  test("sends a guest to the public list", async function (assert) {
    await visit("/collections/invites");
    await settled();

    assert.strictEqual(
      currentURL(),
      "/collections",
      "the inbox is login-only, anonymous reading toggle or not"
    );
    assert.dom(".collection-invite-card").doesNotExist();
  });
});
