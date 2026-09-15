import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";
import CollectionCreateButton from "./collection-create-button";
import CollectionInviteCard from "./collection-invite-card";
import CollectionTabs from "./collection-tabs";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DEmptyState from "discourse/ui-kit/d-empty-state";
import DLoadMore from "discourse/ui-kit/d-load-more";

// The invitee's inbox (docs/05 §2.4). Same shell as the three collection lists so the tab
// bar stays put, but the rows are invitations rather than collections, and they carry
// no sorting: the endpoint fixes the order at newest first.
export default class CollectionInvitesPage extends Component {
  <template>
    <section class="collection-list">
      <div class="container">
        <CollectionTabs />

        <header class="collection-list__header">
          <div class="collection-list__heading">
            <h1 class="collection-list__title">
              {{i18n "collections.invites.heading"}}
            </h1>
            <p class="collection-list__subtitle">
              {{i18n "collections.invites.subtitle"}}
            </p>
          </div>
          <CollectionCreateButton />
        </header>

        <DLoadMore
          @action={{@controller.loadMore}}
          @enabled={{@controller.canLoadMore}}
          @isLoading={{@controller.loadingMore}}
        >
          {{#if @controller.rows.length}}
            <ul class="collection-invites">
              {{#each @controller.rows as |row|}}
                <CollectionInviteCard @row={{row}} @controller={{@controller}} />
              {{/each}}
            </ul>
          {{else}}
            <DEmptyState
              @title={{i18n "collections.invites.empty_title"}}
              @body={{i18n "collections.invites.empty_body"}}
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
