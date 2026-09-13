import { LinkTo } from "@ember/routing";
import Component from "@glimmer/component";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";

// The three public / personal views plus the invite inbox. Every page under them
// renders the same bar, so the active view is one click away from anywhere; the
// personal views (and the inbox, which is always "mine") only exist for a logged-in
// viewer — a guest may read the public list and nothing else.
export default class CollectionTabs extends Component {
  @service currentUser;

  <template>
    <nav
      class="collection-list__tabs"
      aria-label={{i18n "collections.tabs_label"}}
    >
      <LinkTo
        class="collection-list__tab"
        data-link-name="collections-all"
        @route="collections"
      >
        {{i18n "collections.tabs.all"}}
      </LinkTo>

      {{#if this.currentUser}}
        <LinkTo
          class="collection-list__tab"
          data-link-name="collections-mine"
          @route="collectionsMine"
        >
          {{i18n "collections.tabs.mine"}}
        </LinkTo>
        <LinkTo
          class="collection-list__tab"
          data-link-name="collections-subscribed"
          @route="collectionsSubscribed"
        >
          {{i18n "collections.tabs.subscribed"}}
        </LinkTo>
        <LinkTo
          class="collection-list__tab"
          data-link-name="collections-invites"
          @route="collectionsInvites"
        >
          {{i18n "collections.tabs.invites"}}
        </LinkTo>
      {{/if}}
    </nav>
  </template>
}
