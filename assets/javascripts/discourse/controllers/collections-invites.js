import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { popupAjaxError } from "discourse/lib/ajax-error";
import {
  acceptCollectionInvite,
  INVITE_OWNER,
  listMyInvites,
  rejectCollectionInvite,
} from "../lib/collection-api";
import { confirmAction } from "../lib/confirm";
import { inviteRoleName, inviteStatusLabel } from "../lib/invite-labels";

// The invitee's side of the invitation flow (docs/05 §2.4 / docs/05 §2.5): what
// others asked of me, and the two answers I can give while the invitation is still
// pending. Answering moves the row in place — the list is the record, so it is never
// refetched, and an answered invitation stays visible as history.
export default class CollectionsInvitesController extends Controller {
  @service dialog;

  @tracked invites = [];
  @tracked meta = { page: 0, page_size: 30, more: false, total: 0 };
  @tracked loadingMore = false;
  @tracked pendingInviteId = null;

  get canLoadMore() {
    return this.meta.more && !this.loadingMore;
  }

  // The wording of a row, plus the one gate that matters: only a pending invitation
  // can be answered. A transfer names the sitting owner, which is the whole reason
  // the inbox shape carries that snapshot (docs/05 §2.4).
  get rows() {
    return this.invites.map((invite) => ({
      invite,
      isPending: invite.status === "pending",
      isOwnershipTransfer: invite.action_type === INVITE_OWNER,
      statusLabel: inviteStatusLabel(invite.status),
      roleName: inviteRoleName(invite.action_type),
      inviter: invite.inviter,
      ownerUsername: invite.collection?.owner?.username ?? null,
      busy: this.pendingInviteId === invite.id,
    }));
  }

  @action
  async loadMore() {
    if (!this.canLoadMore) {
      return;
    }

    this.loadingMore = true;
    try {
      const page = await listMyInvites({
        page: this.meta.page + 1,
        page_size: this.meta.page_size,
      });
      this.invites = [...this.invites, ...page.invites];
      this.meta = page.meta;
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.loadingMore = false;
    }
  }

  // docs/05 §2.5 — accepting writes the membership row (type=0) or moves ownership
  // (type=1), so the two asks read differently before the fact: one gains a role on
  // someone's collection, the other takes the collection over.
  @action
  async accept(row) {
    const confirmed = await confirmAction(this.dialog, {
      messageKey: row.isOwnershipTransfer
        ? "collections.invites.confirm_accept_owner"
        : "collections.invites.confirm_accept_maintainer",
      labelKey: "collections.invites.accept",
      replacements: { name: row.invite.collection.name },
      danger: false,
    });
    if (!confirmed) {
      return;
    }

    this.pendingInviteId = row.invite.id;
    try {
      await acceptCollectionInvite(row.invite.id);
      this.#setStatus(row.invite, "accepted");
    } catch (err) {
      // The invitation may have been revoked or expired since the page loaded, or the
      // invitee may no longer qualify (capacity, allowed groups) — the server words
      // all of that, and nothing about the row changes.
      popupAjaxError(err);
    } finally {
      this.pendingInviteId = null;
    }
  }

  // docs/05 §2.5 — declining writes nothing but the decline itself, so there is no result
  // to reconcile beyond the row's new state.
  @action
  async reject(row) {
    const confirmed = await confirmAction(this.dialog, {
      messageKey: "collections.invites.confirm_reject",
      labelKey: "collections.invites.reject",
      replacements: { name: row.invite.collection.name },
    });
    if (!confirmed) {
      return;
    }

    this.pendingInviteId = row.invite.id;
    try {
      await rejectCollectionInvite(row.invite.id);
      this.#setStatus(row.invite, "rejected");
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.pendingInviteId = null;
    }
  }

  // Answered rows stay in the list as history (they are inside the retention window),
  // so the status flips instead of the row disappearing.
  #setStatus(invite, status) {
    this.invites = this.invites.map((entry) =>
      entry === invite ? { ...entry, status } : entry
    );
  }
}
