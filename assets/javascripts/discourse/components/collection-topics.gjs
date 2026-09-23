import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DEmptyState from "discourse/ui-kit/d-empty-state";
import DLoadMore from "discourse/ui-kit/d-load-more";
import { i18n } from "discourse-i18n";
import CollectionSortBar from "./collection-sort-bar";
import CollectionTopicRow from "./collection-topic-row";

export default <template>
  <section class="collection-topics">
    <header class="collection-topics__header">
      <h2 class="collection-topics__heading">
        {{i18n "collections.reading.heading"}}
      </h2>
      <div class="collection-topics__sorting">
        <CollectionSortBar
          @fields={{@controller.topicsSortFields}}
          @labelKey="collections.reading.sort_label"
          @labelPrefix="collections.reading.sort."
          @onChangeSort={{@controller.changeTopicsSort}}
          @onToggleOrder={{@controller.toggleTopicsOrder}}
          @order={{@controller.topicsOrder}}
          @sort={{@controller.topicsSort}}
        />
        {{#if @controller.canManageReadingDefaults}}
          <DButton
            class="btn-default collection-topics__save-default"
            @action={{@controller.saveReadingDefaults}}
            @disabled={{@controller.savingDefaultsDisabled}}
            @icon="check"
            @label={{@controller.saveDefaultsLabel}}
            @title="collections.reading.default_hint"
          />
        {{/if}}
      </div>
    </header>

    {{#if @controller.loadingTopics}}
      <DConditionalLoadingSpinner @condition={{@controller.loadingTopics}} />
    {{else if @controller.topics.length}}
      <DLoadMore
        @action={{@controller.loadMoreTopics}}
        @enabled={{@controller.canLoadMoreTopics}}
        @isLoading={{@controller.loadingMoreTopics}}
      >
        <div class="collection-topics__list">
          {{#each @controller.topics as |row|}}
            <CollectionTopicRow
              @collection={{@collection}}
              @controller={{@controller}}
              @row={{row}}
            />
          {{/each}}
        </div>
      </DLoadMore>
    {{else}}
      <DEmptyState
        @body={{i18n "collections.reading.empty_body"}}
        @title={{i18n "collections.no_topics_yet"}}
      />
    {{/if}}
  </section>
</template>
