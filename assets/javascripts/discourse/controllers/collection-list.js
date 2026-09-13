import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { popupAjaxError } from "discourse/lib/ajax-error";

// Paged-list behaviour shared by the three /collections list views (all, mine,
// subscribed). Each subclass fixes its sortable columns and default sort, and
// implements fetchPage for its own endpoint.
export default class CollectionListController extends Controller {
  queryParams = ["sort", "order"];

  @tracked collections = [];
  @tracked meta = { page: 0, page_size: 30, more: false, total: 0 };
  @tracked order = "desc";
  @tracked loadingMore = false;

  get canLoadMore() {
    return this.meta.more && !this.loadingMore;
  }

  @action
  changeSort(sort) {
    if (this.sort !== sort) {
      this.sort = sort;
    }
  }

  @action
  toggleOrder() {
    this.order = this.order === "asc" ? "desc" : "asc";
  }

  @action
  async loadMore() {
    if (!this.meta.more || this.loadingMore) {
      return;
    }

    this.loadingMore = true;
    try {
      const next = await this.fetchPage({
        sort: this.sort,
        order: this.order,
        page: this.meta.page + 1,
        page_size: this.meta.page_size,
      });
      this.collections = [...this.collections, ...next.collections];
      this.meta = next.meta;
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.loadingMore = false;
    }
  }

  // Subclass contract: resolve to the endpoint's { collections, meta } page.
  async fetchPage() {
    throw new Error("fetchPage is not implemented");
  }
}
