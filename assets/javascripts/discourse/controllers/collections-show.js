import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import CollectionOwnerCollectionsModal from "../components/modal/collection-owner-collections-modal";
import RemoveTopicModal from "../components/modal/remove-topic-modal";
import TopicSelectedRepliesModal from "../components/modal/topic-selected-replies-modal";
import {
  countTopicSelectedReplies,
  deleteCollection,
  listCollectionInvites,
  listCollectionTopics,
  removeCollectionMaintainer,
  removeTopicFromCollection,
  revokeCollectionInvite,
  rewriteTopicNote,
  subscribeToCollection,
  unselectReplyFromCollection,
  unsubscribeFromCollection,
  updateCollectionReadingDefaults,
  updateTopicNote,
} from "../lib/collection-api";
import { confirmAction } from "../lib/confirm";
import { inviteRoleName, inviteStatusLabel } from "../lib/invite-labels";
import { READING_SORT_DEFAULT, READING_SORT_FIELDS } from "../lib/reading-sort";
import { canViewSubscriberList } from "../lib/subscriber-visibility";

// How much of the invitation record the collection page itself carries — the rest is
// one click away in CollectionInviteRecordsModal.
const RECENT_INVITE_ROWS = 3;

// Read + subscribe state for the /collections/:id detail page (docs/03 §4
// + the "订阅" section). The route hands over the full-shape model; roles are
// derived against the current user so the page can adapt owner/teamworker/
// visitor/staff rendering without asking the server again.
//
// The page also shows the collection's reading feed (docs/04 §1) below the header. Its
// paging state lives here too; the route reseeds it on every :id change and calls
// loadTopics() for the first page (docs/04 §1 — feed rows only show topic cards,
// never collection metadata).
//
// Content management of that feed (docs/04 §4 / §5 / docs/06 §1) lives here too: the
// controller owns the topics array, so a successful write replaces the affected row
// (removal drops it) and the list never refetches.
export default class CollectionsShowController extends Controller {
  @service currentUser;
  @service dialog;
  @service modal;
  @service router;
  @service siteSettings;

  @tracked isSubscribed = false;
  @tracked subscriberCount = 0;
  @tracked toggling = false;

  // Header counters kept outside the route model so a write can move them: the
  // model object is plain JSON and mutating it would not re-render.
  @tracked topicCount = 0;
  @tracked lastTopicAddedAt = null;

  // The metadata edit (docs/05 §1) writes back the full shape, but only name / description
  // are shown, so they are mirrored here for the same reason as the counters above.
  @tracked collectionName = "";
  @tracked collectionDescription = "";
  @tracked avatarUpload = null;
  @tracked backgroundUpload = null;
  @tracked deleting = false;

  // The team comes off the route model as plain JSON too, so removals are applied
  // to this mirror instead.
  @tracked teamworkers = [];
  @tracked pendingMaintainerId = null;

  // Same for the owner: the role chip, the header line, the team card and every
  // management entry on the page are derived from it, so a takeover (docs/05 §2.7) has to
  // move it here rather than on the unmovable route model.
  @tracked owner = null;

  // The owner's other collections (docs/03 §4), as seeded by the route: a capped list of
  // id + name, plus whether the server held more back. The page renders them as chips and
  // opens the full list in a modal; nothing here refetches or paginates.
  @tracked ownerCollections = [];
  @tracked hasMoreOwnerCollections = false;

  // The invitation record (docs/05 §2.3) the owner or a staff manager reads below the team
  // card; a revoke drops its row.
  @tracked invites = [];
  @tracked invitesMeta = { page: 0, page_size: 30, more: false, total: 0 };
  @tracked loadingInvites = false;
  @tracked loadingMoreInvites = false;
  @tracked pendingInviteId = null;

  @tracked topics = [];
  @tracked topicsMeta = { page: 0, page_size: 30, more: false, total: 0 };
  @tracked defaultTopicOrder = "desc";
  @tracked defaultTopicSort = READING_SORT_DEFAULT;
  @tracked savingReadingDefaults = false;
  @tracked topicsOrder = "desc";
  @tracked topicsSort = READING_SORT_DEFAULT;
  // uid -> user, the feed's author source (the responses' top-level `users` map,
  // docs/04 §1), merged as pages and replaced rows arrive. Rows reference authors by
  // id only, so this is what the avatar and username are read from.
  @tracked users = {};
  @tracked loadingTopics = false;
  @tracked loadingMoreTopics = false;

