import { on } from "@ember/modifier";
import CollectionTopicRow from "./collection-topic-row";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DEmptyState from "discourse/ui-kit/d-empty-state";
import DLoadMore from "discourse/ui-kit/d-load-more";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

// The collection reading feed (docs/04 §1): paginated collected topics below the
// detail header, newest-add first by default with an asc/desc toggle. Data and
// paging live on the page controller; this stays a thin view over it.
export default <template>
  <section class="collection-topics">
    <header class="collection-topics__header">
      <h2 class="collection-topics__heading">
        {{i18n "collections.reading.heading"}}
      </h2>
      <button
        type="button"
        class="collection-topics__order-toggle"
        title={{if
          (eq @controller.topicsOrder "asc")
          (i18n "collections.order_asc")
          (i18n "collections.order_desc")
        }}
        {{on "click" @controller.toggleTopicsOrder}}
      >
        {{dIcon (if (eq @controller.topicsOrder "asc") "arrow-up" "arrow-down")}}
        {{i18n
          (if (eq @controller.topicsOrder "asc") "collections.order_asc" "collections.order_desc")
        }}
      </button>
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
        @title={{i18n "collections.no_topics_yet"}}
        @body={{i18n "collections.reading.empty_body"}}
      />
    {{/if}}
  </section>
</template>;
