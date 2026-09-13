import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { listMyCollections } from "../lib/collection-api";

export default class CollectionsMineRoute extends DiscourseRoute {
  @service currentUser;
  @service router;

  beforeModel() {
    // The endpoint is scoped to the logged-in user (docs/04 §6).
    if (!this.currentUser) {
      this.router.replaceWith("collections");
    }
  }

  queryParams = {
    sort: { refreshModel: true },
    order: { refreshModel: true },
  };

  async model(params) {
    return listMyCollections({
      sort: params.sort,
      order: params.order,
      page: 0,
    });
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.setProperties({
      collections: model.collections,
      meta: model.meta,
    });
  }
}