  // Topic id of the row whose write is in flight; that row's buttons lock while the
  // rest of the feed stays usable.
  @tracked pendingTopicId = null;

  // Bumped on every (re)load; responses with a stale sequence are dropped so an
  // order toggle or a route change never lets an older request overwrite newer data.
  #topicsRequestSeq = 0;

  // The currentUser guard matters: without it a guest viewing an UNCLAIMED collection
  // compares undefined with undefined and reads as the owner — which would hand a guest
  // the owner-only entries (delete among them).
  get isOwner() {
    return !!this.currentUser && this.owner?.id === this.currentUser.id;
  }

  get isTeamworker() {
    return this.teamworkers.some((user) => user.id === this.currentUser?.id);
  }

  // The chip names the viewer's relation to THIS collection, so the two membership
  // roles are the only ones it ever states. Everyone else — guests, and staff
  // holding no role here — gets no chip at all: whether they may manage this
  // collection shows up as the buttons themselves, never as a badge.
  get roleLabel() {
    if (this.isOwner) {
      return i18n("collections.owner_badge");
    }
    if (this.isTeamworker) {
      return i18n("collections.teamworker_badge");
    }
    return null;
  }

  get roleClass() {
    if (this.isOwner) {
      return "-owner";
    }
    if (this.isTeamworker) {
      return "-teamworker";
    }
    return null;
  }

  // Owner auto-subscribes on creation but may opt out and back in (docs/02 §5),
  // so every logged-in viewer can toggle; only guests cannot.
  get canSubscribe() {
    return !!this.currentUser;
  }

  get canEditNote() {
    return this.canManageContent || this.canRewriteNote;
  }

  // Removing / unfeaturing / editing a note is owner-or-co-maintainer only — staff
  // get no bypass here (docs/06 §2). The server re-checks; this picks the rendering.
  get canManageContent() {
    return this.isOwner || this.isTeamworker;
  }

  // Rewriting a note is the one staff write on someone else's collection: admin and
  // moderator both always hold it, with no setting gate (docs/06 §1).
  get canRewriteNote() {
    return !!this.currentUser?.staff;
  }

  // Collection-level management (docs/05 §1 rename / description; the ownership invite joins
  // it) works on ANY collection — someone else's, or an unclaimed one. Admin
  // always; moderator only when the site setting allows it. Mirrors
  // CollectionPolicy#can_manage_collection?, which is narrower than canRewriteNote
  // above on purpose (docs/02 §1 / docs/06 §2).
  get canManageCollectionAsStaff() {
    const user = this.currentUser;
    if (!user) {
      return false;
    }
    return (
      !!user.admin ||
      (!!user.moderator &&
        this.siteSettings.collection_moderators_can_manage_collections)
    );
  }

  get canManageAppearance() {
    return this.canManageContent || this.canManageCollectionAsStaff;
  }

  get canManageMetadata() {
    return this.isOwner || this.canManageCollectionAsStaff;
  }

  // Deleting is owner-only: the management role covers metadata and ownership, never
  // destruction (docs/06 §2).
  get canDeleteCollection() {
    return this.isOwner;
  }

  // Team (docs/02 §3 / docs/05 §2.1 / docs/06 §2): the owner removes any co-maintainer, a
  // co-maintainer removes only themselves (leaving), and staff hold neither.
  get canManageMaintainers() {
    return this.isOwner;
  }

  get canLeaveCollection() {
    return this.isTeamworker;
  }

  // Inviting a co-maintainer needs a sitting owner to invite, so it is owner-only.
  // An ownership invite is the owner's self-transfer, or a staff management op —
  // which on an unclaimed collection is how it gets its first owner.
  get canInviteMaintainer() {
    return this.isOwner;
  }

  get canInviteOwner() {
    return this.isOwner || this.canManageCollectionAsStaff;
  }

