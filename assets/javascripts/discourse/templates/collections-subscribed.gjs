import CollectionListPage from "../components/collection-list-page";

export default <template>
  <CollectionListPage
    @controller={{@controller}}
    @emptyBodyKey="collections.subscribed_empty"
    @emptyTitleKey="collections.subscribed_empty_title"
    @subtitleKey="collections.subscribed_subtitle"
    @titleKey="collections.heading"
  />
</template>;
