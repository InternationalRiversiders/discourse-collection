import { ajax } from "discourse/lib/ajax";

// Thin verb wrappers over the plugin API (docs/02). Components and services
// call these instead of building endpoint strings, so the top-level mount path
// ("/collections...", engine mounted at "/") lives in one place.

// docs/05 §2.1 action_type.
export const INVITE_MAINTAINER = 0;
export const INVITE_OWNER = 1;

function pageData({ sort, order, page, page_size } = {}) {
  const data = {};
  if (sort) {
    data.sort = sort;
  }
  if (order) {
    data.order = order;
  }
  if (page !== undefined) {
    data.page = page;
  }
  if (page_size !== undefined) {
    data.page_size = page_size;
  }
  return data;
}

// docs/03 §3 all public collections.
export function listCollections(options = {}) {
  return ajax("/collections.json", { data: pageData(options) });
}

// docs/04 §6 collections the current user owns or co-maintains.
export function listMyCollections(options = {}) {
  return ajax("/collections/mine.json", { data: pageData(options) });
}

// docs/04 §6 collections the current user subscribes to.
export function listSubscribedCollections(options = {}) {
  return ajax("/collections/subscribed.json", { data: pageData(options) });
}

// docs/03 §4 a single collection in its full shape.
export function getCollection(id) {
  return ajax(`/collections/${id}.json`);
}

// docs/04 §1 one reading-page page of a collection's topics. Each row carries added_at /
// note / the topic card / up to collection_max_selected_replies_per_topic inline
// selected replies (docs/04 §1).
export function listCollectionTopics(id, options = {}) {
  return ajax(`/collections/${id}/topics.json`, { data: pageData(options) });
}

// docs/04 §2 overflow pager for one collected topic's selected replies (fixed post_id ASC,
// not capped by the inline limit) — the endpoint behind has_more_selected_replies.
export function listTopicSelectedReplies(id, topicId, options = {}) {
  return ajax(`/collections/${id}/topics/${topicId}/selected_replies.json`, {
    data: pageData(options),
  });
}

// docs/04 §3 collect a topic into a collection (owner/teamworker only). Idempotent: a
// repeat call is a 200 no-op rather than an error, which is why the picker marks
// already-collected collections instead of relying on a failure. Resolves to the
// collection's full shape (updated counters), not to the collected-topic row.
export function addTopicToCollection(collectionId, topicId, { note } = {}) {
  const data = { topic_id: topicId };
  if (note !== undefined) {
    data.note = note;
  }
  return ajax(`/collections/${collectionId}/topics.json`, {
    type: "POST",
    data,
  });
}

// docs/04 §5 un-collect a topic. Resolves to the collection's full shape. The server also
// drops every selected-reply row of that (collection, topic) pair, so callers must
// mirror that by clearing the topic's featured replies locally.
export function removeTopicFromCollection(collectionId, topicId) {
  return ajax(`/collections/${collectionId}/topics/${topicId}.json`, {
    type: "DELETE",
  });
}

// docs/04 §4 feature / un-feature one reply. Both verbs are incremental and idempotent and
// resolve to the collected-topic row; a feature on a topic the collection does not
// hold is a 404, and an OP or non-regular post is a 422.
export function selectReplyInCollection(collectionId, topicId, postId) {
  return ajax(`/collections/${collectionId}/topics/${topicId}.json`, {
    type: "PATCH",
    data: { selected_replies: { add: [postId] } },
  });
}

export function unselectReplyFromCollection(collectionId, topicId, postId) {
  return ajax(`/collections/${collectionId}/topics/${topicId}.json`, {
    type: "PATCH",
    data: { selected_replies: { remove: [postId] } },
  });
}

// docs/04 §4 note edit (owner / co-maintainer). The note field is tri-state server-side: a
// value replaces it, an absent key leaves it alone. An emptied editor sends "", which
// the service stores as nil — so blank clears the note like an explicit null (docs/04 §4).
export function updateTopicNote(collectionId, topicId, note) {
  return ajax(`/collections/${collectionId}/topics/${topicId}.json`, {
    type: "PATCH",
    data: { note },
  });
}

