import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DLoadMore from "discourse/ui-kit/d-load-more";
import DModal from "discourse/ui-kit/d-modal";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { escapeExpression } from "discourse/lib/utilities";
import { eq, includes } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dNumber from "discourse/ui-kit/helpers/d-number";
import {
  addTopicToCollection,
  listMyCollections,
  removeTopicFromCollection,
  selectReplyInCollection,
  unselectReplyFromCollection,
} from "../../lib/collection-api";

/**
 * Collection manager opened from a post's action bar. Lists the collections the
 * acting user maintains and acts on one of them per click — the topic's membership
 * on the first post, the reply's featured state on any other post. Every action
 * confirms first and the modal stays open so a run of collections can be edited
 * without reopening it.
 *
 * Its header also carries the way to create a collection. The form is a modal of its
 * own and the modal service holds one at a time, so the picker hands the chore to its
 * caller and is reopened by it once the form is done (see the entry point in
 * components/post-menu).
 */
export default class AddToCollectionModal extends Component {
  @service dialog;

  @tracked collectedIds = [];
  @tracked collections = [];
  @tracked loading = false;
  @tracked loadingMore = false;
  @tracked meta = { page: 0, page_size: 30, more: false, total: 0 };
  @tracked pendingId = null;
  @tracked selectedIds = [];

  #requestSeq = 0;

  get canLoadMore() {
    return this.meta.more && !this.loading && !this.loadingMore;
  }

  get isPostMode() {
    return this.args.model.mode === "post";
  }

  get titleKey() {
    return this.isPostMode
      ? "collections.topic.feature_title"
      : "collections.topic.picker_title";
  }

  @action
  close() {
    this.args.closeModal?.();
  }

  @action
  createCollection() {
    this.args.model.onCreate?.();
  }

  @action
  async load() {
    // The list endpoint carries no membership information, so the row state is
    // seeded by the caller from the topic and post the server injected (docs/07).
    this.collectedIds = [...(this.args.model.collectedIds ?? [])];
    this.selectedIds = [...(this.args.model.selectedIds ?? [])];

    const seq = ++this.#requestSeq;
    this.loading = true;
    try {
      const page = await listMyCollections({
        page: 0,
        page_size: this.meta.page_size,
      });
      if (seq !== this.#requestSeq) {
        return;
      }
      this.collections = this.#pinNewCollection(page.collections);
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
      const page = await listMyCollections({
        page: this.meta.page + 1,
        page_size: this.meta.page_size,
      });
      if (seq !== this.#requestSeq) {
        return;
      }
      this.collections = this.#pinNewCollection([
        ...this.collections,
        ...page.collections,
      ]);
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

