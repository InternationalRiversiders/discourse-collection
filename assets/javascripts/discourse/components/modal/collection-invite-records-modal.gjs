import { action } from "@ember/object";
import Component from "@glimmer/component";
import DLoadMore from "discourse/ui-kit/d-load-more";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";
import CollectionInviteRecord from "../collection-invite-record";

// The whole invitation record of one collection (docs/05 §2.3), opened from the
// page's preview when it was cut short. It reads the page controller's list rather
// than fetching its own: paging on past the first response, and revoking a row, then
// move the page behind the window too.
export default class CollectionInviteRecordsModal extends Component {
  @action
  close() {
    this.args.closeModal?.();
  }

  <template>
    <DModal
      @closeModal={{this.close}}
      @title={{i18n "collections.invite_records.heading"}}
    >
      <:body>
        <DLoadMore
          @action={{@model.controller.loadMoreInvites}}
          @enabled={{@model.controller.canLoadMoreInvites}}
          @isLoading={{@model.controller.loadingMoreInvites}}
        >
          <ul class="collection-invite-records__list">
            {{#each @model.controller.inviteRows as |row|}}
              <CollectionInviteRecord
                @row={{row}}
                @controller={{@model.controller}}
              />
            {{/each}}
          </ul>
        </DLoadMore>
      </:body>
    </DModal>
  </template>
}
