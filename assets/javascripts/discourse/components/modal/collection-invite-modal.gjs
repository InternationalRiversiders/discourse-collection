import { hash } from "@ember/helper";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { extractErrorInfo, popupAjaxError } from "discourse/lib/ajax-error";
import UserChooser from "discourse/select-kit/components/user-chooser";
import DModal from "discourse/ui-kit/d-modal";
import { not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { INVITE_MAINTAINER, inviteToCollection } from "../../lib/collection-api";

// Sending one invitation from a collection page (docs/05 §2.1). @model.actionType
// picks the kind: 0 invites a co-maintainer, 1 invites a new owner. The wording and the
// granted role both follow from it; nothing takes effect until the invitee accepts, so
// the modal reports the pending invite rather than a changed team.
//
// Picking THEMSELVES is the one pick that can land at once (docs/05 §2.7): for a staff
// member on a collection they do not own it means taking that collection over, and the
// server does it inside the request — the response comes back accepted, and the page
// behind the modal is updated from it.
export default class CollectionInviteModal extends Component {
  @tracked error = null;
  @tracked invitee = null;
  @tracked inviteeUsername = null;
  @tracked sentTo = null;
  @tracked takenOver = false;
  @tracked submitting = false;

  get #key() {
    return this.args.model.actionType === INVITE_MAINTAINER
      ? "maintainer"
      : "owner";
  }

  get title() {
    return i18n(`collections.invite.${this.#key}.title`);
  }

  get description() {
    return i18n(`collections.invite.${this.#key}.description`);
  }

  get sentMessage() {
    return i18n(`collections.invite.${this.#key}.sent`, {
      username: this.sentTo,
    });
  }

  // A takeover is the inviter's own doing, so it names no one and waits for no one.
  get takenOverMessage() {
    return i18n("collections.invite.owner.taken_over");
  }

  get finished() {
    return this.takenOver || !!this.sentTo;
  }

  get canSubmit() {
    return !!this.invitee && !this.submitting;
  }

  @action
  close() {
    this.args.closeModal?.();
  }

  // select-kit hands over both the values (usernames) and the picked rows; the API
  // wants the user id, which only the row carries.
  @action
  pickInvitee(values, items) {
    this.invitee = items?.[0] ?? null;
    this.inviteeUsername = values?.[0] ?? null;
    this.error = null;
  }

  @action
  async submit() {
    if (!this.canSubmit) {
      return;
    }

    this.submitting = true;
    this.error = null;
    try {
      const response = await inviteToCollection(this.args.model.collectionId, {
        userId: this.invitee.id,
        actionType: this.args.model.actionType,
      });
      // A takeover answers with the invite it already accepted alongside the updated
      // collection; anything else answers the freshly parked invite itself.
      const invite = response.invite || response;
      if (invite.status === "accepted") {
        this.takenOver = true;
        this.args.model.onTakenOver?.(response.collection);
      } else {
        this.sentTo = this.invitee.username;
        this.args.model.onSent?.();
      }
    } catch (err) {
      // A 4xx here explains the pick itself (cap reached, already a co-maintainer, not
      // in an allowed group, one ownership invite already pending) and the server has
      // already worded it for the inviter's locale, so it belongs next to the field.
      const { message, status } = extractErrorInfo(err);
      if (status && status < 500) {
        this.error = message;
      } else {
        popupAjaxError(err);
      }
    } finally {
      this.submitting = false;
    }
  }

  <template>
    <DModal @closeModal={{this.close}} @title={{this.title}}>
      <:body>
        <div class="collection-invite">
          {{#if this.takenOver}}
            <p class="collection-invite__taken-over">{{this.takenOverMessage}}</p>
          {{else if this.sentTo}}
            <p class="collection-invite__sent">{{this.sentMessage}}</p>
          {{else}}
            <p class="collection-invite__description">{{this.description}}</p>

            {{! The viewer is not excluded wholesale: taking a collection over means
                picking yourself, so the exclusions are whoever this pick cannot mean
                for THIS kind of invitation (the sitting owner, the sitting team). }}
            <UserChooser
              @value={{this.inviteeUsername}}
              @onChange={{this.pickInvitee}}
              @options={{hash
                excludedUsernames=@model.excludedUsernames
                filterIcon="magnifying-glass"
                filterPlaceholder="collections.invite.placeholder"
                maximum=1
              }}
            />

            {{#if this.error}}
              <p class="collection-invite__error">{{this.error}}</p>
            {{/if}}
          {{/if}}
        </div>
      </:body>

      <:footer>
        {{#if this.finished}}
          <button
            type="button"
            class="btn btn-primary collection-invite__close"
            {{on "click" this.close}}
          >
            {{i18n "collections.invite.close"}}
          </button>
        {{else}}
          <button
            type="button"
            class="btn collection-invite__cancel"
            {{on "click" this.close}}
          >
            {{i18n "collections.invite.cancel"}}
          </button>
          <button
            type="button"
            class="btn btn-primary collection-invite__submit"
            disabled={{not this.canSubmit}}
            {{on "click" this.submit}}
          >
            {{i18n "collections.invite.submit"}}
          </button>
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
