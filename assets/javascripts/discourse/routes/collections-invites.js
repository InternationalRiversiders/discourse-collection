import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { listMyInvites } from "../lib/collection-api";

export default class CollectionsInvitesRoute extends DiscourseRoute {
  @service currentUser;
  @service router;

  beforeModel() {
    // The inbox is always "mine" (docs/05 §2.4), so it is closed to guests
    // even when collection_allow_anonymous opens the public reads.
    if (!this.currentUser) {
      this.router.replaceWith("collections");
    }
  }

  async model() {
    return listMyInvites({ page: 0 });
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.setProperties({
      invites: model.invites,
      meta: model.meta,
    });
  }
}
