import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";
import { i18n } from "discourse-i18n";

// Topic-page reverse lookup (docs/07), rendered inside a post's
// `.post__contents` right under the cooked HTML. Read-only: the first post carries
// the topic level set (the collections holding this topic), every other post carries
// the post level set (the collections featuring that reply), resolved against the
// topic level name table. Acting on either set lives in the post action bar entry.
export default class CollectionTopicChips extends Component {
  static shouldRender(args, context) {
    if (!context.siteSettings.collection_enabled) {
      return false;
    }
    // Guests only ever see the chips when anonymous reading is enabled, matching
    // the sidebar/nav gate.
    return Boolean(
      context.currentUser || context.siteSettings.collection_allow_anonymous
    );
  }

  get post() {
    return this.args.outletArgs.post;
  }

  get topic() {
    return this.post?.topic;
  }

  get isFirstPost() {
    return this.post?.post_number === 1;
  }

  get topicCollections() {
    return this.topic?.collections ?? [];
  }

  get featuredCollections() {
    const ids = this.post?.selected_by_collection_ids;
    if (!ids?.length) {
      return [];
    }
    return ids
      .map((id) =>
        this.topicCollections.find((collection) => collection.id === id)
      )
      .filter(Boolean);
  }

  get showCollectedChips() {
    return this.isFirstPost && this.topicCollections.length > 0;
  }

  get showFeaturedChips() {
    return this.featuredCollections.length > 0;
  }

  <template>
    {{#if this.showCollectedChips}}
      <div class="collection-topic-chips">
        <span class="collection-topic-chips__label">
          {{i18n "collections.topic.collected_in"}}
        </span>
        {{#each this.topicCollections as |collection|}}
          <LinkTo
            class="collection-topic-chips__chip"
            @route="collectionsShow"
            @model={{collection.id}}
          >
            {{collection.name}}
          </LinkTo>
        {{/each}}
      </div>
    {{/if}}

    {{#if this.showFeaturedChips}}
      <div class="collection-topic-chips -featured">
        <span class="collection-topic-chips__label">
          {{i18n "collections.topic.featured_in"}}
        </span>
        {{#each this.featuredCollections as |collection|}}
          <LinkTo
            class="collection-topic-chips__chip"
            @route="collectionsShow"
            @model={{collection.id}}
          >
            {{collection.name}}
          </LinkTo>
        {{/each}}
      </div>
    {{/if}}
  </template>
}
