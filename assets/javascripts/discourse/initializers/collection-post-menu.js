import { withPluginApi } from "discourse/lib/plugin-api";
import CollectionPostMenuButton from "../components/post-menu/collection-post-menu-button";

// Adds the collections entry to every post's action bar. `api.addPostMenuButton` is
// decommissioned, so the button joins the "more" region through the post-menu-buttons
// value transformer's DAG, the way discourse-assign and discourse-solved do.
export default {
  name: "collection-post-menu",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (!siteSettings.collection_enabled) {
      return;
    }

    withPluginApi((api) => {
      api.registerValueTransformer(
        "post-menu-buttons",
        ({ value: dag, context }) => {
          dag.add(
            "collection",
            CollectionPostMenuButton,
            // lastHiddenButtonKey is null when the site collapses no buttons at all;
            // only then fall back to the DAG's default position.
            context.lastHiddenButtonKey
              ? {
                  before: context.lastHiddenButtonKey,
                  after: context.secondLastHiddenButtonKey,
                }
              : undefined
          );
        }
      );
    });
  },
};
