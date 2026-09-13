import { click, settled, visit } from "@ember/test-helpers";
import { test } from "qunit";
import selectKit from "discourse/tests/helpers/select-kit-helper";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { i18n } from "discourse-i18n";

// needs.user() makes the viewer eviltrout / id 19.
const VIEWER = { id: 19, username: "eviltrout", name: "Robin Ward" };
const ANA = { id: 20, username: "ana", name: "Ana", avatar_template: "/a/{size}.png" };
const RIVER = { id: 2, username: "river", name: "River", avatar_template: "/r/{size}.png" };

const DIALOG = ".dialog-body";

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

// A record row as the owner's side reads it (docs/05 §2.3): the full invite, the
// invitee included — unlike the inbox shape, which is always "mine".
function recordRow(id, overrides = {}) {
  return {
    id,
    action_type: 0,
    status: "pending",
    inviter: VIEWER,
    invitee: ANA,
    collection: { id: 12, name: "Collection 12" },
    created_at: "2026-02-01T01:00:00.000Z",
    expires_at: "2026-02-11T01:00:00.000Z",
    ...overrides,
  };
}

function recordsResponse(rows) {
  return {
    invites: rows,
    meta: { page: 0, page_size: 30, more: false, total: rows.length },
  };
}

acceptance("Collections invite records — owner", function (needs) {
  const requests = { revoked: [], sent: [] };
  let rows = [];

  needs.hooks.beforeEach(() => {
    requests.revoked = [];
    requests.sent = [];
    rows = [
      recordRow(7),
      // Someone else started this transfer, so the viewer may not revoke it.
      recordRow(8, { action_type: 1, inviter: RIVER }),
      // A staff takeover is recorded with the same user on both sides (docs/05 §2.7).
      recordRow(9, { action_type: 1, status: "accepted", inviter: ANA, invitee: ANA }),
    ];
  });

  needs.user();
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    server.get("/collections/12.json", () => helper.response(fullShape(12)));
    server.get("/collections/12/topics.json", () => helper.response(EMPTY_FEED));
    server.get("/collections/12/invites.json", () =>
      helper.response(recordsResponse(rows))
    );
    server.delete("/collections/12/invites/:invite_id.json", (request) => {
      requests.revoked.push(request.params.invite_id);
      return helper.response({ success: "OK" });
    });
    server.post("/collections/12/invites.json", (request) => {
      const body = new URLSearchParams(request.requestBody);
      requests.sent.push({
        userId: body.get("user_id"),
        actionType: body.get("action_type"),
      });
      const created = recordRow(21, { invitee: RIVER });
      // The record reads newest first (docs/05 §2.3), so a just-sent invitation leads it —
      // which is also what puts it inside the page's preview.
      rows = [created, ...rows];
      return helper.response(201, created);
    });
    server.get("/u/search/users", () => helper.response({ users: [RIVER] }));
  });

  test("lists the invitations and where each one stands", async function (assert) {
    await visit("/collections/12");
    await settled();

    assert.dom(".collection-invite-record").exists({ count: 3 });

    assert
      .dom("[data-invite-id='7'] .collection-invite-record__inviter")
      .hasText("eviltrout", "the record names who issued the invitation");
    assert
      .dom("[data-invite-id='7'] .collection-invite-record__invitee")
      .hasText("ana", "and who it was issued to");
    assert
      .dom("[data-invite-id='7'] .collection-invite-record__inviter img")
      .exists("both parties read by face");
    assert
      .dom("[data-invite-id='7'] .collection-invite-record__inviter a")
      .exists({ count: 1 }, "each party's face and name are one link, not two");
    assert
      .dom("[data-invite-id='7'] .collection-invite-record__role")
      .hasText(
        i18n("collections.invite_records.to_be", {
          role: i18n("collections.invites.role_name.maintainer"),
        })
      );
    assert
      .dom("[data-invite-id='7'] .collection-invite-status")
      .hasText(i18n("collections.invites.status.pending"));
    assert
      .dom("[data-invite-id='8'] .collection-invite-record__role")
      .hasText(
        i18n("collections.invite_records.to_be", {
          role: i18n("collections.invites.role_name.owner"),
        })
      );
    assert
      .dom("[data-invite-id='9'] .collection-invite-record__inviter")
      .hasText(
        "ana",
        "a staff takeover names the same user on both sides (docs/05 §2.7)"
      );
    assert
      .dom("[data-invite-id='9'] .collection-invite-record__invitee")
      .hasText("ana");
    assert
      .dom(".collection-invite-records__more")
      .doesNotExist("a record short enough to read whole asks for no window");
  });

  test("offers revoking only on a pending invitation the viewer issued", async function (assert) {
    await visit("/collections/12");
    await settled();

    assert
      .dom("[data-invite-id='7'] .collection-invite-record__revoke")
      .exists("the viewer issued this one and it is still pending");
    assert
      .dom("[data-invite-id='8'] .collection-invite-record__revoke")
      .doesNotExist("someone else issued this one");
    assert
      .dom("[data-invite-id='9'] .collection-invite-record__revoke")
      .doesNotExist("an accepted invitation cannot be revoked");
  });

  test("revoking confirms, deletes the invitation and drops its row", async function (assert) {
    await visit("/collections/12");
    await settled();

    await click("[data-invite-id='7'] .collection-invite-record__revoke");
    assert
      .dom(DIALOG)
      .hasText(
        i18n("collections.invite_records.confirm_revoke", { username: "ana" })
      );
    assert.strictEqual(
      requests.revoked.length,
      0,
      "nothing is deleted before the confirmation"
    );

    await click(".dialog-footer .btn-danger");
    await settled();

    assert.deepEqual(requests.revoked, ["7"]);
    assert
      .dom("[data-invite-id='7']")
      .doesNotExist("a revoked invitation leaves the record");
    assert.dom(".collection-invite-record").exists({ count: 2 });
  });

  test("records an invitation as soon as it is sent", async function (assert) {
    rows = [];
    await visit("/collections/12");
    await settled();

    assert
      .dom(".collection-detail__invites")
      .doesNotExist("there is nothing to record yet");

    await click(".collection-detail__invite-maintainer");
    const chooser = selectKit(".collection-invite .user-chooser");
    await chooser.expand();
    await chooser.fillInFilter("river");
    await chooser.selectRowByValue("river");
    await click(".collection-invite__submit");
    await settled();

    assert.deepEqual(requests.sent, [{ userId: "2", actionType: "0" }]);
    assert
      .dom(".collection-invite-record[data-invite-id='21']")
      .exists("the record shows the invitation the viewer just sent");
    assert
      .dom(".collection-invite-records__more")
      .exists("and now hands the tail of the record to a window");
  });
});

