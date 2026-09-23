import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
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

  get activity() {
    const sort = this.args.sort ?? "last_topic_added_at";
    if (sort === "created_at") {
      return {
        at: this.collection.created_at,
        icon: "plus",
        label: i18n("collections.tile.created_at"),
      };
    }
    if (sort === "last_topic_added_at") {
      return {
        at: this.collection.last_topic_added_at,
        icon: "clock",
        label: i18n("collections.tile.last_topic_added_at"),
      };
    }
    return null;
  }

  // The tile is a plain anchor, not a LinkTo, so it needs its own href.
  get href() {
    return getURL(`/collections/${this.collection.id}`);
  }

  // The currentUser guard matters here as much as it does on the detail page: a guest
  // looking at an UNCLAIMED collection would otherwise compare undefined with
  // undefined and be handed the owner chip.
  get isOwner() {
    return (
      !!this.currentUser && this.collection.owner?.id === this.currentUser.id
    );
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
      ...attributes
      {{on "click" this.openCollection}}
    >
      <header class="collection-tile__header">
        <span aria-hidden="true" class="collection-tile__emblem">{{dIcon
            "layer-group"
          }}</span>
        <h2 class="collection-tile__name">{{emojiText
            this.collection.name
          }}</h2>
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

      <footer class="collection-tile__footer">
        <div class="collection-tile__owner">
          {{#if this.collection.owner}}
            <DUserLink
              class="collection-tile__owner-link"
              @user={{this.collection.owner}}
            >
              {{dAvatar this.collection.owner imageSize="tiny" hideTitle=true}}
              <span
                class="collection-tile__owner-name"
                title={{this.collection.owner.username}}
              >
                {{this.collection.owner.username}}
              </span>
            </DUserLink>
          {{else}}
            <span class="collection-tile__owner-name -unclaimed">
              {{i18n "collections.no_owner"}}
            </span>
          {{/if}}
        </div>

        <div class="collection-tile__meta">
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

          {{#if this.activity}}
            <span
              class="collection-tile__activity"
              title={{this.activity.label}}
            >
              {{dIcon this.activity.icon}}
              <span class="sr-only">{{this.activity.label}}</span>
              {{#if this.activity.at}}
                {{dFormatDate this.activity.at format="medium" leaveAgo="true"}}
              {{else}}
                <span>{{i18n "collections.no_topics_yet"}}</span>
              {{/if}}
            </span>
          {{/if}}
        </div>
      </footer>
    </a>
  </template>
}
