import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { getCollection } from "../lib/collection-api";
import { READING_SORT_DEFAULT } from "../lib/reading-sort";

export default class CollectionsShowRoute extends DiscourseRoute {
  @service currentUser;
  @service router;
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
      topicsOrder: "desc",
      topicsSort: READING_SORT_DEFAULT,
      loadingTopics: false,
      loadingMoreTopics: false,
    });
    controller.loadTopics();
    controller.loadInvites();
  }
}
