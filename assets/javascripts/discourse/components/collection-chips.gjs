import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";

// A row of collection chips: an optional label, one link per collection (each entry only
// needs id and name), then whatever the caller yields — a trailing action, say. Callers
// that name the row with a heading of their own leave the label off.
// `.collection-chips` carries the row layout and the pill styling only; the page that
// uses it owns its own padding, borders and font size.
export default class CollectionChips extends Component {
  <template>
    <div class="collection-chips">
      {{#if @label}}
        <span class="collection-chips__label">{{@label}}</span>
      {{/if}}
      {{#each @collections as |collection|}}
        <LinkTo
          class="collection-chips__chip"
          @route="collectionsShow"
          @model={{collection.id}}
        >
          {{collection.name}}
        </LinkTo>
      {{/each}}
      {{yield}}
    </div>
  </template>
}