  // Who may open the roster (docs/02 §5): the site setting names the minimum role, and both
  // the setting and the viewer's roles on this collection are already on the page. The
  // server re-checks; this only picks the rendering. The count is a separate matter the
  // entry adds on top of it.
  get canViewSubscribers() {
    return canViewSubscriberList({
      setting: this.siteSettings.collection_subscribers_visibility,
      user: this.currentUser,
      isOwner: this.isOwner,
      isTeamworker: this.isTeamworker,
    });
  }

  // The viewer's own id, for "did I issue this invitation" — a guest has none, and
  // comparing against a missing currentUser is not a thing a template should do.
  get currentUserId() {
    return this.currentUser?.id ?? null;
  }

  // The invitation record belongs to whoever runs the collection: its owner, and
  // staff holding the management role (docs/05 §2.3). The invitee reads their own
  // rows in the inbox instead, so nothing renders for anyone else.
  get canManageInvites() {
    return this.isOwner || this.canManageCollectionAsStaff;
  }

  get showInviteRecords() {
    return this.canManageInvites && this.invites.length > 0;
  }

  // The page carries the three most recent rows and nothing more; "there is more" is
  // asked of the server's total rather than of what happens to be loaded, so the
  // preview never claims the record ends where the first response did.
  get recentInviteRows() {
    return this.inviteRows.slice(0, RECENT_INVITE_ROWS);
  }

  get hasMoreInvites() {
    return this.invitesMeta.total > RECENT_INVITE_ROWS;
  }

  // One recorded invitation, worded for the manager's side: who asked whom for what
  // (never "you"), and where it stands.
  get inviteRows() {
    return this.invites.map((invite) => ({
      invite,
      statusLabel: inviteStatusLabel(invite.status),
      roleName: inviteRoleName(invite.action_type),
      inviter: invite.inviter,
      invitee: invite.invitee,
      canRevoke: this.#canRevokeInvite(invite),
      busy: this.pendingInviteId === invite.id,
    }));
  }

  get canLoadMoreInvites() {
    return (
      this.invitesMeta.more && !this.loadingInvites && !this.loadingMoreInvites
    );
  }

  get canLoadMoreTopics() {
    return (
      this.topicsMeta.more && !this.loadingTopics && !this.loadingMoreTopics
    );
  }

  get canManageReadingDefaults() {
    return this.canManageContent || this.canManageCollectionAsStaff;
  }

  get isDefaultTopicsSort() {
    return (
      this.topicsSort === this.defaultTopicSort &&
      this.topicsOrder === this.defaultTopicOrder
    );
  }

  get savingDefaultsDisabled() {
    return this.savingReadingDefaults || this.isDefaultTopicsSort;
  }

  get saveDefaultsLabel() {
    return this.isDefaultTopicsSort
      ? "collections.reading.current_default"
      : "collections.reading.set_default";
  }

  get topicsSortFields() {
    return READING_SORT_FIELDS;
  }

  // The feed's only author lookup: rows hold a user_id and nothing else, so every
  // avatar and username on the page is read through here.
  userFor(userId) {
    return userId == null ? null : this.users[userId];
  }

  // First page of the reading feed (docs/04 §1). Called by the route after every :id
  // reseed and by both sort controls.
  async loadTopics() {
    const seq = ++this.#topicsRequestSeq;
    this.loadingTopics = true;
    try {
      const page = await listCollectionTopics(this.model.id, {
        sort: this.topicsSort,
        order: this.topicsOrder,
        page: 0,
        page_size: this.topicsMeta.page_size,
      });
      if (seq !== this.#topicsRequestSeq) {
        return;
      }
      this.topics = page.topics;
      this.users = { ...this.users, ...page.users };
      this.topicsMeta = page.meta;
    } catch (err) {
      if (seq === this.#topicsRequestSeq) {
        popupAjaxError(err);
      }
    } finally {
      if (seq === this.#topicsRequestSeq) {
        this.loadingTopics = false;
      }
    }
  }

