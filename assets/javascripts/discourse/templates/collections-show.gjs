import CollectionDetailPage from "../components/collection-detail-page";

export default <template>
  <CollectionDetailPage
    @collection={{@model}}
    @controller={{@controller}}
  />
</template>;
