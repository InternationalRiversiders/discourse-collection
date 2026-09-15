import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import CollectionFormModal from "./modal/collection-form-modal";

// The way into the create form, shared by every collection list so the entry sits in
// the same place on all of them. Creating needs an account, so a guest is not shown
// the button at all — and the endpoint would refuse one anyway.
export default class CollectionCreateButton extends Component {
  @service currentUser;
  @service modal;

  get canCreate() {
    return Boolean(this.currentUser);
  }

  @action
  openCreate() {
    this.modal.show(CollectionFormModal, { model: { mode: "create" } });
  }

  <template>
    {{#if this.canCreate}}
      <button
        type="button"
        class="collection-list__new-button btn btn-primary"
        {{on "click" this.openCreate}}
      >
        {{dIcon "plus"}}
        {{i18n "collections.new_button"}}
      </button>
    {{/if}}
  </template>
}
