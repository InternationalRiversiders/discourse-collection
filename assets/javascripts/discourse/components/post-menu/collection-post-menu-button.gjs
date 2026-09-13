import { action } from "@ember/object";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import DButton from "discourse/ui-kit/d-button";
import AddToCollectionModal from "../modal/add-to-collection-modal";

/**
 * Post action bar entry for collections (docs/07). Every post carries it: on
 * the first post it manages the topic's membership, on a reply it manages that
 * reply's featured state. The button owns the in-place model updates so the chips
 * under the posts react without refetching the topic.
 */
export default class CollectionPostMenuButton extends Component {
  // The action bar keeps this behind the "more" toggle instead of the visible row.
  static hidden = true;

  static shouldRender(args, context) {
    const post = args.post;
    const topic = post?.topic;

    if (!context.siteSettings.collection_enabled || !context.currentUser) {
      return false;
    }

    // Private messages and non-regular posts (small action, whisper) are rejected
    // by the write endpoints, so the entry could only ever produce an error.
    return Boolean(
      topic &&
        !topic.isPrivateMessage &&
        post.post_type === context.site.post_types.regular
    );
  }

  @service modal;

  get #isFirstPost() {
    return this.#post?.post_number === 1;
  }

  get #post() {
    return this.args.post;
  }

  get #postSelectedIds() {
    return this.#post?.selected_by_collection_ids ?? [];
  }

  get #topic() {
    return this.#post?.topic;
  }

  get #topicCollections() {
    return this.#topic?.collections ?? [];
  }

  @action
  openManager() {
    if (!this.#topic) {
      return;
    }

    const shared = {
      topicId: this.#topic.id,
      title: this.#topic.fancy_title,
      collectedIds: this.#topicCollections.map((collection) => collection.id),
    };

    const model = this.#isFirstPost
      ? {
          ...shared,
          mode: "topic",
          onCollect: (collection) => this.#addToTopic(collection),
          onUncollect: (collectionId) => this.#removeFromTopic(collectionId),
        }
      : {
          ...shared,
          mode: "post",
          postId: this.#post.id,
          selectedIds: this.#postSelectedIds,
          onFeature: (collectionId) => this.#featureReply(collectionId, true),
          onUnfeature: (collectionId) => this.#featureReply(collectionId, false),
        };

    this.modal.show(AddToCollectionModal, { model });
  }

  // `collections` is a registered tracked array, so reassigning it re-renders the
  // chips in place (initializers/collection-topic.js).
  #addToTopic(collection) {
    if (this.#topicCollections.some((held) => held.id === collection.id)) {
      return;
    }

    this.#topic.collections = [
      ...this.#topicCollections,
      { id: collection.id, name: collection.name },
    ];
  }

  #featureReply(collectionId, selected) {
    const ids = this.#postSelectedIds;

    this.#post.selected_by_collection_ids = selected
      ? [...new Set([...ids, collectionId])]
      : ids.filter((id) => id !== collectionId);
  }

  #removeFromTopic(collectionId) {
    this.#topic.collections = this.#topicCollections.filter(
      (held) => held.id !== collectionId
    );

    // Un-collecting drops every selected reply of this topic server-side, so the
    // featured chips have to go from the loaded posts too (docs/04 §5).
    for (const post of this.#topic.postStream?.posts ?? []) {
      const ids = post.selected_by_collection_ids ?? [];

      if (ids.includes(collectionId)) {
        post.selected_by_collection_ids = ids.filter(
          (id) => id !== collectionId
        );
      }
    }
  }

  <template>
    <DButton
      class="post-action-menu__collection"
      ...attributes
      @action={{this.openManager}}
      @ariaLabel="collections.topic.menu_title"
      @icon="collection"
      @title="collections.topic.menu_title"
    />
  </template>
}
