import { click, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import selectKit from "discourse/tests/helpers/select-kit-helper";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

// needs.user() makes the viewer eviltrout / id 19.
const VIEWER = { id: 19, username: "eviltrout", name: "Robin Ward" };
const RIVER = { id: 2, username: "river", name: "River" };
const OTHER_OWNER = { id: 20, username: "ana", name: "Ana" };

// That fixture user is admin, moderator and staff, so `needs.user()` alone hands a module
// the staff management role as well. The modules below mean a viewer who holds no such
// role, and say so; the ones about a staff reader keep the flags and say which.
const NON_STAFF = { admin: false, moderator: false, staff: false };

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

// The chooser looks the picked user up by search; id 43 is the one the stub rejects.
// The viewer is in the results too, so a test can prove they stay out of the picks
// that cannot mean them (or, for staff, that they can pick themselves).
const SEARCH_RESULTS = {
  users: [
    { id: 19, username: "eviltrout", name: "Robin Ward", avatar_template: "/e/{size}.png" },
    { id: 42, username: "ana", name: "Ana", avatar_template: "/a/{size}.png" },
    { id: 43, username: "blocked", name: "Blocked", avatar_template: "/b/{size}.png" },
  ],
};

acceptance("Collections team — owner", function (needs) {
  const requests = { invited: [], removed: [] };

  needs.hooks.beforeEach(() => {
    requests.invited = [];
    requests.removed = [];
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
      helper.response(fullShape(12, { teamworkers: [RIVER] }))
    );
    server.get("/collections/12/topics.json", () => helper.response(EMPTY_FEED));
    server.delete("/collections/12/teamworkers/2.json", () => {
      requests.removed.push(2);
      return helper.response(fullShape(12, { teamworkers: [] }));
    });
    server.post("/collections/12/invites.json", (request) => {
      const body = new URLSearchParams(request.requestBody);
      requests.invited.push({
        userId: body.get("user_id"),
        actionType: body.get("action_type"),
      });
      if (body.get("user_id") === "43") {
        return helper.response(422, {
          errors: ["That user is already a co-maintainer of this collection."],
        });
      }
      return helper.response(201, { id: 7 });
    });
    server.get("/u/search/users", () => helper.response(SEARCH_RESULTS));
  });

  test("shows the roster and both invitations to the owner", async function (assert) {
    await visit("/collections/12");
    await settled();

    assert
      .dom(".collection-detail__team-member")
      .exists({ count: 2 }, "the roster holds the owner and the co-maintainer");
    assert
      .dom(".collection-detail__team-member.-owner")
      .containsText("eviltrout");
    assert
      .dom(".collection-detail__team-member[data-username='river']")
      .containsText("river");
    assert.dom(".collection-detail__invite-maintainer").exists();
    assert.dom(".collection-detail__invite-owner").exists();
    assert
      .dom(".collection-detail__team-member[data-username='river'] .collection-detail__team-action")
      .hasText(i18n("collections.team.remove"));
  });

  test("removes a co-maintainer after confirming", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(
      ".collection-detail__team-member[data-username='river'] .collection-detail__team-action"
    );
    assert.dom(DIALOG).exists("removal asks first");
    assert.strictEqual(requests.removed.length, 0, "nothing is sent before the confirm");

    await click(DIALOG_CONFIRM);
    await settled();

    assert.deepEqual(requests.removed, [2]);
    assert
      .dom(".collection-detail__team-member[data-username='river']")
      .doesNotExist("the removed co-maintainer leaves the roster");
    assert
      .dom(".collection-detail__team-member.-owner")
      .exists("the owner stays");
  });

  test("keeps the co-maintainer when the removal confirm is dismissed", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(
      ".collection-detail__team-member[data-username='river'] .collection-detail__team-action"
    );
    await click(".dialog-footer .btn-default");
    await settled();

    assert.strictEqual(requests.removed.length, 0);
    assert
      .dom(".collection-detail__team-member[data-username='river']")
      .exists();
  });

  test("invites the picked user as a co-maintainer", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__invite-maintainer");
    assert
      .dom(".collection-invite__description")
      .hasText(i18n("collections.invite.maintainer.description"));

    await selectInvitee(assert, "ana", "ana");
    await click(".collection-invite__submit");
    await settled();

    assert.deepEqual(requests.invited, [{ userId: "42", actionType: "0" }]);
    assert
      .dom(".collection-invite__sent")
      .hasText(i18n("collections.invite.maintainer.sent", { username: "ana" }));
  });

  test("invites the picked user to take over the collection", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__invite-owner");
    await selectInvitee(assert, "ana", "ana");
    await click(".collection-invite__submit");
    await settled();

    assert.deepEqual(requests.invited, [{ userId: "42", actionType: "1" }]);
  });

  test("keeps the owner out of their own ownership picker", async function (assert) {
    await visit("/collections/12");
    await settled();
    await click(".collection-detail__invite-owner");

    const chooser = selectKit(".collection-invite .user-chooser");
    await chooser.expand();
    await chooser.fillInFilter("eviltrout");
    await settled();

    assert
      .dom(".collection-invite .select-kit-row[data-value='eviltrout']")
      .doesNotExist("an owner cannot transfer a collection to themselves");
  });

  test("shows a refused invitation next to the field and stays open", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__invite-maintainer");
    await selectInvitee(assert, "block", "blocked");
    await click(".collection-invite__submit");
    await settled();

    assert.deepEqual(requests.invited, [{ userId: "43", actionType: "0" }]);
    assert
      .dom(".collection-invite__error")
      .includesText("already a co-maintainer");
    assert
      .dom(".collection-invite__sent")
      .doesNotExist("a refused invitation is not reported as sent");
    assert
      .dom(".collection-invite__submit")
      .exists("the inviter can pick someone else");
  });

  test("cannot invite without picking a user", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click(".collection-detail__invite-maintainer");
    assert.dom(".collection-invite__submit").isDisabled();

    await click(".collection-invite__cancel");
    assert.strictEqual(requests.invited.length, 0);
  });
});

