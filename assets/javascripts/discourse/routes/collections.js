import DiscourseRoute from "discourse/routes/discourse";
import { listCollections } from "../lib/collection-api";

export default class CollectionsRoute extends DiscourseRoute {
  queryParams = {
    sort: { refreshModel: true },
    order: { refreshModel: true },
  };

  async model(params) {
    return listCollections({
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
