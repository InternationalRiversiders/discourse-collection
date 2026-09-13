import CollectionListPage from "../components/collection-list-page";

export default <template>
  <CollectionListPage
    @controller={{@controller}}
    @create={{true}}
    @emptyBodyKey="collections.mine_empty"
    @emptyTitleKey="collections.mine_empty_title"
    @subtitleKey="collections.mine_subtitle"
    @titleKey="collections.heading"
  />
</template>;
