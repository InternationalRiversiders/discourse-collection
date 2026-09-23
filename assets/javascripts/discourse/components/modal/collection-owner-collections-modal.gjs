import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DLoadMore from "discourse/ui-kit/d-load-more";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";
import { listCollections } from "../../lib/collection-api";
import cardMasonry from "../../modifiers/card-masonry";
import CollectionRoleHint from "../collection-role-hint";
import CollectionTile from "../collection-tile";

// Everything one user created or maintains (docs/03 §3), rendered as the same tiles the
// /collections page shows. Opened from the owner chips block on a collection page, which
// carries only a capped, name-only slice of that list — this one pages through the rest.
// The collection the reader came from is part of the list too: the endpoint is the plain
// user filter, unfiltered here.
export default class CollectionOwnerCollectionsModal extends Component {
  @tracked collections = [];
  @tracked meta = { page: 0, page_size: 30, more: false, total: 0 };
  @tracked loading = false;
  @tracked loadingMore = false;

  #requestSeq = 0;

  get canLoadMore() {
    return this.meta.more && !this.loading && !this.loadingMore;
  }

  @action
  close() {
    this.args.closeModal?.();
  }

  @action
  async load() {
    const seq = ++this.#requestSeq;
    this.loading = true;
    try {
      const page = await listCollections({
        username: this.args.model.username,
        page: 0,
        page_size: this.meta.page_size,
      });
      if (seq !== this.#requestSeq) {
        return;
      }
      this.collections = page.collections;
      this.meta = page.meta;
    } catch (err) {
      if (seq === this.#requestSeq) {
        popupAjaxError(err);
      }
    } finally {
      if (seq === this.#requestSeq) {
        this.loading = false;
      }
    }
  }

  @action
  async loadMore() {
    if (!this.canLoadMore) {
      return;
    }

    const seq = this.#requestSeq;
    this.loadingMore = true;
    try {
      const page = await listCollections({
        username: this.args.model.username,
        page: this.meta.page + 1,
        page_size: this.meta.page_size,
      });
      if (seq !== this.#requestSeq) {
        return;
      }
      this.collections = [...this.collections, ...page.collections];
      this.meta = page.meta;
    } catch (err) {
      if (seq === this.#requestSeq) {
        popupAjaxError(err);
      }
    } finally {
      if (seq === this.#requestSeq) {
        this.loadingMore = false;
      }
    }
  }

  <template>
    <DModal
      @closeModal={{this.close}}
      @title={{i18n
        "collections.owner_collections.title"
        username=@model.username
      }}
    >
      <:body>
        <div class="collection-owner-collections" {{didInsert this.load}}>
          <CollectionRoleHint />
          {{#if this.loading}}
            <DConditionalLoadingSpinner @condition={{this.loading}} />
          {{else}}
            <DLoadMore
              @action={{this.loadMore}}
              @enabled={{this.canLoadMore}}
              @isLoading={{this.loadingMore}}
            >
              <div
                class="collection-list__grid"
                {{cardMasonry ".collection-tile"}}
              >
                {{#each this.collections as |collection|}}
                  {{! The modal outlives the route change, so the tile takes it down on
                  the way to the collection it points at. }}
                  <CollectionTile
                    @collection={{collection}}
                    @onNavigate={{this.close}}
                  />
                {{/each}}
              </div>
            </DLoadMore>
            {{#if this.loadingMore}}
              <DConditionalLoadingSpinner @condition={{this.loadingMore}} />
            {{/if}}
          {{/if}}
        </div>
      </:body>
    </DModal>
  </template>
}
