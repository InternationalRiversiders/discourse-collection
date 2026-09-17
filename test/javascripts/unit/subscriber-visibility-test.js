import { module, test } from "qunit";
import { canViewSubscriberList } from "discourse/plugins/discourse-collection/discourse/lib/subscriber-visibility";

// The three viewers the rule tells apart, in the shape the page hands it: a core User model
// carries `admin`, and `staff` which is admin-or-moderator.
const ADMIN = { admin: true, staff: true };
const MODERATOR = { admin: false, staff: true };
const MEMBER = { admin: false, staff: false };

const LEVELS = ["admin", "staff", "staff_owner", "staff_owner_teamworker", "logged_in"];

function canViewSubscribers({ setting, user = MEMBER, isOwner = false, isTeamworker = false }) {
  return canViewSubscriberList({ setting, user, isOwner, isTeamworker });
}

module("Unit | Lib | subscriber-visibility", function () {
  test("turns away a visitor who is not signed in, whatever the setting says", function (assert) {
    [...LEVELS, undefined].forEach((setting) => {
      assert.false(
        canViewSubscribers({ setting, user: null, isOwner: true, isTeamworker: true }),
        `${setting} admits nobody anonymous`
      );
    });
  });

  test("logged_in — the default — admits any signed-in user", function (assert) {
    assert.true(canViewSubscribers({ setting: "logged_in" }), "the level itself");
    assert.true(canViewSubscribers({ setting: undefined }), "and a setting the client lacks");
  });

  test("admin admits admins only", function (assert) {
    assert.true(canViewSubscribers({ setting: "admin", user: ADMIN }));
    assert.false(canViewSubscribers({ setting: "admin", user: MODERATOR }));
    assert.false(
      canViewSubscribers({ setting: "admin", user: MEMBER, isOwner: true, isTeamworker: true }),
      "the collection's own team is not staff"
    );
  });

  test("staff adds moderators, whatever the collection's roles are", function (assert) {
    assert.true(canViewSubscribers({ setting: "staff", user: ADMIN }));
    assert.true(canViewSubscribers({ setting: "staff", user: MODERATOR }));
    assert.false(
      canViewSubscribers({ setting: "staff", user: MEMBER, isOwner: true, isTeamworker: true })
    );
  });

  test("staff_owner adds this collection's owner, but not its co-maintainers", function (assert) {
    assert.true(canViewSubscribers({ setting: "staff_owner", user: MEMBER, isOwner: true }));
    assert.true(canViewSubscribers({ setting: "staff_owner", user: MODERATOR }));
    assert.false(
      canViewSubscribers({ setting: "staff_owner", user: MEMBER, isTeamworker: true }),
      "a co-maintainer is one level down"
    );
    assert.false(canViewSubscribers({ setting: "staff_owner", user: MEMBER }));
  });

  test("staff_owner_teamworker adds this collection's co-maintainers", function (assert) {
    assert.true(canViewSubscribers({ setting: "staff_owner_teamworker", user: MEMBER, isOwner: true }));
    assert.true(
      canViewSubscribers({ setting: "staff_owner_teamworker", user: MEMBER, isTeamworker: true })
    );
    assert.false(canViewSubscribers({ setting: "staff_owner_teamworker", user: MEMBER }));
  });
});