  @action
  async collect(collection) {
    await this.#apply(collection, {
      messageKey: "collections.topic.confirm_collect",
      labelKey: "collections.topic.collect",
      request: () => addTopicToCollection(collection.id, this.args.model.topicId),
      flip: () => {
        this.collectedIds = [...this.collectedIds, collection.id];
        this.args.model.onCollect?.({
          id: collection.id,
          name: collection.name,
        });
      },
    });
  }

  @action
  async feature(collection) {
    await this.#apply(collection, {
      messageKey: "collections.topic.confirm_feature",
      labelKey: "collections.topic.feature",
      request: () =>
        selectReplyInCollection(
          collection.id,
          this.args.model.topicId,
          this.args.model.postId
        ),
      flip: () => {
        this.selectedIds = [...this.selectedIds, collection.id];
        this.args.model.onFeature?.(collection.id);
      },
    });
  }

  @action
  async uncollect(collection) {
    await this.#apply(collection, {
      messageKey: "collections.topic.confirm_uncollect",
      labelKey: "collections.topic.uncollect",
      danger: true,
      request: () =>
        removeTopicFromCollection(collection.id, this.args.model.topicId),
      flip: () => {
        this.collectedIds = this.collectedIds.filter(
          (id) => id !== collection.id
        );
        // Un-collecting also clears the topic's featured replies server-side.
        this.selectedIds = [];
        this.args.model.onUncollect?.(collection.id);
      },
    });
  }

  @action
  async unfeature(collection) {
    await this.#apply(collection, {
      messageKey: "collections.topic.confirm_unfeature",
      labelKey: "collections.topic.unfeature",
      danger: true,
      request: () =>
        unselectReplyFromCollection(
          collection.id,
          this.args.model.topicId,
          this.args.model.postId
        ),
      flip: () => {
        this.selectedIds = this.selectedIds.filter(
          (id) => id !== collection.id
        );
        this.args.model.onUnfeature?.(collection.id);
      },
    });
  }

  async #apply(collection, { messageKey, labelKey, danger, request, flip }) {
    // The dialog renders the message as trusted HTML, and a collection name is user
    // text, so it is escaped before interpolation.
    const confirmed = await this.dialog.confirm({
      message: i18n(messageKey, { name: escapeExpression(collection.name) }),
      confirmButtonLabel: labelKey,
      confirmButtonClass: danger ? "btn-danger" : "btn-primary",
    });

    if (!confirmed) {
      return;
    }

    this.pendingId = collection.id;
    try {
      await request();
      flip();
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.pendingId = null;
    }
  }

  // A collection created through this modal's own entry point holds no topics yet, so the
  // list's ordering (last topic added, newest first) would leave it at the very bottom —
  // where the user who just created it cannot see it. It is pinned to the top instead, and
  // filtered out of the pages so it never shows twice.
  #pinNewCollection(collections) {
    const created = this.args.model.newCollection;

    if (!created) {
      return collections;
    }

    return [created, ...collections.filter((item) => item.id !== created.id)];
  }

  <template>
    <DModal
      class="add-to-collection-modal"
      @closeModal={{this.close}}
      @title={{i18n this.titleKey}}
    >
      <:headerBelowTitle>
        <button
          type="button"
          class="btn btn-default add-to-collection__new"
          {{on "click" this.createCollection}}
        >
          {{i18n "collections.topic.new_collection"}}
        </button>
      </:headerBelowTitle>
      <:body>
        <div class="add-to-collection" {{didInsert this.load}}>
          <p class="add-to-collection__topic">{{this.args.model.title}}</p>

          {{#if this.loading}}
            <DConditionalLoadingSpinner @condition={{this.loading}} />
          {{else if this.collections.length}}
            <DLoadMore
              @action={{this.loadMore}}
              @enabled={{this.canLoadMore}}
              @isLoading={{this.loadingMore}}
            >
              <ul class="add-to-collection__list">
                {{#each this.collections as |collection|}}
                  <li
                    class="add-to-collection__row"
                    data-collection-id={{collection.id}}
                  >
                    <span class="add-to-collection__name">
                      {{collection.name}}
                    </span>
                    <span class="add-to-collection__count">
                      {{dIcon "layer-group"}}
                      {{dNumber collection.topic_count}}
                    </span>
                    {{! The mode owns the row: the first post only ever collects or
                    un-collects its topic, a reply only ever features or unfeatures
                    that reply. Membership of the topic alone never turns a reply row
                    into a feature toggle, nor the other way around. }}
                    {{#if this.isPostMode}}
                      {{#if (includes this.collectedIds collection.id)}}
                        {{#if (includes this.selectedIds collection.id)}}
                          <button
                            type="button"
                            class="btn btn-small btn-danger add-to-collection__action"
                            disabled={{eq this.pendingId collection.id}}
                            {{on "click" (fn this.unfeature collection)}}
                          >
                            {{i18n "collections.topic.unfeature"}}
                          </button>
                        {{else}}
                          <button
                            type="button"
                            class="btn btn-small add-to-collection__action"
                            disabled={{eq this.pendingId collection.id}}
                            {{on "click" (fn this.feature collection)}}
                          >
                            {{i18n "collections.topic.feature"}}
                          </button>
                        {{/if}}
                      {{else}}
                        <button
                          type="button"
                          class="btn btn-small add-to-collection__action"
                          disabled={{true}}
                        >
                          {{i18n "collections.topic.feature"}}
                        </button>
                        <span class="add-to-collection__hint">
                          {{i18n "collections.topic.feature_requires_topic"}}
                        </span>
                      {{/if}}
                    {{else if (includes this.collectedIds collection.id)}}
                      <button
                        type="button"
                        class="btn btn-small btn-danger add-to-collection__action"
                        disabled={{eq this.pendingId collection.id}}
                        {{on "click" (fn this.uncollect collection)}}
                      >
                        {{i18n "collections.topic.uncollect"}}
                      </button>
                    {{else}}
                      <button
                        type="button"
                        class="btn btn-small add-to-collection__action"
                        disabled={{eq this.pendingId collection.id}}
                        {{on "click" (fn this.collect collection)}}
                      >
                        {{i18n "collections.topic.collect"}}
                      </button>
                    {{/if}}
                  </li>
                {{/each}}
              </ul>
            </DLoadMore>
          {{else}}
            <p class="add-to-collection__empty">
              {{i18n "collections.topic.picker_empty"}}
            </p>
          {{/if}}
        </div>
      </:body>
    </DModal>
  </template>
}
