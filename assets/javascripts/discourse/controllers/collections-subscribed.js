import { tracked } from "@glimmer/tracking";
import { listSubscribedCollections } from "../lib/collection-api";
import CollectionListController from "./collection-list";

export default class CollectionsSubscribedController extends CollectionListController {
  @tracked sort = "last_topic_added_at";

  get sortFields() {
    return [
      "created_at",
      "last_topic_added_at",
      "topic_count",
      "subscriber_count",
    ];
  }

  async fetchPage(options) {
    return listSubscribedCollections(options);
  }
}
