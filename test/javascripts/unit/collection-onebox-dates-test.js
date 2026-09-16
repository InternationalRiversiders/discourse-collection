import { module, test } from "qunit";
import { longDate } from "discourse/lib/formatter";
import {
  formatCollectionDate,
  renderCollectionDates,
} from "discourse/plugins/discourse-collection/discourse/lib/collection-onebox-dates";
import { i18n } from "discourse-i18n";

// Every expectation that could depend on the machine running the suite goes through
// core's own formatters, so the tests hold in any zone.
const NOW = new Date("2026-09-16T12:00:00Z");
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

function ago(ms) {
  return new Date(NOW.getTime() - ms);
}

module("Unit | Lib | collection-onebox-dates", function () {
  test("prints the full moment once the card is old", function (assert) {
    const tenDaysAgo = ago(10 * DAY);

    assert.strictEqual(
      formatCollectionDate(tenDaysAgo.getTime(), NOW),
      longDate(tenDaysAgo),
      "the baked UTC text gives way to a full local timestamp"
    );
  });

  test("keeps core's relative wording while the card is recent", function (assert) {
    assert.strictEqual(
      formatCollectionDate(ago(3 * HOUR).getTime(), NOW),
      i18n("dates.medium_with_ago.x_hours", { count: 3 }),
      "three hours reads as it does anywhere else on the site"
    );
  });

  test("says just now for a card baked moments ago", function (assert) {
    assert.strictEqual(
      formatCollectionDate(ago(30 * 1000).getTime(), NOW),
      i18n("now"),
      "a fresh card does not date itself to the minute"
    );
  });

  // The switch lands where core's medium format would have started printing a short date
  // instead, one second later rather than one second earlier.
  test("switches to the full timestamp past five days, and not before", function (assert) {
    assert.strictEqual(
      formatCollectionDate(ago(5 * DAY).getTime(), NOW),
      i18n("dates.medium_with_ago.x_days", { count: 5 }),
      "five days exactly still reads as relative"
    );

    const justOver = ago(5 * DAY + 1000);
    assert.strictEqual(
      formatCollectionDate(justOver.getTime(), NOW),
      longDate(justOver),
      "a second later it is the exact moment"
    );
  });

  test("rewrites every date a card carries, each on its own side of the cutoff", function (assert) {
    const createdAt = ago(3 * HOUR);
    const lastAddedAt = ago(30 * DAY);
    const root = document.createElement("div");
    root.innerHTML = `
      <span class="collection-onebox__date" data-time="${createdAt.getTime()}">baked</span>
      <span class="collection-onebox__date" data-time="${lastAddedAt.getTime()}">baked</span>
    `;

    renderCollectionDates(root, NOW);

    const dates = root.querySelectorAll(".collection-onebox__date");
    assert.strictEqual(
      dates[0].textContent,
      i18n("dates.medium_with_ago.x_hours", { count: 3 }),
      "the recent one keeps the relative wording"
    );
    assert.strictEqual(
      dates[1].textContent,
      longDate(lastAddedAt),
      "the old one carries the exact moment"
    );
  });

  test("leaves a date without a usable timestamp as it was baked", function (assert) {
    const root = document.createElement("div");
    root.innerHTML = `<span class="collection-onebox__date">September 16, 2026, 12:00pm UTC</span>`;

    renderCollectionDates(root, NOW);

    assert.strictEqual(
      root.querySelector(".collection-onebox__date").textContent,
      "September 16, 2026, 12:00pm UTC",
      "nothing to render against, so the fallback stands"
    );
  });
});
