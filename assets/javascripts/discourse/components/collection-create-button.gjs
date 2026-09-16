import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import CollectionFormModal from "./modal/collection-form-modal";

// The way into the create form, shared by every collection list so the entry sits in
// the same place on all of them. Who may create is the server's answer (docs/01 §3), not
// a rule restated here: a guest carries no such flag, and the endpoint refuses the rest.
export default class CollectionCreateButton extends Component {
  @service currentUser;
  @service modal;

  get canCreate() {
    return Boolean(this.currentUser?.can_create_collection);
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
