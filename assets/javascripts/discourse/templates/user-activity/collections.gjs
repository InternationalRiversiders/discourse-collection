import CollectionListPage from "../../components/collection-list-page";

// One user's collections in a fixed order: no list tabs, no sort controls.
export default <template>
  <CollectionListPage
    @controller={{@controller}}
    @emptyBodyKey="collections.user_activity.empty"
    @emptyTitleKey="collections.user_activity.empty_title"
    @showSort={{false}}
    @showTabs={{false}}
    @subtitleKey="collections.user_activity.subtitle"
    @titleKey="collections.user_activity.title"
    @username={{@controller.username}}
  />
</template>;
