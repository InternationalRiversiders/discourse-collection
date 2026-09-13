/* eslint-disable ember/route-path-style */
export default function () {
  // Flat top-level routes. The nested-looking URLs (/collections/mine) come from
  // the `path:` options, not from route nesting: each list page is an
  // independent top-level route whose controller alone owns its query params.
  // Nesting the lists under one parent put ancestor+descendant controllers in a
  // single active hierarchy that both mapped `sort`/`order`, which Ember forbids
  // — flat sibling routes are never active together, so no clash.
  this.route("collections", { path: "/collections" });
  this.route("collectionsMine", { path: "/collections/mine" });
  this.route("collectionsSubscribed", { path: "/collections/subscribed" });
  // /collections/invites is a literal segment and must be declared before the
  // dynamic :id route, which would otherwise swallow it (mirrors the backend's
  // route order in config/routes.rb).
  this.route("collectionsInvites", { path: "/collections/invites" });
  this.route("collectionsShow", { path: "/collections/:id" });
}