acceptance("Collections team — co-maintainer", function (needs) {
  const requests = { removed: [] };

  needs.hooks.beforeEach(() => {
    requests.removed = [];
  });

  needs.user(NON_STAFF);
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
    server.get("/collections/13.json", () =>
      helper.response(
        fullShape(13, { owner: OTHER_OWNER, teamworkers: [VIEWER, RIVER] })
      )
    );
    server.get("/collections/13/topics.json", () => helper.response(EMPTY_FEED));
    server.delete("/collections/13/teamworkers/19.json", () => {
      requests.removed.push(19);
      return helper.response(
        fullShape(13, { owner: OTHER_OWNER, teamworkers: [RIVER] })
      );
    });
  });

  test("offers leaving on the viewer's own row only", async function (assert) {
    await visit("/collections/13");
    await settled();

    assert
      .dom(".collection-detail__team-member[data-username='eviltrout'] .collection-detail__team-action")
      .hasText(i18n("collections.team.leave"));
    assert
      .dom(".collection-detail__team-member[data-username='river'] .collection-detail__team-action")
      .doesNotExist("a co-maintainer cannot remove the others");
    assert
      .dom(".collection-detail__invite-maintainer")
      .doesNotExist("inviting is the owner's");
    assert.dom(".collection-detail__invite-owner").doesNotExist();
  });

  test("leaves after confirming and loses the role chip", async function (assert) {
    await visit("/collections/13");
    await settled();

    assert
      .dom(".collection-detail__role")
      .hasText(i18n("collections.teamworker_badge"));

    await click(
      ".collection-detail__team-member[data-username='eviltrout'] .collection-detail__team-action"
    );
    await click(DIALOG_CONFIRM);
    await settled();

    assert.deepEqual(requests.removed, [19]);
    assert
      .dom(".collection-detail__team-member[data-username='eviltrout']")
      .doesNotExist();
    assert.dom(".collection-detail__role").doesNotExist();
  });
});

