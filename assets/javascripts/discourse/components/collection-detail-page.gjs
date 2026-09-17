import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { LinkTo } from "@ember/routing";
import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import CollectionChips from "./collection-chips";
import CollectionInviteRecords from "./collection-invite-records";
import CollectionTopics from "./collection-topics";
import CollectionUser from "./collection-user";
import CollectionFormModal from "./modal/collection-form-modal";
import CollectionInviteModal from "./modal/collection-invite-modal";
import CollectionSubscribersModal from "./modal/collection-subscribers-modal";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dNumber from "discourse/ui-kit/helpers/d-number";
import { and, eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { INVITE_MAINTAINER, INVITE_OWNER } from "../lib/collection-api";
import emojiText from "../lib/emoji-text";

export default class CollectionDetailPage extends Component {
  @service currentUser;
  @service modal;

  // A guest has no id, and reading one off a missing currentUser is not a thing a
  // template should do — the row comparison below reads this instead.
  get currentUserId() {
    return this.currentUser?.id ?? null;
  }

  get showActions() {
    return (
      this.args.controller.canSubscribe ||
      this.args.controller.canManageMetadata ||
      this.args.controller.canDeleteCollection
    );
  }

  // An unclaimed collection with nobody on the team has no roster to show.
  get showTeam() {
    return (
      !!this.args.controller.owner ||
      this.args.controller.teamworkers.length > 0
    );
  }

  get subscribeIcon() {
    return this.args.controller.isSubscribed ? "bell-slash" : "bell";
  }

  get subscribeLabel() {
    if (this.args.controller.isSubscribed) {
      return i18n("collections.detail.unsubscribe");
    }
    return i18n("collections.detail.subscribe");
  }

  // Who the roster is open to is the controller's call (docs/02 §5): a list of users stays
  // closed even where the collection itself is public, and the site setting may close it
  // further. What is left here is the empty case — a list with nobody on it has nothing to
  // open, so the entry appears only once there is a subscriber behind the count. Everyone
  // else keeps the count alone, which is part of the collection itself.
  get canViewSubscribers() {
    return (
      this.args.controller.canViewSubscribers &&
      this.args.controller.subscriberCount > 0
    );
  }

  // The owner's other collections (docs/03 §4): the heading names whose list this is, and
  // the trailing action reads "Details" when the server held nothing back — either way it
  // opens the full list, which is where the richer tiles are.
  get ownerCollectionsHeading() {
    return i18n("collections.owner_collections.heading", {
      username: this.args.controller.owner?.username,
    });
  }

  get ownerCollectionsButtonLabel() {
    if (this.args.controller.hasMoreOwnerCollections) {
      return i18n("collections.owner_collections.more");
    }
    return i18n("collections.owner_collections.details");
  }

  // docs/05 §1 — the modal writes and hands the full shape back to the controller, which
  // mirrors the two fields the page renders.
  @action
  editMetadata() {
    this.modal.show(CollectionFormModal, {
      model: {
        mode: "edit",
        id: this.args.collection.id,
        name: this.args.controller.collectionName,
        description: this.args.controller.collectionDescription,
        onSaved: this.args.controller.applyMetadata,
      },
    });
  }

  @action
  inviteMaintainer() {
    // Both the owner and the sitting co-maintainers already hold the role, so the
    // chooser leaves them out rather than letting the pick end in a 422.
    const owner = this.args.controller.owner;
    this.modal.show(CollectionInviteModal, {
      model: {
        collectionId: this.args.collection.id,
        actionType: INVITE_MAINTAINER,
        excludedUsernames: [
          owner?.username,
          ...this.args.controller.teamworkers.map((user) => user.username),
        ].filter(Boolean),
        onSent: this.args.controller.loadInvites,
      },
    });
  }

  @action
  inviteOwner() {
    // The sitting owner already holds the role, so picking them is a transfer to
    // themselves — a no-op on accept, since the same row is demoted and promoted back.
    // Staff open this on collections they do not own, so the owner — not the viewer —
    // is the one to leave out; everyone else, the viewer included, stays eligible: for
    // staff picking themselves is a takeover that lands on the spot (docs/05 §2.7).
    const owner = this.args.controller.owner;
    this.modal.show(CollectionInviteModal, {
      model: {
        collectionId: this.args.collection.id,
        actionType: INVITE_OWNER,
        excludedUsernames: [owner?.username].filter(Boolean),
        onSent: this.args.controller.loadInvites,
        onTakenOver: this.args.controller.applyOwnership,
      },
    });
  }

  // The roster is its own fetch: the page never carries the list itself, only the count.
  @action
  viewSubscribers() {
    this.modal.show(CollectionSubscribersModal, {
      model: { collectionId: this.args.collection.id },
    });
  }

  <template>
    <section class="collection-detail">
      <div class="container">
        <nav class="collection-detail__nav">
          <LinkTo class="collection-detail__back" @route="collections">
            {{dIcon "chevron-left"}}
            {{i18n "collections.detail.back"}}
          </LinkTo>
        </nav>

        <header class="collection-detail__header">
          <div class="collection-detail__heading">
            <h1 class="collection-detail__name">{{emojiText @controller.collectionName}}</h1>
            {{#if @controller.roleLabel}}
              <span class="collection-detail__role {{@controller.roleClass}}">
                {{@controller.roleLabel}}
              </span>
            {{/if}}
          </div>

          {{#if @controller.owner}}
            <div class="collection-detail__owner">
              <CollectionUser
                class="collection-user-link"
                @hideTitle={{true}}
                @user={{@controller.owner}}
              />
            </div>
          {{else}}
            <p class="collection-detail__owner -unclaimed">
              {{i18n "collections.no_owner"}}
            </p>
          {{/if}}

          {{#if @controller.collectionDescription}}
            <p class="collection-detail__description">
              {{emojiText @controller.collectionDescription}}
            </p>
          {{/if}}

          <dl class="collection-detail__stats">
            <div class="collection-detail__stat">
              <dt>{{i18n "collections.stats.topic_count"}}</dt>
              <dd>{{dNumber @controller.topicCount}}</dd>
            </div>
            <div class="collection-detail__stat">
              <dt>{{i18n "collections.stats.subscriber_count"}}</dt>
              <dd>{{dNumber @controller.subscriberCount}}</dd>
            </div>
            <div class="collection-detail__stat">
              <dt>{{i18n "collections.detail.created"}}</dt>
              <dd>
                {{dFormatDate
                  @collection.created_at
                  format="medium"
                  leaveAgo="true"
                }}
              </dd>
            </div>
            {{#if @controller.lastTopicAddedAt}}
              <div class="collection-detail__stat">
                <dt>{{i18n "collections.detail.last_activity"}}</dt>
                <dd>
                  {{dFormatDate
                    @controller.lastTopicAddedAt
                    format="medium"
                    leaveAgo="true"
                  }}
                </dd>
              </div>
            {{/if}}
          </dl>
        </header>

        {{#if this.showActions}}
          <div class="collection-detail__actions">
            {{#if @controller.canSubscribe}}
              <button
                type="button"
                class="btn btn-primary collection-detail__subscribe"
                disabled={{@controller.toggling}}
                {{on "click" @controller.toggleSubscription}}
              >
                {{dIcon this.subscribeIcon}}
                {{this.subscribeLabel}}
              </button>
            {{/if}}

            {{#if this.canViewSubscribers}}
              <button
                type="button"
                class="btn collection-detail__subscribers"
                {{on "click" this.viewSubscribers}}
              >
                {{dIcon "bookmark"}}
                {{i18n "collections.detail.view_subscribers"}}
              </button>
            {{/if}}

            {{#if @controller.canManageMetadata}}
              <button
                type="button"
                class="btn collection-detail__edit"
                {{on "click" this.editMetadata}}
              >
                {{dIcon "pencil"}}
                {{i18n "collections.detail.edit"}}
              </button>
            {{/if}}

            {{#if @controller.canInviteMaintainer}}
              <button
                type="button"
                class="btn collection-detail__invite-maintainer"
                {{on "click" this.inviteMaintainer}}
              >
                {{dIcon "user-plus"}}
                {{i18n "collections.team.invite_maintainer"}}
              </button>
            {{/if}}

            {{#if @controller.canInviteOwner}}
              <button
                type="button"
                class="btn collection-detail__invite-owner"
                {{on "click" this.inviteOwner}}
              >
                {{dIcon "user-shield"}}
                {{i18n "collections.team.invite_owner"}}
              </button>
            {{/if}}

            {{#if @controller.canDeleteCollection}}
              <button
                type="button"
                class="btn btn-danger collection-detail__delete"
                disabled={{@controller.deleting}}
                {{on "click" @controller.destroyCollection}}
              >
                {{dIcon "trash-can"}}
                {{i18n "collections.detail.delete"}}
              </button>
            {{/if}}
          </div>
        {{/if}}

        {{! The owner's other collections (docs/03 §4), right under the action row. Nothing
        renders for an ownerless collection or an owner whose only collection is this one. }}
        {{#if @controller.ownerCollections.length}}
          <section class="collection-detail__owner-collections">
            <h2 class="collection-detail__subheading">
              {{this.ownerCollectionsHeading}}
            </h2>

            <CollectionChips @collections={{@controller.ownerCollections}}>
              <button
                type="button"
                class="collection-chips__chip btn btn-primary"
                {{on "click" @controller.openOwnerCollections}}
              >
                {{this.ownerCollectionsButtonLabel}}
              </button>
            </CollectionChips>
          </section>
        {{/if}}

        {{#if this.showTeam}}
          <section class="collection-detail__team">
            <h2 class="collection-detail__subheading">
              {{i18n "collections.detail.team"}}
            </h2>
            <ul class="collection-detail__team-list">
              {{#if @controller.owner}}
                <li class="collection-detail__team-member -owner">
                  <CollectionUser
                    class="collection-user-link"
                    @hideTitle={{true}}
                    @user={{@controller.owner}}
                  />
                  <span class="collection-detail__team-badge">
                    {{i18n "collections.owner_badge"}}
                  </span>
                </li>
              {{/if}}

              {{#each @controller.teamworkers as |maintainer|}}
                <li
                  class="collection-detail__team-member"
                  data-username={{maintainer.username}}
                >
                  <CollectionUser
                    class="collection-user-link"
                    @hideTitle={{true}}
                    @user={{maintainer}}
                  />
                  <span class="collection-detail__team-badge">
                    {{i18n "collections.teamworker_badge"}}
                  </span>

                  {{#if @controller.canManageMaintainers}}
                    <button
                      type="button"
                      class="btn btn-danger btn-small collection-detail__team-action"
                      disabled={{eq
                        @controller.pendingMaintainerId
                        maintainer.id
                      }}
                      {{on
                        "click"
                        (fn @controller.removeMaintainer maintainer)
                      }}
                    >
                      {{i18n "collections.team.remove"}}
                    </button>
                  {{else if
                    (and
                      @controller.canLeaveCollection
                      (eq maintainer.id this.currentUserId)
                    )
                  }}
                    <button
                      type="button"
                      class="btn btn-danger btn-small collection-detail__team-action"
                      disabled={{eq
                        @controller.pendingMaintainerId
                        maintainer.id
                      }}
                      {{on "click" @controller.leaveCollection}}
                    >
                      {{i18n "collections.team.leave"}}
                    </button>
                  {{/if}}
                </li>
              {{/each}}
            </ul>
          </section>
        {{/if}}

        {{#if @controller.showInviteRecords}}
          <CollectionInviteRecords @controller={{@controller}} />
        {{/if}}

        <CollectionTopics @collection={{@collection}} @controller={{@controller}} />
      </div>
    </section>
  </template>
}
