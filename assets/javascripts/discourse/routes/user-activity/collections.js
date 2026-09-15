import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";
import { listCollections } from "../../lib/collection-api";

/**
 * A profile's collections tab (docs/03 §3 with `username`): the collections that
 * user created or maintains. The order is the endpoint's documented default —
 * most recently collected first — so no sort is sent.
 */
export default class UserActivityCollectionsRoute extends DiscourseRoute {
  @service currentUser;
  @service router;
  @service siteSettings;

  beforeModel() {
    // Same gate as the tab itself: reading collections requires the anonymous
    // toggle when logged out.
    if (!this.currentUser && !this.siteSettings.collection_allow_anonymous) {
      this.router.replaceWith("userActivity.index");
    }
  }

  model() {
    return listCollections({
      username: this.modelFor("user").username,
      page: 0,
    });
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    // Reseeded for every :username, so loadMore() never mixes two users' pages.
    controller.setProperties({
      username: this.modelFor("user").username,
      collections: model.collections,
      meta: model.meta,
    });
  }

  // Only our own segment: core's `user` and `userActivity` ancestors already contribute
  // the username and the activity stream, so naming the user here would print them twice.
  titleToken() {
    return i18n("collections.nav_name");
  }
}
