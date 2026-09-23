import Component from "@glimmer/component";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DEmptyState from "discourse/ui-kit/d-empty-state";
import DLoadMore from "discourse/ui-kit/d-load-more";
import { i18n } from "discourse-i18n";
import cardMasonry from "../modifiers/card-masonry";
import CollectionCreateButton from "./collection-create-button";
import CollectionRoleHint from "./collection-role-hint";
import CollectionSortBar from "./collection-sort-bar";
import CollectionTabs from "./collection-tabs";
import CollectionTile from "./collection-tile";

export default class CollectionListPage extends Component {
  get showCreate() {
    return Boolean(this.args.create);
  }

  // The profile's collections tab is the only caller that wants the note: every tile
  // there belongs to one user, so the role badge looks like that user's.
  get showRoleHint() {
    return this.args.showRoleHint ?? false;
  }

  // The profile's collections tab reuses this page but is not one of the
  // /collections views: it renders neither the list tabs nor the sort controls.
  get showSort() {
    return this.args.showSort ?? true;
  }

  get showTabs() {
    return this.args.showTabs ?? true;
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
            <CollectionCreateButton />
          {{/if}}
        </header>

        {{#if this.showRoleHint}}
          <CollectionRoleHint />
        {{/if}}

        {{#if this.showSort}}
          <div class="collection-list__toolbar">
            <CollectionSortBar
              @fields={{@controller.sortFields}}
              @labelKey="collections.sort_label"
              @labelPrefix="collections.sort."
              @onChangeSort={{@controller.changeSort}}
              @onToggleOrder={{@controller.toggleOrder}}
              @order={{@controller.order}}
              @sort={{@controller.sort}}
            />
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
            <div
              class="collection-list__grid"
              {{cardMasonry ".collection-tile"}}
            >
              {{#each @controller.collections as |collection|}}
                <CollectionTile
                  @collection={{collection}}
                  @sort={{@controller.sort}}
                />
              {{/each}}
            </div>
          {{else}}
            <DEmptyState
              @body={{i18n @emptyBodyKey username=@username}}
              @title={{i18n @emptyTitleKey username=@username}}
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