  // Both sort controls refetch page 0: loadTopics bumps the request sequence, so a
  // load-more still in flight from the previous ordering is dropped rather than appended.
  @action
  async saveReadingDefaults() {
    if (!this.canManageReadingDefaults || this.savingDefaultsDisabled) {
      return;
    }
    const model = this.model;
    this.savingReadingDefaults = true;
    try {
      const collection = await updateCollectionReadingDefaults(model.id, {
        default_topic_sort: this.topicsSort,
        default_topic_order: this.topicsOrder,
      });
      if (this.model !== model || this.isDestroying) {
        return;
      }
      this.defaultTopicSort = collection.default_topic_sort;
      this.defaultTopicOrder = collection.default_topic_order;
    } catch (err) {
      if (this.model === model && !this.isDestroying) {
        popupAjaxError(err);
      }
    } finally {
      if (this.model === model && !this.isDestroying) {
        this.savingReadingDefaults = false;
      }
    }
  }

  @action
  async changeTopicsSort(field) {
    if (this.topicsSort === field) {
      return;
    }
    this.topicsSort = field;
    await this.loadTopics();
  }

  @action
  async toggleTopicsOrder() {
    this.topicsOrder = this.topicsOrder === "asc" ? "desc" : "asc";
    await this.loadTopics();
  }

  @action
  async loadMoreTopics() {
    if (!this.canLoadMoreTopics) {
      return;
    }
    const seq = this.#topicsRequestSeq;
    this.loadingMoreTopics = true;
    try {
      const page = await listCollectionTopics(this.model.id, {
        sort: this.topicsSort,
        order: this.topicsOrder,
        page: this.topicsMeta.page + 1,
        page_size: this.topicsMeta.page_size,
      });
      if (seq !== this.#topicsRequestSeq) {
        return;
      }
      this.topics = [...this.topics, ...page.topics];
      this.users = { ...this.users, ...page.users };
      this.topicsMeta = page.meta;
    } catch (err) {
      if (seq === this.#topicsRequestSeq) {
        popupAjaxError(err);
      }
    } finally {
      if (seq === this.#topicsRequestSeq) {
        this.loadingMoreTopics = false;
      }
    }
  }

  // First page of the invitation record (docs/05 §2.3). The route calls this on every :id
  // change, and the invite modal calls it again once a new invitation has been sent
  // so the record it just created is visible right away; viewers who may not read
  // the record never issue the request at all.
  @action
  async loadInvites() {
    if (!this.canManageInvites) {
      return;
    }

    this.loadingInvites = true;
    try {
      const page = await listCollectionInvites(this.model.id, {
        page: 0,
        page_size: this.invitesMeta.page_size,
      });
      this.invites = page.invites;
      this.invitesMeta = page.meta;
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.loadingInvites = false;
    }
  }

  @action
  async loadMoreInvites() {
    if (!this.canLoadMoreInvites) {
      return;
    }

    this.loadingMoreInvites = true;
    try {
      const page = await listCollectionInvites(this.model.id, {
        page: this.invitesMeta.page + 1,
        page_size: this.invitesMeta.page_size,
      });
      this.invites = [...this.invites, ...page.invites];
      this.invitesMeta = page.meta;
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.loadingMoreInvites = false;
    }
  }

