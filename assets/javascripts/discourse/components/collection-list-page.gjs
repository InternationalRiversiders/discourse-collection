import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import CollectionTabs from "./collection-tabs";
import CollectionTile from "./collection-tile";
import CollectionFormModal from "./modal/collection-form-modal";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DEmptyState from "discourse/ui-kit/d-empty-state";
import DLoadMore from "discourse/ui-kit/d-load-more";
import dIcon from "discourse/ui-kit/helpers/d-icon";

export default class CollectionListPage extends Component {
  @service currentUser;
  @service modal;

  get showCreate() {
    return this.args.create && this.currentUser;
  }

  // The profile's collections tab reuses this page but is not one of the
  // /collections views: it renders neither the list tabs nor the sort controls.
  get showSort() {
    return this.args.showSort ?? true;
  }

  get showTabs() {
    return this.args.showTabs ?? true;
  }

  @action
  openCreate() {
    this.modal.show(CollectionFormModal, { model: { mode: "create" } });
  }

  <template>
    <section class="collection-list">
      <div class="container">
        {{#if this.showTabs}}
          <CollectionTabs />
        {{/if}}

        <header class="collection-list__header">
          <div class="collection-list__heading">
            <h1 class="collection-list__title">
              {{i18n @titleKey username=@username}}
            </h1>
            <p class="collection-list__subtitle">
              {{i18n @subtitleKey username=@username}}
            </p>
          </div>
          {{#if this.showCreate}}
            <button
              type="button"
              class="collection-list__new-button btn btn-primary"
              {{on "click" this.openCreate}}
            >
              {{dIcon "plus"}}
              {{i18n "collections.new_button"}}
            </button>
          {{/if}}
        </header>

        {{#if this.showSort}}
          <div class="collection-list__toolbar">
            <div
              class="collection-list__sort"
              role="group"
              aria-label={{i18n "collections.sort_label"}}
            >
              {{#each @controller.sortFields as |field|}}
                <button
                  type="button"
                  class={{if
                    (eq @controller.sort field)
                    "collection-list__sort-button -active"
                    "collection-list__sort-button"
                  }}
                  aria-pressed={{eq @controller.sort field}}
                  {{on "click" (fn @controller.changeSort field)}}
                >
                  {{i18n (concat "collections.sort." field)}}
                </button>
              {{/each}}
            </div>
            <button
              type="button"
              class="collection-list__order-toggle"
              title={{if
                (eq @controller.order "asc")
                (i18n "collections.order_asc")
                (i18n "collections.order_desc")
              }}
              {{on "click" @controller.toggleOrder}}
            >
              {{dIcon (if (eq @controller.order "asc") "arrow-up" "arrow-down")}}
              {{i18n
                (if (eq @controller.order "asc") "collections.order_asc" "collections.order_desc")
              }}
            </button>
          </div>
        {{/if}}

        {{#if @controller.meta.total}}
          <p class="collection-list__total">
            {{i18n "collections.results_total" count=@controller.meta.total}}
          </p>
        {{/if}}

        <DLoadMore
          @action={{@controller.loadMore}}
          @enabled={{@controller.canLoadMore}}
          @isLoading={{@controller.loadingMore}}
        >
          {{#if @controller.collections.length}}
            <div class="collection-list__grid">
              {{#each @controller.collections as |collection|}}
                <CollectionTile @collection={{collection}} />
              {{/each}}
            </div>
          {{else}}
            <DEmptyState
              @title={{i18n @emptyTitleKey username=@username}}
              @body={{i18n @emptyBodyKey username=@username}}
            />
          {{/if}}
        </DLoadMore>

        {{#if @controller.canLoadMore}}
          <DConditionalLoadingSpinner @condition={{@controller.loadingMore}} />
        {{/if}}
      </div>
    </section>
  </template>
}
