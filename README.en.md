# discourse-collection

English | [简体中文](./README.md)

---

A Discourse plugin: public collections.

Signed-in users can create collections, collect any topic on the forum into them, feature the good replies in them, and co-maintain them together with others. A collection is a hand-curated public list, there to be browsed, subscribed to, and used to look up which collections a topic has been added to.

## Features

- **Collecting**: create a collection and collect any topic into it, with an optional note on each entry; a topic page shows which collections the topic has been added to.

- **Featured replies**: feature the good replies in a topic into a collection. The collection reading page shows them inline under each topic, and expands the full set when a topic has more than the inline limit. Removing a topic takes its featured replies with it and cannot be undone, so the removal says how many are at stake and offers to show them first.

- **Subscribing and notifications**: any signed-in user can subscribe to a collection. When new topics are collected into it, subscribers get a native Discourse notification. A collection always keeps a **single entry** in the notification list: every addition marks it unread again and lights the badge, instead of piling up one item per topic.

- **Co-maintenance**: the owner invites others to become co-maintainers, and it takes effect once the invitee accepts. The owner can remove a co-maintainer, and a co-maintainer can leave on their own.

- **Ownership transfer**: the owner can start an ownership transfer, and staff can start one on any collection (including an unclaimed one, whose owner's account was deleted). Either way it takes effect only once the invitee accepts.

- **Link cards**: a collection link on a line of its own in a post body renders as a card (name, description, counts, owner, dates), and the same link inside a sentence renders as a "name - Collections" link. Off by default.

- **Anonymous browsing**: off by default; when it is on, signed-out visitors can browse collections.

- **Profile page**: a **Collections** tab on a user's activity page lists every collection that user created or maintains, ordered by most recently collected.

- **Moderation**: admins (and moderators, if enabled by a setting) can fix the name or description of any collection and rewrite collection notes; those changes go into Discourse's native staff action log.

Visibility: the topic and post lists inside a collection are always filtered on the server against the viewer's permissions, and entries the viewer cannot access are dropped (the same rules as the forum's own lists, except that topics with a muted notification level are still included) — a collection is never a way around forum permissions.

## Usage

1. Open **Collections** in the left sidebar to get the list page, whose tabs are All / Mine / Subscribed / Invites.

2. Create a collection (name and description) on the **Mine** tab.

3. On any topic, open **More** in the post action bar and pick **Add to collection**, then choose one of your own collections (or one you can manage). The same entry point features a single reply.

4. A collection's page is where you subscribe to it, read the stream of collected topics, and manage its team and its invitations.

5. When you are invited, both the notification and the **Invites** tab tell you about it; accept or decline there.

## Installation

Install it the usual way for a Discourse plugin; there are no extra dependencies (the database migration creates 6 tables). After installing, check that `collection_enabled` and the various group admission settings are what you expect.

Existing posts need to be **rebaked** before they grow a card once link cards are turned on.

## Site settings

The settings all live under the "Plugins" category in site settings, each with its own description and default value; the commonly used ones are:

| Setting | Default | Description |
| --- | --- | --- |
| Collection enabled | on | Master switch for the plugin |
| Collection allow anonymous | off | Signed-out visitors can browse collections |
| Collection moderators can manage collections | off | Moderators can manage other people's collections (change the name or description, start an ownership transfer); admins always can |
| Collection create allowed groups | `trust_level_1` | Groups that may create collections and be invited as a new owner; empty = off |
| Collection teamworker allowed groups | `trust_level_1` | Groups that may be invited as a co-maintainer; empty = off |
| Collection create disallowed groups | empty | Groups that may not create collections or become a new owner; empty = nobody is rejected |
| Collection teamworker disallowed groups | empty | Groups that may not become a co-maintainer; empty = nobody is rejected |

Admission is decided by **group membership**, and only at the moment the action happens; **disallowed groups take precedence over allowed groups** (matching both means being rejected). The role settings that lift a limit lift only the count limits, not group admission.

## Development

- The repository's development conventions and schema rules are in [CLAUDE.md](CLAUDE.md).

- The HTTP API design is in [docs/index.md](docs/index.md); the table-creation migration is the single source of truth for the schema.
