import Component from "@glimmer/component";
import DNavigationItem from "discourse/ui-kit/d-navigation-item";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

/**
 * The collections tab appended to a profile's activity tab bar (core's
 * user-activity-bottom outlet). DNavigationItem renders its own list item, which
 * the outlet would only wrap on top for a legacy connector.
 */
export default class CollectionUserActivityTab extends Component {
  static shouldRender(args, context) {
    if (!context.siteSettings.collection_enabled) {
      return false;
    }
    // Guests only get the tab when anonymous reading is enabled, matching the
    // sidebar entry and the topic-page chips.
    return Boolean(
      context.currentUser || context.siteSettings.collection_allow_anonymous
    );
  }

  <template>
    <DNavigationItem
      class="user-nav__activity-collections"
      @ariaCurrentContext="subNav"
      @route="userActivity.collections"
    >
      {{dIcon "collection"}}
      <span>{{i18n "collections.nav_name"}}</span>
    </DNavigationItem>
  </template>
}