acceptance("Collections invite records — previewed", function (needs) {
  let rows = [];

  needs.hooks.beforeEach(() => {
    rows = Array.from({ length: 5 }, (_, index) => recordRow(100 + index));
  });

  needs.user();
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    server.get("/collections/15.json", () => helper.response(fullShape(15)));
    server.get("/collections/15/topics.json", () => helper.response(EMPTY_FEED));
    server.get("/collections/15/invites.json", () =>
      helper.response(recordsResponse(rows))
    );
  });

  test("previews the newest rows and opens the whole record in a window", async function (assert) {
    await visit("/collections/15");
    await settled();

    assert
      .dom(".collection-detail__invites .collection-invite-record")
      .exists({ count: 3 }, "the page carries a preview, not the whole record");
    assert
      .dom(".collection-detail__invites [data-invite-id='100']")
      .exists("the preview starts at the most recent invitation");
    assert
      .dom(".collection-detail__invites [data-invite-id='103']")
      .doesNotExist("and stops before the fourth");

    await click(".collection-invite-records__more");

    assert
      .dom(".d-modal .collection-invite-record")
      .exists({ count: 5 }, "the window carries every invitation of the record");
  });
});

acceptance("Collections invite records — plain reader", function (needs) {
  let requested = 0;

  needs.hooks.beforeEach(() => {
    requested = 0;
  });

  needs.user();
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    server.get("/collections/13.json", () =>
      helper.response(fullShape(13, { owner: ANA }))
    );
    server.get("/collections/13/topics.json", () => helper.response(EMPTY_FEED));
    server.get("/collections/13/invites.json", () => {
      requested++;
      return helper.response(recordsResponse([recordRow(7)]));
    });
  });

  test("sees no record and never asks for one", async function (assert) {
    await visit("/collections/13");
    await settled();

    assert.dom(".collection-detail__invites").doesNotExist();
    assert.strictEqual(
      requested,
      0,
      "the record is only read by the owner and staff managers"
    );
  });
});

acceptance("Collections invite records — staff", function (needs) {
  needs.user({ admin: true });
  needs.settings({ collection_enabled: true });
  needs.pretender((server, helper) => {
    server.get("/collections/14.json", () =>
      helper.response(fullShape(14, { owner: ANA }))
    );
    server.get("/collections/14/topics.json", () => helper.response(EMPTY_FEED));
    // The viewer holds no team role on this collection, but a staff manager may call
    // off anyone's live pending invitation (docs/05 §2.2) — which is what these rows are.
    server.get("/collections/14/invites.json", () =>
      helper.response(
        recordsResponse([
          recordRow(7, { inviter: ANA }),
          recordRow(8, { action_type: 1, inviter: ANA }),
          recordRow(9, { status: "accepted", inviter: ANA }),
        ])
      )
    );
  });

  test("reads the record of someone else's collection without holding the team", async function (assert) {
    await visit("/collections/14");
    await settled();

    assert.dom(".collection-invite-record").exists({ count: 3 });
    assert
      .dom("[data-invite-id='7'] .collection-invite-record__revoke")
      .exists("a staff manager may call off someone else's co-maintainer invitation");
    assert
      .dom("[data-invite-id='8'] .collection-invite-record__revoke")
      .exists("and someone else's ownership invitation, whatever the type");
    assert
      .dom("[data-invite-id='9'] .collection-invite-record__revoke")
      .doesNotExist("an answered invitation still cannot be revoked");
  });
});

acceptance("Collections invite records — moderator with management on", function (needs) {
  needs.user({ moderator: true });
  needs.settings({
    collection_enabled: true,
    collection_moderators_can_manage_collections: true,
  });
  needs.pretender((server, helper) => {
    server.get("/collections/16.json", () =>
      helper.response(fullShape(16, { owner: ANA }))
    );
    server.get("/collections/16/topics.json", () => helper.response(EMPTY_FEED));
    server.get("/collections/16/invites.json", () =>
      helper.response(recordsResponse([recordRow(7, { inviter: ANA })]))
    );
  });

  test("holds the same management role over invitations as an admin", async function (assert) {
    await visit("/collections/16");
    await settled();

    assert.dom(".collection-invite-record").exists({ count: 1 });
    assert
      .dom("[data-invite-id='7'] .collection-invite-record__revoke")
      .exists("the site setting is what hands the moderator this power");
  });
});
