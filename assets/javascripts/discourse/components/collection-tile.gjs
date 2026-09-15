import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import getURL from "discourse/lib/get-url";
import { wantsNewWindow } from "discourse/lib/intercept-click";
import DUserLink from "discourse/ui-kit/d-user-link";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dNumber from "discourse/ui-kit/helpers/d-number";
import { i18n } from "discourse-i18n";
import emojiText from "../lib/emoji-text";

export default class CollectionTile extends Component {
  @service currentUser;
  @service router;

  get collection() {
    return this.args.collection;
  }

  // The tile is a plain anchor, not a LinkTo, so it needs its own href.
  get href() {
    return getURL(`/collections/${this.collection.id}`);
  }

  // The currentUser guard matters here as much as it does on the detail page: a guest
  // looking at an UNCLAIMED collection would otherwise compare undefined with
  // undefined and be handed the owner chip.
  get isOwner() {
    return !!this.currentUser && this.collection.owner?.id === this.currentUser.id;
  }

  get roleLabel() {
    if (this.isOwner) {
      return i18n("collections.owner_badge");
    }
    if (this.collection.is_teamworker) {
      return i18n("collections.teamworker_badge");
    }
    return null;
  }

  get roleClass() {
    return this.isOwner ? "-owner" : "-teamworker";
  }

  // A LinkTo here would preventDefault and transition on any simple click bubbling
  // through it, swallowing the owner link nested below — core's card handler skips a
  // click someone else already handled. So the tile navigates itself.
  //
  // A caller that holds the tile inside a layer of its own (a modal, say) passes
  // @onNavigate to take that layer down before the route changes; the early returns
  // above never fire it, so a new tab or a user card leaves that layer alone.
  @action
  openCollection(event) {
    // Modified clicks and the card trigger are not ours to answer: the browser follows
    // the href, and core's card handler takes the trigger.
    if (wantsNewWindow(event) || event.target.closest("[data-user-card]")) {
      return;
    }

    event.preventDefault();
    this.args.onNavigate?.();
    this.router.transitionTo("collectionsShow", this.collection.id);
  }

  <template>
    <a
      class="collection-tile"
      href={{this.href}}
      {{on "click" this.openCollection}}
    >
      <header class="collection-tile__header">
        <h2 class="collection-tile__name">{{emojiText this.collection.name}}</h2>
        {{#if this.roleLabel}}
          <span class="collection-tile__role {{this.roleClass}}">
            {{this.roleLabel}}
          </span>
        {{/if}}
      </header>

      {{#if this.collection.description}}
        <p class="collection-tile__description">
          {{emojiText this.collection.description}}
        </p>
      {{/if}}

      <div class="collection-tile__owner">
        {{#if this.collection.owner}}
          <DUserLink
            class="collection-tile__owner-link"
            @user={{this.collection.owner}}
          >
            {{dAvatar this.collection.owner imageSize="tiny" hideTitle=true}}
            <span class="collection-tile__owner-name">
              {{this.collection.owner.username}}
            </span>
          </DUserLink>
        {{else}}
          <span class="collection-tile__owner-name -unclaimed">
            {{i18n "collections.no_owner"}}
          </span>
        {{/if}}
      </div>

      <div class="collection-tile__stats">
        <span
          class="collection-tile__stat"
          title={{i18n "collections.stats.topic_count"}}
        >
          {{dIcon "layer-group"}}
          {{dNumber this.collection.topic_count}}
        </span>
        <span
          class="collection-tile__stat"
          title={{i18n "collections.stats.subscriber_count"}}
        >
          {{dIcon "bookmark"}}
          {{dNumber this.collection.subscriber_count}}
        </span>
        <span
          class="collection-tile__stat"
          title={{i18n "collections.stats.teamworker_count"}}
        >
          {{dIcon "user-group"}}
          {{dNumber this.collection.teamworker_count}}
        </span>
      </div>

      <footer class="collection-tile__footer">
        <span class="collection-tile__activity">
          {{dIcon "clock"}}
          {{i18n "collections.tile.created_at"}}
          {{dFormatDate
            this.collection.created_at
            format="medium"
            leaveAgo="true"
          }}
        </span>
        {{#if this.collection.last_topic_added_at}}
          <span class="collection-tile__activity">
            {{dIcon "clock"}}
            {{i18n "collections.tile.last_topic_added_at"}}
            {{dFormatDate
              this.collection.last_topic_added_at
              format="medium"
              leaveAgo="true"
            }}
          </span>
        {{else}}
          <span class="collection-tile__activity -none">
            {{i18n "collections.no_topics_yet"}}
          </span>
        {{/if}}
      </footer>
    </a>
  </template>
}
