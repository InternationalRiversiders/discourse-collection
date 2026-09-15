import CollectionListPage from "../components/collection-list-page";

export default <template>
  <CollectionListPage
    @controller={{@controller}}
    @create={{true}}
    @emptyBodyKey="collections.empty"
    @emptyTitleKey="collections.empty_title"
    @subtitleKey="collections.subtitle"
    @titleKey="collections.heading"
  />
</template>;
