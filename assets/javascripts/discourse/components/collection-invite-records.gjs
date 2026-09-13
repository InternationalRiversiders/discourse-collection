import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import CollectionInviteRecord from "./collection-invite-record";
import CollectionInviteRecordsModal from "./modal/collection-invite-records-modal";

// The invitations of one collection, as its owner or a staff manager reads them
// (docs/05 §2.3). A record only grows, and the reading feed below it is what the
// page is for, so the page itself shows the few most recent rows and hands the rest
// to a window that paginates them.
export default class CollectionInviteRecords extends Component {
  @service modal;

  @action
  showAll() {
    this.modal.show(CollectionInviteRecordsModal, {
      model: { controller: this.args.controller },
    });
  }

  <template>
    <section class="collection-detail__invites">
      <h2 class="collection-detail__subheading">
        {{i18n "collections.invite_records.heading"}}
      </h2>

      <div class="collection-invite-records">
        <ul class="collection-invite-records__list">
          {{#each @controller.recentInviteRows as |row|}}
            <CollectionInviteRecord @row={{row}} @controller={{@controller}} />
          {{/each}}
        </ul>

        {{#if @controller.hasMoreInvites}}
          <button
            type="button"
            class="collection-invite-records__more"
            {{on "click" this.showAll}}
          >
            {{dIcon "chevron-down"}}
            {{i18n "collections.invite_records.show_all"}}
          </button>
        {{/if}}
      </div>
    </section>
  </template>
}
