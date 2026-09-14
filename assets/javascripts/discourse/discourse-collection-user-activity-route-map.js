/**
 * The collections tab on a user's activity page (core's user.userActivity
 * resource): route name userActivity.collections, URL
 * /u/:username/activity/collections. It never activates alongside the flat
 * top-level collections route, so the two may each own a `collections` name.
 */
export default {
  resource: "user.userActivity",

  map() {
    this.route("collections");
  },
};
