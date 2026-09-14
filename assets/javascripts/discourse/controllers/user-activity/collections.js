import { tracked } from "@glimmer/tracking";
import { listCollections } from "../../lib/collection-api";
import CollectionListController from "../collection-list";

/**
 * A profile's collections tab. The order is fixed to the endpoint's default (most
 * recently collected first), so the page renders no sort controls and the URL
 * carries no sort params.
 */
export default class UserActivityCollectionsController extends CollectionListController {
  queryParams = [];

  @tracked sort = "last_topic_added_at";
  @tracked order = "desc";
  @tracked username = null;

  async fetchPage(options) {
    return listCollections({ ...options, username: this.username });
  }
}
