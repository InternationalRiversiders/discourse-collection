import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { LinkTo } from "@ember/routing";
import Component from "@glimmer/component";
import rawDate from "discourse/helpers/raw-date";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import { i18n } from "discourse-i18n";
import CollectionInvitePerson from "./collection-invite-person";

// One invitation as the invitee reads it (docs/05 §2.4). The row answers "what am
// I being asked, and by whom", "until when", and — for a transfer — who holds the
// collection now; only a pending invitation carries the expiry.
export default class CollectionInviteCard extends Component {
  <template>
    <li
      class="collection-invite-card -{{@row.invite.status}}"
      data-invite-id={{@row.invite.id}}
    >
      <div class="collection-invite-card__header">
        <LinkTo
          class="collection-invite-card__collection"
          @route="collectionsShow"
          @model={{@row.invite.collection.id}}
        >
          {{@row.invite.collection.name}}
        </LinkTo>
        <span class="collection-invite-status -{{@row.invite.status}}">
          {{@row.statusLabel}}
        </span>
      </div>

      <p class="collection-invite-card__role">
        <CollectionInvitePerson
          class="collection-invite-card__inviter"
          @user={{@row.inviter}}
        />
        <span class="collection-invite-card__ask">
          {{i18n "collections.invites.invited_you" role=@row.roleName}}
        </span>
      </p>

      {{#if @row.isOwnershipTransfer}}
        <p class="collection-invite-card__owner">
          {{#if @row.ownerUsername}}
            {{i18n "collections.invites.current_owner" username=@row.ownerUsername}}
          {{else}}
            {{i18n "collections.invites.no_current_owner"}}
          {{/if}}
        </p>
      {{/if}}

      <div class="collection-invite-card__meta">
        <span class="collection-invite-card__date">
          {{dFormatDate
            @row.invite.created_at
            format="medium"
            leaveAgo="true"
          }}
        </span>
        {{#if @row.isPending}}
          {{! The one date here that lies in the future, and relative ages only read
              backwards: relativeAgeMedium treats a negative distance as "now", so
              dFormatDate would print "just now" for an expiry ten days out. An
              absolute date is what "expires" means anyway (core renders its own
              invitation expiry the same way). }}
          <span class="collection-invite-card__expiry">
            {{i18n "collections.invites.expires"}}
            {{rawDate @row.invite.expires_at}}
          </span>
        {{/if}}
      </div>

      {{#if @row.isPending}}
        <div class="collection-invite-card__actions">
          <button
            type="button"
            class="btn btn-primary btn-small collection-invite-card__accept"
            disabled={{@row.busy}}
            {{on "click" (fn @controller.accept @row)}}
          >
            {{i18n "collections.invites.accept"}}
          </button>
          <button
            type="button"
            class="btn btn-small collection-invite-card__reject"
            disabled={{@row.busy}}
            {{on "click" (fn @controller.reject @row)}}
          >
            {{i18n "collections.invites.reject"}}
          </button>
        </div>
      {{/if}}
    </li>
  </template>
}
