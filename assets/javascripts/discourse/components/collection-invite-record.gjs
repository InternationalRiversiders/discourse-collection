import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import Component from "@glimmer/component";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import { i18n } from "discourse-i18n";
import CollectionInvitePerson from "./collection-invite-person";

// One recorded invitation, as the manager's side reads it (docs/05 §2.3): who asked
// whom for what, and where it stands. Revoking is the issuer's own call or a staff
// manager's (docs/05 §2.2), which is what the row's gate says. Shared by the page's preview
// and the full-list window.
export default class CollectionInviteRecord extends Component {
  <template>
    <li class="collection-invite-record" data-invite-id={{@row.invite.id}}>
      <span class="collection-invite-record__summary">
        <CollectionInvitePerson
          class="collection-invite-record__inviter"
          @user={{@row.inviter}}
        />
        <span class="collection-invite-record__verb">
          {{i18n "collections.invite_records.invited"}}
        </span>
        <CollectionInvitePerson
          class="collection-invite-record__invitee"
          @user={{@row.invitee}}
        />
        <span class="collection-invite-record__role">
          {{i18n "collections.invite_records.to_be" role=@row.roleName}}
        </span>
      </span>

      <span class="collection-invite-status -{{@row.invite.status}}">
        {{@row.statusLabel}}
      </span>
      <span class="collection-invite-record__date">
        {{dFormatDate @row.invite.created_at format="medium" leaveAgo="true"}}
      </span>

      {{#if @row.canRevoke}}
        <button
          type="button"
          class="btn btn-danger btn-small collection-invite-record__revoke"
          disabled={{@row.busy}}
          {{on "click" (fn @controller.revokeInvite @row.invite)}}
        >
          {{i18n "collections.invite_records.revoke"}}
        </button>
      {{/if}}
    </li>
  </template>
}
