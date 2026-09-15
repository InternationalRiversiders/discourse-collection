import { array } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";
import { tracked } from "@glimmer/tracking";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DLoadMore from "discourse/ui-kit/d-load-more";
import DModal from "discourse/ui-kit/d-modal";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import CollectionUser from "../collection-user";
import { listTopicSelectedReplies } from "../../lib/collection-api";
import emojiText, { titleText } from "../../lib/emoji-text";

// Full selected-reply list for one collected topic (docs/04 §2 overflow endpoint).
// Opened from a row's "view all selected replies" entry when the inline window
// reported has_more_selected_replies. Paginates post_id ASC beyond that window,
// independent of collection_max_selected_replies_per_topic.
export default class TopicSelectedRepliesModal extends Component {
  @service siteSettings;

  @tracked replies = [];
  @tracked meta = { page: 0, page_size: 30, more: false, total: 0 };
  // uid -> user, the response's `users` map (docs/04 §1), merged across pages so
  // every reply resolves its author without refetching.
  @tracked users = {};
  @tracked loading = false;
  @tracked loadingMore = false;

  #requestSeq = 0;

  get canLoadMore() {
    return this.meta.more && !this.loading && !this.loadingMore;
  }

  // Core's topic route renders /t/:slug/:id with "-" standing in for a missing slug, and
  // the fallback lives here so every caller can hand over topic.slug as it is.
  get slug() {
    return this.args.model.slug || "-";
  }

  // Same lookup the page controller offers its rows, against this modal's own map.
  // @action is load-bearing: a template-called method must be bound.
  @action
  userFor(userId) {
    return userId == null ? null : this.users[userId];
  }

  @action
  close() {
    this.args.closeModal?.();
  }

  @action
  async load() {
    const seq = ++this.#requestSeq;
    this.loading = true;
    try {
      const page = await listTopicSelectedReplies(
        this.args.model.collectionId,
        this.args.model.topicId,
        { page: 0, page_size: this.meta.page_size }
      );
      if (seq !== this.#requestSeq) {
        return;
      }
      this.replies = page.selected_replies;
      this.users = { ...this.users, ...page.users };
      this.meta = page.meta;
    } catch (err) {
      if (seq === this.#requestSeq) {
        popupAjaxError(err);
      }
    } finally {
      if (seq === this.#requestSeq) {
        this.loading = false;
      }
    }
  }

  @action
  async loadMore() {
    if (!this.canLoadMore) {
      return;
    }
    const seq = this.#requestSeq;
    this.loadingMore = true;
    try {
      const page = await listTopicSelectedReplies(
        this.args.model.collectionId,
        this.args.model.topicId,
        { page: this.meta.page + 1, page_size: this.meta.page_size }
      );
      if (seq !== this.#requestSeq) {
        return;
      }
      this.replies = [...this.replies, ...page.selected_replies];
      this.users = { ...this.users, ...page.users };
      this.meta = page.meta;
    } catch (err) {
      if (seq === this.#requestSeq) {
        popupAjaxError(err);
      }
    } finally {
      if (seq === this.#requestSeq) {
        this.loadingMore = false;
      }
    }
  }

  <template>
    <DModal
      @closeModal={{this.close}}
      @title={{i18n "collections.reading.selected_replies"}}
    >
      <:body>
        <div class="topic-selected-replies" {{didInsert this.load}}>
          <p class="topic-selected-replies__topic">
            {{titleText
              this.args.model.title
              this.siteSettings.support_mixed_text_direction
            }}
          </p>

          {{#if this.loading}}
            <DConditionalLoadingSpinner @condition={{this.loading}} />
          {{else if this.replies.length}}
            <DLoadMore
              @action={{this.loadMore}}
              @enabled={{this.canLoadMore}}
              @isLoading={{this.loadingMore}}
            >
              <ul class="topic-selected-replies__list">
                {{#each this.replies as |reply|}}
                  <li class="topic-selected-replies__reply">
                    {{! Sibling of the post link, as in the inline rows: nested, it
                    never reaches core's card handler. }}
                    <CollectionUser
                      class="topic-selected-replies__reply-user"
                      @user={{this.userFor reply.user_id}}
                    />
                    {{! Same post link as the inline rows: topic + post number, via
                    core's :nearPost segment (docs/04 §1). }}
                    <LinkTo
                      class="topic-selected-replies__reply-link"
                      @route="topic.fromParamsNear"
                      @models={{array
                        this.slug
                        this.args.model.topicId
                        reply.post_number
                      }}
                    >
                      <span class="topic-selected-replies__reply-excerpt">
                        {{emojiText reply.excerpt}}
                      </span>
                    </LinkTo>
                  </li>
                {{/each}}
              </ul>
            </DLoadMore>
            {{#if this.loadingMore}}
              <DConditionalLoadingSpinner @condition={{this.loadingMore}} />
            {{/if}}
          {{else}}
            <p class="topic-selected-replies__empty">
              {{i18n "collections.reading.selected_replies_empty"}}
            </p>
          {{/if}}
        </div>
      </:body>
    </DModal>
  </template>
}
