// The cell for a `collection_id` column, reached through the `collection` relation type
// registered in lib/discourse_collection/data_explorer_relations.rb — `@ctx.collection`
// is the `{id, name}` it resolved, absent when the column holds no such collection.
const Collection = <template>
  <a href="{{@ctx.baseuri}}/collections/{{@ctx.collection.id}}">{{@ctx.collection.name}}</a>
</template>;

export default Collection;
