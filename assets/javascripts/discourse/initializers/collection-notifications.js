import { withPluginApi } from "discourse/lib/plugin-api";
import { registerCollectionNotificationRenderers } from "../lib/collection-notifications";

// Gives this plugin's four notification types (docs/09 §1) their user-menu
// rendering; the classes themselves live in lib/collection-notifications.
export default {
  name: "collection-notifications",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.collection_enabled) {
      return;
    }

    withPluginApi((api) => {
      if (!api.registerNotificationTypeRenderer) {
        return;
      }

      registerCollectionNotificationRenderers(api);
    });
  },
};
