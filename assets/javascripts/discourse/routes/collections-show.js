import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";
import {
  getCollection,
  markCollectionNotificationsRead,
} from "../lib/collection-api";
import { shouldMarkCollectionNotificationsRead } from "../lib/collection-notifications";
import { READING_SORT_DEFAULT } from "../lib/reading-sort";

export default class CollectionsShowRoute extends DiscourseRoute {
  @service currentUser;
  @service router;
  @service site;
  @service siteSettings;

  beforeModel() {
    // Reading a collection requires the anonymous-read toggle when logged out.
    if (!this.currentUser && !this.siteSettings.collection_allow_anonymous) {
      this.router.replaceWith("collections");
    }
  }

  model(params) {
    return getCollection(params.id);
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.setProperties({
      isSubscribed: model.is_subscribed,
      subscriberCount: model.subscriber_count,
      toggling: false,
      // Header counters are reseeded from the model and then owned by the controller,
      // so removing a collected topic can move them without refetching (docs/04 §5).
      topicCount: model.topic_count,
      lastTopicAddedAt: model.last_topic_added_at,
      // Same for the metadata a name / description edit (docs/05 §1) can rewrite.
      collectionName: model.name,
      avatarUpload: model.avatar_upload ?? null,
      backgroundUpload: model.background_upload ?? null,
      collectionDescription: model.description ?? "",
      deleting: false,
      pendingTopicId: null,
      // The co-maintainer list a removal rewrites, and the owner a takeover
      // replaces (docs/05 §2.7).
      owner: model.owner,
      teamworkers: model.teamworkers,
      pendingMaintainerId: null,
      // The owner's other collections (docs/03 §4) arrive with the model: the page only
      // renders them, the modal fetches the full list itself.
      ownerCollections: model.owner_collections ?? [],
      hasMoreOwnerCollections: model.has_more_owner_collections ?? false,
      // The invitation record (docs/05 §2.3), reseeded per :id like the feed; loadInvites()
      // is a no-op for a viewer who may not read it.
      invites: [],
      invitesMeta: { page: 0, page_size: 30, more: false, total: 0 },
      loadingInvites: false,
      loadingMoreInvites: false,
      pendingInviteId: null,
      // Reseed the reading feed (docs/04 §1) for every :id change, then load page 0.
      // loadTopics() reads this.model.id, so it must run after the reseed.
      topics: [],
      users: {},
      topicsMeta: { page: 0, page_size: 30, more: false, total: 0 },
      defaultTopicOrder: model.default_topic_order ?? "desc",
      defaultTopicSort: model.default_topic_sort ?? READING_SORT_DEFAULT,
      savingReadingDefaults: false,
      topicsOrder: model.default_topic_order ?? "desc",
      topicsSort: model.default_topic_sort ?? READING_SORT_DEFAULT,
      loadingTopics: false,
      loadingMoreTopics: false,
    });
    controller.loadTopics();
    controller.loadInvites();

    // Reaching the collection is what makes its notifications read (docs/09 §1).
    // Fire-and-forget: a refused pass leaves them unread, which is where they started.
    if (shouldMarkCollectionNotificationsRead(this.currentUser, this.site)) {
      void markCollectionNotificationsRead(model.id).catch(() => {});
    }
  }

  // The name comes from the controller rather than the model: an edit (docs/05 §1)
  // replaces the page's copy there, and applyMetadata() re-collects the title from it.
  titleToken() {
    const name =
      this.controllerFor("collectionsShow")?.collectionName ||
      this.modelFor("collectionsShow")?.name;

    if (!name) {
      return;
    }

    return [name, i18n("collections.nav_name")];
  }
}