// docs/06 §1 staff rewrite of one note on any collection (admin + moderator always, no
// setting gate). Same tri-state, note-only: featured replies can never ride along.
export function rewriteTopicNote(collectionId, topicId, note) {
  return ajax(`/collections/${collectionId}/topics/${topicId}/note.json`, {
    type: "PUT",
    data: { note },
  });
}

// docs/03 §2 create a collection owned by the acting user; resolves to the full shape.
export function createCollection({ name, description }) {
  return ajax("/collections.json", {
    type: "POST",
    data: { name, description },
  });
}

// docs/05 §1 rename / change description. Partial body: name and/or description, at least
// one. The collection's owner may edit its own; staff may edit any collection
// (including an unclaimed one). Resolves to the full shape.
export function updateCollection(id, { name, description } = {}) {
  const data = {};
  if (name !== undefined) {
    data.name = name;
  }
  if (description !== undefined) {
    data.description = description;
  }
  return ajax(`/collections/${id}.json`, { type: "PUT", data });
}

// DELETE a collection (owner only — the matrix does not open this to staff). Child
// rows cascade in the database, so there is nothing to clean up client-side; callers
// must leave the page, which no longer resolves.
export function deleteCollection(id) {
  return ajax(`/collections/${id}.json`, { type: "DELETE" });
}

// docs/05 §2.1 invite a user to co-maintain (INVITE_MAINTAINER) or to take ownership
// (INVITE_OWNER). Nothing takes effect until the invitee accepts; a live pending
// invite for the same user and type comes back as-is instead of erroring.
//
// The answers are not uniform: a regular issue returns the parked invite, but a staff
// member inviting THEMSELVES as the owner (docs/05 §2.7) takes the collection over inside
// the request, so the response is `{ invite: <already accepted>, collection: <full
// shape> }` instead — callers read `response.invite` first.
export function inviteToCollection(collectionId, { userId, actionType }) {
  return ajax(`/collections/${collectionId}/invites.json`, {
    type: "POST",
    data: { user_id: userId, action_type: actionType },
  });
}

// docs/05 §2.3 the invitations of one collection (owner / staff only) — pending rows plus
// the accepted / rejected / expired history still inside the retention window.
export function listCollectionInvites(id, options = {}) {
  return ajax(`/collections/${id}/invites.json`, { data: pageData(options) });
}

// docs/05 §2.2 revoke a pending invitation — one's own, or anyone's when the caller is a
// staff manager. The row is gone afterwards, which also frees its spot.
export function revokeCollectionInvite(collectionId, inviteId) {
  return ajax(`/collections/${collectionId}/invites/${inviteId}.json`, {
    type: "DELETE",
  });
}

// docs/05 §2.4 my invitation inbox — every invitation addressed to me, whatever the
// collection. Logged in only: unlike the public lists, the anonymous-read toggle
// does not open it.
export function listMyInvites(options = {}) {
  return ajax("/collections/invites.json", { data: pageData(options) });
}

// docs/05 §2.5 accept — the membership row / ownership switch happens now. Resolves to the
// collection's full shape, not to the invite, so the caller can move on with it.
export function acceptCollectionInvite(inviteId) {
  return ajax(`/collections/invites/${inviteId}/accept.json`, { type: "POST" });
}

// docs/05 §2.5 reject — no membership or ownership is written, only the decline. Resolves
// to a bare success body.
export function rejectCollectionInvite(inviteId) {
  return ajax(`/collections/invites/${inviteId}/reject.json`, { type: "POST" });
}

// docs/02 §3 teammate removal — the owner removes a co-maintainer, or a co-maintainer
// removes themselves (leaving). Resolves to the collection's full shape with the
// team already updated.
export function removeCollectionMaintainer(collectionId, userId) {
  return ajax(`/collections/${collectionId}/teamworkers/${userId}.json`, {
    type: "DELETE",
  });
}

// Subscription (docs/02 §5): both verbs resolve to the collection's full
// shape with the updated is_subscribed / subscriber_count.
export function subscribeToCollection(id) {
  return ajax(`/collections/${id}/subscription.json`, { type: "POST" });
}

export function unsubscribeFromCollection(id) {
  return ajax(`/collections/${id}/subscription.json`, { type: "DELETE" });
}
