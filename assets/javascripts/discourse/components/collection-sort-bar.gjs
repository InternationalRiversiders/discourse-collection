import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import dIcon from "discourse/ui-kit/helpers/d-icon";

// The sort toolbar shared by the three collection lists and the reading feed: one pill
// per sortable key plus an asc/desc toggle. Callers own the state and the fetch, so each
// page keeps its own keys and default. @labelPrefix namespaces the per-key labels.
export default <template>
  <div class="collection-sort" ...attributes>
    <div class="collection-sort__fields" role="group" aria-label={{i18n @labelKey}}>
      {{#each @fields as |field|}}
        <button
          type="button"
          class={{if
            (eq @sort field)
            "collection-sort__button -active"
            "collection-sort__button"
          }}
          aria-pressed={{eq @sort field}}
          {{on "click" (fn @onChangeSort field)}}
        >
          {{i18n (concat @labelPrefix field)}}
        </button>
      {{/each}}
    </div>
    <button
      type="button"
      class="collection-sort__order-toggle"
      title={{if
        (eq @order "asc")
        (i18n "collections.order_asc")
        (i18n "collections.order_desc")
      }}
      {{on "click" @onToggleOrder}}
    >
      {{dIcon (if (eq @order "asc") "arrow-up" "arrow-down")}}
      {{i18n
        (if (eq @order "asc") "collections.order_asc" "collections.order_desc")
      }}
    </button>
  </div>
</template>;
