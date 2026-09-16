import { longDate, relativeAgeMediumSpan } from "discourse/lib/formatter";
import { i18n } from "discourse-i18n";

// The card bakes its timestamps as absolute dates in the server's zone, which is UTC and
// is not the reader's (docs/12 §5). The browser knows better than the server does here, so
// it re-renders them; the initializer decides when.

// Core's medium format stops saying "3 days ago" past five days and prints a short date
// instead, and no format keeps the full timestamp (frontend/discourse/app/lib/formatter.js).
// The card wants the full one in the reader's own zone, so the cutoff is applied here
// rather than handed to core.
const RELATIVE_CUTOFF_SECONDS = 5 * 24 * 60 * 60;

const MINUTE_SECONDS = 60;

export const DATE_SELECTOR = ".collection-onebox__date[data-time]";

/**
 * The text a baked timestamp should read as right now: relative while it is recent, the
 * full moment once it is not.
 *
 * @param {number} epochMs - The timestamp the card baked into `data-time`.
 * @param {Date} now - The moment to measure against.
 */
export function formatCollectionDate(epochMs, now) {
  const distance = Math.round((now.getTime() - epochMs) / 1000);

  if (distance < MINUTE_SECONDS) {
    return i18n("now");
  }

  if (distance > RELATIVE_CUTOFF_SECONDS) {
    return longDate(new Date(epochMs));
  }

  return relativeAgeMediumSpan(distance, true);
}

/**
 * Rewrites every date in the cards under `root`, leaving the baked text in place for
 * anything that carries no timestamp.
 *
 * @param {Element} root - The subtree to sweep, a rendered post or the document.
 * @param {Date} [now] - The moment to measure against.
 */
export function renderCollectionDates(root, now = new Date()) {
  root.querySelectorAll(DATE_SELECTOR).forEach((element) => {
    const epochMs = parseInt(element.dataset.time, 10);

    if (epochMs) {
      element.textContent = formatCollectionDate(epochMs, now);
    }
  });
}
