import { isTesting } from "discourse/lib/environment";
import { withPluginApi } from "discourse/lib/plugin-api";
import { renderCollectionDates } from "../lib/collection-onebox-dates";

// The text baked into a card is a UTC timestamp, and a relative wording would go stale
// sitting in a post, so the card re-renders its dates in the browser: once as the post is
// built, and then on the same heartbeat core uses for its own dates. The decorator runs
// while the cooked element is still detached (d-decorated-html.gjs), so the baked text is
// never on screen — it is what mails, digests and readers without JavaScript get.
const REFRESH_INTERVAL = 60 * 1000;

export default {
  name: "collection-onebox-dates",

  initialize() {
    withPluginApi((api) => {
      api.decorateCookedElement((element) => renderCollectionDates(element));
    });

    if (isTesting()) {
      return;
    }

    this._refreshInterval = setInterval(
      () => renderCollectionDates(document),
      REFRESH_INTERVAL
    );
  },

  teardown() {
    clearInterval(this._refreshInterval);
  },
};
