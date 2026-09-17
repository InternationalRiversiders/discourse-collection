import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DLoadMore from "discourse/ui-kit/d-load-more";
import DModal from "discourse/ui-kit/d-modal";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import CollectionUser from "../collection-user";
import { listSubscribers } from "../../lib/collection-api";

// One collection's subscriber roster (docs/02 §5), newest subscription first: the opening
// page is who subscribed lately and paging walks back through the rest. The current owner
// is never in it — the one subscriber that does not count.
//
// The entry that opens this only exists for a viewer the site setting admits
// (collection_subscribers_visibility) and only above a non-zero count, so the empty branch
// is a safety net (a subscriber leaving between the page load and the click) rather than a
// state a visitor reaches. The endpoint re-checks the same rule, which is what keeps the
// roster out of the hands the collection itself may be open to (docs/01 §2).
export default class CollectionSubscribersModal extends Component {
  @tracked subscribers = [];
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
      const page = await listSubscribers(this.args.model.collectionId, {
        page: 0,
        page_size: this.meta.page_size,
      });
      if (seq !== this.#requestSeq) {
        return;
      }
      this.subscribers = page.subscribers;
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
      const page = await listSubscribers(this.args.model.collectionId, {
        page: this.meta.page + 1,
        page_size: this.meta.page_size,
      });
      if (seq !== this.#requestSeq) {
        return;
      }
      this.subscribers = [...this.subscribers, ...page.subscribers];
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
      @title={{i18n "collections.detail.subscribers_title"}}
    >
      <:body>
        <div class="collection-subscribers" {{didInsert this.load}}>
          {{#if this.loading}}
            <DConditionalLoadingSpinner @condition={{this.loading}} />
          {{else if this.subscribers.length}}
            <DLoadMore
              @action={{this.loadMore}}
              @enabled={{this.canLoadMore}}
              @isLoading={{this.loadingMore}}
            >
              <ul class="collection-subscribers__list">
                {{#each this.subscribers as |subscriber|}}
                  <li class="collection-subscribers__subscriber">
                    <CollectionUser @user={{subscriber}} />
                  </li>
                {{/each}}
              </ul>
            </DLoadMore>
            {{#if this.loadingMore}}
              <DConditionalLoadingSpinner @condition={{this.loadingMore}} />
            {{/if}}
          {{else}}
            <p class="collection-subscribers__empty">
              {{i18n "collections.detail.subscribers_empty"}}
            </p>
          {{/if}}
        </div>
      </:body>
    </DModal>
  </template>
}
