import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

export default {
  name: "collection-nav",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    const currentUser = container.lookup("service:current-user");

    // The whole plugin is hidden when disabled, and anonymous readers only see
    // lists when the anonymous read setting is on (docs/01 §2).
    const showCommunityLink =
      siteSettings.collection_enabled &&
      (currentUser || siteSettings.collection_allow_anonymous);

    withPluginApi((api) => {
      // The admin sidebar gives every plugin a gear by default; use our own sprite
      // symbol (svg-icons/collection.svg) there too. Registered outside the gate
      // below so it never depends on the community link being visible.
      api.setAdminPluginIcon("discourse-collection", "collection");

      if (!showCommunityLink) {
        return;
      }

      api.addCommunitySectionLink({
        name: "collections",
        route: "collections",
        text: i18n("collections.nav_name"),
        title: i18n("collections.nav_title"),
        icon: "collection",
      });
    });
  },
};
