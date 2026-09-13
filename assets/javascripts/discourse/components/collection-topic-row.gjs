import { array, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import CollectionUser from "./collection-user";
import TopicSelectedRepliesModal from "./modal/topic-selected-replies-modal";
import Category from "discourse/models/category";
import dCategoryLink from "discourse/ui-kit/helpers/d-category-link";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dNumber from "discourse/ui-kit/helpers/d-number";
import { i18n } from "discourse-i18n";

// Mirrors CollectionTopic::NOTE_MAX_LENGTH — the note column's own limit.
const NOTE_MAX_LENGTH = 100;

// One collected-topic row on the reading page (docs/04 §1): the topic link, its
// post count and add time, then the optional public note and up to
// collection_max_selected_replies_per_topic inline selected replies. Rows with
// has_more_selected_replies=true get a "view all" entry that opens the overflow
// pager modal.
//
// Management entries render for a maintainer; their writes go through the
// page controller, which owns the feed, so this row holds only the note editor's
// own open/draft state.
export default class CollectionTopicRow extends Component {
  @service modal;

  @tracked editingNote = false;
  @tracked noteDraft = "";
  @tracked savingNote = false;

  get canEditNote() {
    return this.args.controller.canEditNote;
  }

  get canManageContent() {
    return this.args.controller.canManageContent;
  }

  get hasSelectedReplies() {
    return (this.args.row.selected_replies?.length ?? 0) > 0;
  }

  get pending() {
    return this.args.controller.pendingTopicId === this.args.row.topic.id;
  }

  // Core's topic route renders /t/:slug/:id with "-" standing in for a missing
  // slug (same convention as reviewable-topic-link.gjs).
  get topicSlug() {
    return this.args.row.topic.slug || "-";
  }

  // The badge core's topic list draws for a topic's category. The wire carries only
  // category_id, and Category.findById is exactly how core's own Topic model turns
  // that id into the badge object — the badge itself (colors, parent, the
  // uncategorized suppression) is core's.
  //
  // A null category_id is a real state, not a missing field: core nulls it when a
  // topic is converted to a personal message (TopicConverter). Saying so here keeps
  // "no category, no badge" our decision rather than a by-product of core's falsy
  // check — the template drops the whole category block when this is empty.
  get category() {
    const categoryId = this.args.row.topic.category_id;
    return categoryId ? Category.findById(categoryId) : undefined;
  }

  // @action because a template-called method must be bound, and this build's parser
  // rejects writing the call on a named argument.
  @action
  userFor(userId) {
    return this.args.controller.userFor(userId);
  }

  @action
  viewAllReplies() {
    this.modal.show(TopicSelectedRepliesModal, {
      model: {
        collectionId: this.args.collection.id,
        topicId: this.args.row.topic.id,
        slug: this.topicSlug,
        title: this.args.row.topic.fancy_title,
      },
    });
  }

  // The editor opens on the stored note, so an emptied box saves "" and the server
  // stores nil: blank is the clear gesture, not a lost note.
  @action
  startNoteEdit() {
    this.noteDraft = this.args.row.note ?? "";
    this.editingNote = true;
  }

  @action
  updateNoteDraft(event) {
    this.noteDraft = event.target.value;
  }

  @action
  cancelNoteEdit() {
    this.editingNote = false;
  }

  @action
  async saveNote() {
    this.savingNote = true;
    try {
      const saved = await this.args.controller.saveTopicNote(
        this.args.row,
        this.noteDraft
      );
      if (saved && !this.isDestroyed) {
        this.editingNote = false;
      }
    } finally {
      if (!this.isDestroyed) {
        this.savingNote = false;
      }
    }
  }

  @action
  async removeTopic() {
    await this.args.controller.removeTopic(this.args.row);
  }

  @action
  async unfeature(reply) {
    await this.args.controller.unfeatureReply(this.args.row, reply);
  }

  <template>
    <article class="collection-topic">
      <div class="collection-topic__heading">
        {{! The same marker core's topic list draws for an unlisted topic
        (components/topic-status.gjs). The wire only hands this row to a visitor who
        may list unlisted topics (staff / TL4), so the conditional key decides alone.
        Core's help string ends with the visibility reason, which this payload does
        not carry — passed empty so interpolation resolves. }}
        {{#if this.args.row.topic.unlisted}}
          <span
            class="topic-status --invisible"
            title={{i18n "topic_statuses.unlisted.help" unlistedReason=""}}
          >{{dIcon "far-eye-slash"}}</span>
        {{/if}}
        <LinkTo
          class="collection-topic__title"
          @route="topic"
          @models={{array this.topicSlug this.args.row.topic.id}}
        >
          {{trustHTML this.args.row.topic.fancy_title}}
        </LinkTo>

        {{#if this.category}}
          <span class="collection-topic__category">
            {{dCategoryLink this.category}}
          </span>
        {{/if}}

        <CollectionUser
          class="collection-topic__author"
          @user={{this.userFor this.args.row.topic.user_id}}
        />

        <span class="collection-topic__meta">
          <span class="collection-topic__posts">
            {{dIcon "comment"}}
            {{dNumber this.args.row.topic.posts_count}}
          </span>
          <span class="collection-topic__added">
            {{i18n "collections.reading.added"}}
            {{dFormatDate
              this.args.row.added_at
              format="medium"
              leaveAgo="true"
            }}
          </span>
        </span>

        {{! Management entries: this page never adds, since collecting and
        featuring stay on the post action bar. Each button carries its own
        gate — maintaining the collection unlocks both, staff alone unlock the note. }}
        {{#if this.canEditNote}}
          <span class="collection-topic__actions">
            <button
              type="button"
              class="btn btn-small collection-topic__edit-note"
              disabled={{this.pending}}
              {{on "click" this.startNoteEdit}}
            >
              {{dIcon "pencil"}}
              {{i18n "collections.reading.edit_note"}}
            </button>
            {{#if this.canManageContent}}
              <button
                type="button"
                class="btn btn-small btn-danger collection-topic__remove"
                disabled={{this.pending}}
                {{on "click" this.removeTopic}}
              >
                {{dIcon "trash-can"}}
                {{i18n "collections.topic.uncollect"}}
              </button>
            {{/if}}
          </span>
        {{/if}}
      </div>

      {{! The excerpt is the topic's own lead text, so it reads and clicks as a second
      way into the topic rather than dead copy. }}
      {{#if this.args.row.topic.excerpt}}
        <LinkTo
          class="collection-topic__excerpt"
          @route="topic"
          @models={{array this.topicSlug this.args.row.topic.id}}
        >
          {{this.args.row.topic.excerpt}}
        </LinkTo>
      {{/if}}

      {{#if this.editingNote}}
        <div class="collection-topic__note-editor">
          <textarea
            class="collection-topic__note-input"
            rows="2"
            maxlength={{NOTE_MAX_LENGTH}}
            placeholder={{i18n "collections.reading.note_placeholder"}}
            value={{this.noteDraft}}
            {{on "input" this.updateNoteDraft}}
          ></textarea>
          <div class="collection-topic__note-buttons">
            <button
              type="button"
              class="btn btn-small btn-primary collection-topic__note-save"
              disabled={{this.savingNote}}
              {{on "click" this.saveNote}}
            >
              {{i18n "collections.reading.save_note"}}
            </button>
            <button
              type="button"
              class="btn btn-small collection-topic__note-cancel"
              disabled={{this.savingNote}}
              {{on "click" this.cancelNoteEdit}}
            >
              {{i18n "collections.reading.cancel_note"}}
            </button>
          </div>
        </div>
      {{else if this.args.row.note}}
        <p class="collection-topic__note">
          <span class="collection-topic__note-label">
            {{i18n "collections.reading.note_label"}}
          </span>
          {{this.args.row.note}}
        </p>
      {{/if}}

      {{#if this.hasSelectedReplies}}
        <div class="collection-topic__selected">
          <p class="collection-topic__selected-label">
            {{i18n "collections.reading.selected_replies"}}
          </p>
          <ul class="collection-topic__reply-list">
            {{#each this.args.row.selected_replies as |reply|}}
              <li class="collection-topic__reply">
                {{! Sibling of the post link, not a child of it: nested, the router takes
                the click before core's card handler sees it. }}
                <CollectionUser
                  class="collection-topic__reply-user"
                  @user={{this.userFor reply.user_id}}
                />
                {{! Straight to the post inside its topic (core's :nearPost segment),
                not /p/:id — the latter costs a second transition to land on the same
                post. }}
                <LinkTo
                  class="collection-topic__reply-link"
                  @route="topic.fromParamsNear"
                  @models={{array
                    this.topicSlug
                    this.args.row.topic.id
                    reply.post_number
                  }}
                >
                  <span class="collection-topic__reply-excerpt">
                    {{reply.excerpt}}
                  </span>
                </LinkTo>
                {{#if this.canManageContent}}
                  <button
                    type="button"
                    class="btn btn-small btn-danger collection-topic__unfeature"
                    disabled={{this.pending}}
                    {{on "click" (fn this.unfeature reply)}}
                  >
                    {{i18n "collections.topic.unfeature"}}
                  </button>
                {{/if}}
              </li>
            {{/each}}
          </ul>

          {{#if this.args.row.has_more_selected_replies}}
            <button
              type="button"
              class="collection-topic__view-all"
              {{on "click" this.viewAllReplies}}
            >
              {{dIcon "chevron-down"}}
              {{i18n "collections.reading.view_all_replies"}}
            </button>
          {{/if}}
        </div>
      {{/if}}
    </article>
  </template>
}