  // docs/05 §2.2 — revoking deletes the row, so the record drops it rather than restating
  // it. The row's gate says who may; the server re-checks and audits the proxy case.
  @action
  async revokeInvite(invite) {
    const confirmed = await this.#confirm({
      messageKey: "collections.invite_records.confirm_revoke",
      labelKey: "collections.invite_records.revoke",
      replacements: { username: invite.invitee?.username ?? "" },
    });
    if (!confirmed) {
      return;
    }

    this.pendingInviteId = invite.id;
    try {
      await revokeCollectionInvite(this.model.id, invite.id);
      this.invites = this.invites.filter((entry) => entry !== invite);
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.pendingInviteId = null;
    }
  }

  @action
  async toggleSubscription() {
    if (this.toggling || !this.currentUser) {
      return;
    }

    const subscribing = !this.isSubscribed;
    // The owner's own subscription row is never counted (docs/02 §5), so
    // toggling it does not move subscriber_count.
    const delta = this.isOwner ? 0 : subscribing ? 1 : -1;

    this.toggling = true;
    const previousSubscribed = this.isSubscribed;
    const previousCount = this.subscriberCount;
    this.isSubscribed = subscribing;
    this.subscriberCount = Math.max(0, this.subscriberCount + delta);

    try {
      const collection = subscribing
        ? await subscribeToCollection(this.model.id)
        : await unsubscribeFromCollection(this.model.id);
      this.isSubscribed = collection.is_subscribed;
      this.subscriberCount = collection.subscriber_count;
    } catch (err) {
      this.isSubscribed = previousSubscribed;
      this.subscriberCount = previousCount;
      popupAjaxError(err);
    } finally {
      this.toggling = false;
    }
  }

  // docs/04 §5 — drops the row and refreshes the header counters from the full-shape response.
  // This is the only entry that cascades rows away for good, so it asks how many are at
  // stake first (docs/04 §7) and only stops for a confirmation when there are any.
  @action
  async removeTopic(row) {
    let count;
    try {
      const payload = await countTopicSelectedReplies(
        this.model.id,
        row.topic.id
      );
      count = payload.selected_reply_count;
    } catch (err) {
      popupAjaxError(err);
      return false;
    }

    if (count > 0 && !(await this.#confirmCascadeRemoval(row, count))) {
      return false;
    }

    this.pendingTopicId = row.topic.id;
    try {
      const collection = await removeTopicFromCollection(
        this.model.id,
        row.topic.id
      );
      this.topics = this.topics.filter((entry) => entry !== row);
      this.topicCount = collection.topic_count;
      this.lastTopicAddedAt = collection.last_topic_added_at;
      return true;
    } catch (err) {
      popupAjaxError(err);
      return false;
    } finally {
      this.pendingTopicId = null;
    }
  }

  // docs/04 §4 remove — the response is the whole reading-page row recomputed server-side
  // (inline replies capped, has_more_selected_replies re-probed), so it replaces the
  // row rather than being merged. Reversible — featuring the reply again restores it — so
  // unlike the removal above, this one doesn't stop to ask.
  @action
  async unfeatureReply(row, reply) {
    this.pendingTopicId = row.topic.id;
    try {
      const updated = await unselectReplyFromCollection(
        this.model.id,
        row.topic.id,
        reply.post_id
      );
      this.#replaceRow(row, updated);
      return true;
    } catch (err) {
      popupAjaxError(err);
      return false;
    } finally {
      this.pendingTopicId = null;
    }
  }

  // Note edit: docs/04 §4 when the viewer maintains the collection, otherwise the staff
  // rewrite (docs/06 §1); a staff owner stays on docs/04 §4, which is not audited (docs/10).
  // Resolves to whether the write went through, so the row closes its editor on success.
  @action
  async saveTopicNote(row, note) {
    this.pendingTopicId = row.topic.id;
    try {
      const updated = this.canManageContent
        ? await updateTopicNote(this.model.id, row.topic.id, note)
        : await rewriteTopicNote(this.model.id, row.topic.id, note);
      this.#replaceRow(row, updated);
      return true;
    } catch (err) {
      popupAjaxError(err);
      return false;
    } finally {
      this.pendingTopicId = null;
    }
  }

  // docs/05 §1 — the edit modal issues the write itself and hands back the full shape; the
  // page only mirrors the two fields it renders.
  @action
  applyMetadata(collection) {
    this.avatarUpload = collection.avatar_upload;
    this.backgroundUpload = collection.background_upload;
    this.collectionName = collection.name;
    this.collectionDescription = collection.description;
    // The document title reads the name too, so re-collect it (the route's titleToken).
    this.send("refreshTitle");
  }

  // The owner's full list is one modal away (docs/03 §3): it pages through the collection
  // list filtered by that username, which the modal fetches for itself.
  @action
  openOwnerCollections() {
    const username = this.owner?.username;
    if (!username) {
      return;
    }

    this.modal.show(CollectionOwnerCollectionsModal, { model: { username } });
  }

  // docs/05 §2.7 — a staff takeover answers with the collection already under its new owner,
  // so the page mirrors the fields it renders instead of re-reading it: the role chip, the
  // team card and every entry gate on the page follow from them.
  @action
  applyOwnership(collection) {
    this.owner = collection.owner;
    this.teamworkers = collection.teamworkers;
    // The subscription moves with the role (docs/08 §1): the incoming owner holds a
    // subscription row that never counts, while the demoted owner's own row starts
    // counting, so the response's recomputed count is the only correct one here.
    this.isSubscribed = collection.is_subscribed;
    this.subscriberCount = collection.subscriber_count;
    // The response is the full shape, but the owner's other collections are only added by
    // docs/03 §4's detail read (docs/03 §1) — and this page shows rather than re-reads.
    // They belonged to the previous owner, so they are dropped along with the heading
    // that has just been renamed.
    this.ownerCollections = [];
    this.hasMoreOwnerCollections = false;
    // Taking over both adds a record and, for staff, gains the record section — the
    // viewer is an owner now.
    this.loadInvites();
  }

  // DELETE — owner only. The collection is gone afterwards, so this leaves the page
  // rather than trying to re-render it.
  @action
  async destroyCollection() {
    const confirmed = await this.#confirm({
      messageKey: "collections.detail.confirm_delete",
      labelKey: "collections.detail.delete",
      replacements: { name: this.collectionName },
    });
    if (!confirmed) {
      return;
    }

    this.deleting = true;
    try {
      await deleteCollection(this.model.id);
      this.router.transitionTo("collections");
    } catch (err) {
      popupAjaxError(err);
      this.deleting = false;
    }
  }

  // Leaving removes the viewer's own row; the full-shape response is what clears
  // their role chip and the management entries that came with it.
  @action
  async leaveCollection() {
    const confirmed = await this.#confirm({
      messageKey: "collections.team.confirm_leave",
      labelKey: "collections.team.leave",
    });
    if (confirmed) {
      await this.#removeTeamworker(this.currentUser.id);
    }
  }

  @action
  async removeMaintainer(user) {
    const confirmed = await this.#confirm({
      messageKey: "collections.team.confirm_remove",
      labelKey: "collections.team.remove",
      replacements: { username: user.username },
    });
    if (confirmed) {
      await this.#removeTeamworker(user.id);
    }
  }

  // Who may call off a recorded invitation (docs/05 §2.2): its issuer, or a staff
  // manager — for whom any still-pending row of the collection is fair game.
  #canRevokeInvite(invite) {
    if (invite.status !== "pending") {
      return false;
    }

    return (
      invite.inviter?.id === this.currentUserId ||
      this.canManageCollectionAsStaff
    );
  }

  // Removals, deletions and revocations go red on both the trigger and the confirm
  // button (plugin-wide rule); the shared helper owns that and the more subtle
  // message-vs-label asymmetry of core's dialog.
  #confirm({ messageKey, labelKey, replacements = {} }) {
    return confirmAction(this.dialog, { messageKey, labelKey, replacements });
  }

  // The cascade warning needs a "view" entry, so it is a modal of its own — and the list
  // it opens is one too, while the modal service holds one at a time. Hence the loop: the
  // confirmation is put back after every look, until the reader confirms or backs out.
  async #confirmCascadeRemoval(row, count) {
    while (true) {
      const result = await this.modal.show(RemoveTopicModal, {
        model: {
          messageKey: "collections.reading.confirm_remove_topic",
          count,
        },
      });

      if (!result?.viewReplies) {
        return result?.confirmed === true;
      }

      await this.modal.show(TopicSelectedRepliesModal, {
        model: {
          collectionId: this.model.id,
          topicId: row.topic.id,
          slug: row.topic.slug,
          title: row.topic.fancy_title,
        },
      });
    }
  }

  // One teammate row locks while its removal is in flight; the rest of the page
  // stays usable.
  async #removeTeamworker(userId) {
    this.pendingMaintainerId = userId;
    try {
      const collection = await removeCollectionMaintainer(
        this.model.id,
        userId
      );
      this.teamworkers = collection.teamworkers;
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.pendingMaintainerId = null;
    }
  }

  // Rows are plain JSON objects (not tracked), so replacing the entry is what
  // re-renders. The new identity also remounts the row component, which is how a
  // successful save closes the note editor. A write response carries its own `users`
  // for the row it returns: those are merged into the page's map and the key is
  // dropped, so a replaced row looks its authors up like every other row.
  #replaceRow(row, payload) {
    const { users, ...updated } = payload;
    this.users = { ...this.users, ...users };
    this.topics = this.topics.map((entry) => (entry === row ? updated : entry));
  }
}