acceptance("Collections team — plain reader", function (needs) {
  needs.user(NON_STAFF);
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
      helper.response(fullShape(14, { owner: OTHER_OWNER, teamworkers: [RIVER] }))
    );
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("sees the roster but no entry to change it", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-detail__team-member").exists({ count: 2 });
    assert.dom(".collection-detail__team-action").doesNotExist();
    assert.dom(".collection-detail__invite-maintainer").doesNotExist();
    assert.dom(".collection-detail__invite-owner").doesNotExist();
  });
});

acceptance("Collections team — staff", function (needs) {
  const requests = { invited: [] };

  needs.hooks.beforeEach(() => {
    requests.invited = [];
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
      helper.response(
        fullShape(14, {
          owner: OTHER_OWNER,
          teamworkers: [RIVER],
          // Only the detail read carries these (docs/03 §1 / docs/03 §4): the page shows
          // the sitting owner's other collections until a takeover renames the heading.
          owner_collections: [{ id: 21, name: "Ana's other" }],
        })
      )
    );
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
    server.get("/collections/15.json", () =>
      helper.response(fullShape(15, { owner: null }))
    );
    server.get("/collections/15/topics.json", () => helper.response(EMPTY_FEED));
    // Picking themselves on someone else's collection (docs/05 §2.7): the server
    // answers 200 with the invite it already accepted and the collection it changed,
    // rather than parking a pending invite.
    server.post("/collections/14/invites.json", (request) => {
      const body = new URLSearchParams(request.requestBody);
      requests.invited.push({
        userId: body.get("user_id"),
        actionType: body.get("action_type"),
      });
      return helper.response(200, {
        invite: {
          id: 9,
          action_type: 1,
          status: "accepted",
          inviter: VIEWER,
          invitee: VIEWER,
          collection: { id: 14, name: "Collection 14" },
          created_at: "2026-01-02T03:04:05.000Z",
          expires_at: "2026-01-12T03:04:05.000Z",
        },
        // The landing shape (docs/05 §2.7): the viewer owns it, the demoted owner stays
        // on as a co-maintainer, the viewer's auto-subscription never counts while the
        // demoted owner's own row starts to (docs/08 §1).
        collection: fullShape(14, {
          owner: VIEWER,
          teamworkers: [OTHER_OWNER, RIVER],
          is_subscribed: true,
          subscriber_count: 6,
        }),
      });
    });
    server.get("/u/search/users", () =>
      helper.response({
        users: [
          { id: 19, username: "eviltrout", name: "Robin Ward", avatar_template: "/e/{size}.png" },
          { id: 20, username: "ana", name: "Ana", avatar_template: "/a/{size}.png" },
          { id: 2, username: "river", name: "River", avatar_template: "/r/{size}.png" },
        ],
      })
    );
  });

  test("offers a co-maintainer as the next owner", async function (assert) {
    await visit("/collections/14");
    await settled();
    await click(".collection-detail__invite-owner");

    const chooser = selectKit(".collection-invite .user-chooser");
    await chooser.expand();
    await chooser.fillInFilter("river");
    await settled();

    assert
      .dom(".collection-invite .select-kit-row[data-value='river']")
      .exists("promoting a co-maintainer is the usual way to hand a collection over");
  });

  test("leaves the sitting owner out of the ownership picker", async function (assert) {
    await visit("/collections/14");
    await settled();
    await click(".collection-detail__invite-owner");

    const chooser = selectKit(".collection-invite .user-chooser");
    await chooser.expand();
    await chooser.fillInFilter("ana");
    await settled();

    assert.true(chooser.isExpanded(), "the picker is open on the filtered term");
    assert.strictEqual(chooser.filter().value(), "ana");
    assert
      .dom(".collection-invite .select-kit-row[data-value='ana']")
      .doesNotExist("the owner cannot take over from themselves");
  });

  test("may start an ownership invite but not maintain the team", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-detail__invite-owner").exists();
    assert
      .dom(".collection-detail__invite-maintainer")
      .doesNotExist("adding a co-maintainer stays with the owner");
    assert
      .dom(".collection-detail__team-action")
      .doesNotExist("staff have no bypass on the team");
  });

  test("takes the collection over when they pick themselves", async function (assert) {
    await visit("/collections/14");
    await settled();
    assert
      .dom(".collection-detail__owner-collections")
      .containsText("Ana's other", "the page starts on the sitting owner's other collections");
    await click(".collection-detail__invite-owner");

    await selectInvitee(assert, "evil", "eviltrout");
    await click(".collection-invite__submit");
    await settled();

    assert.deepEqual(requests.invited, [{ userId: "19", actionType: "1" }]);
    assert
      .dom(".collection-invite__taken-over")
      .hasText(i18n("collections.invite.owner.taken_over"));
    assert
      .dom(".collection-invite__sent")
      .doesNotExist("a takeover is not an invitation waiting on someone");

    // The page behind the modal is updated from the same response: the new owner, the
    // role chip and every owner-only entry the viewer just gained.
    assert
      .dom(".collection-detail__team-member.-owner")
      .containsText("eviltrout");
    assert
      .dom(".collection-detail__team-member[data-username='ana']")
      .exists("the previous owner stays on as a co-maintainer");
    assert
      .dom(".collection-detail__role")
      .hasText(i18n("collections.owner_badge"));
    assert.dom(".collection-detail__delete").exists();
    assert.dom(".collection-detail__invite-maintainer").exists();

    // The subscription came with the role, and the count is the one the server recomputed.
    assert
      .dom(".collection-detail__subscribe")
      .containsText(i18n("collections.detail.unsubscribe"), "the new owner is subscribed");
    assert
      .dom(".collection-detail__stat:nth-child(2) dd")
      .hasText("6", "the count follows the response");
    // The list belonged to the previous owner, so it leaves with the role.
    assert
      .dom(".collection-detail__owner-collections")
      .doesNotExist("the previous owner's other collections go with the role");
  });

  test("may designate a first owner for an unclaimed collection", async function (assert) {
    await visit("/collections/15");
    await settled();

    assert.dom(".collection-detail__team").doesNotExist("nobody is on the team");
    assert.dom(".collection-detail__invite-owner").exists();
    assert.dom(".collection-detail__invite-maintainer").doesNotExist();
  });
});

acceptance("Collections team — guest", function (needs) {
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
    server.get("/collections/16.json", () =>
      helper.response(fullShape(16, { owner: OTHER_OWNER, teamworkers: [RIVER] }))
    );
    server.get("/collections/16/topics.json", () => helper.response(EMPTY_FEED));
  });

  test("reads the roster with nothing to act on", async function (assert) {
    await visit("/collections/16");
    await settled();

    assert.dom(".collection-detail__team-member").exists({ count: 2 });
    assert.dom(".collection-detail__team-action").doesNotExist();
    assert.dom(".collection-detail__invite-maintainer").doesNotExist();
    assert.dom(".collection-detail__invite-owner").doesNotExist();
  });
});

// Drives the user chooser the way a person does: open it, type enough to see the
// user, click the row.
async function selectInvitee(assert, term, username) {
  const chooser = selectKit(".collection-invite .user-chooser");
  await chooser.expand();
  await chooser.fillInFilter(term);
  await settled();

  assert
    .dom(`.collection-invite .select-kit-row[data-value='${username}']`)
    .exists("the search found the user to invite");

  await chooser.selectRowByValue(username);
}
