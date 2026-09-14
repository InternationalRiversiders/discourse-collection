import { service } from "@ember/service";
import Component from "@glimmer/component";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

// The role badge on a tile reports the viewer's own standing in that collection, not the
// standing of the user whose collections the page lists. Guests hold no role and see no
// badge, so they get no note either.
export default class CollectionRoleHint extends Component {
  @service currentUser;

  <template>
    {{#if this.currentUser}}
      <p class="collection-role-hint">
        {{dIcon "circle-info"}}
        {{i18n "collections.role_hint"}}
      </p>
    {{/if}}
  </template>
}
