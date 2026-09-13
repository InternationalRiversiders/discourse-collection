import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";
import CollectionUser from "./collection-user";

// One side of an invitation, as both invite surfaces name it (docs/05 §2.1): face
// plus username, or a stand-in when the account is gone. Either side may be deleted —
// both user references are nullable — and a row still has to read as a sentence.
export default class CollectionInvitePerson extends Component {
  get username() {
    return this.args.user?.username ?? null;
  }

  <template>
    <span class="collection-invite-person" ...attributes>
      {{#if this.username}}
        <CollectionUser
          class="collection-user-link"
          @hideTitle={{true}}
          @user={{@user}}
        />
      {{else}}
        <span class="collection-invite-person__gone">
          {{i18n "collections.invites.unknown_user"}}
        </span>
      {{/if}}
    </span>
  </template>
}
