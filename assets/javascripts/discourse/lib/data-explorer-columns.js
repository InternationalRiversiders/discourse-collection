import Collection from "../components/result-types/collection";

const COLLECTION_TYPE = "collection";

/**
 * Keeps the plugin's `collection` columns linked. Data Explorer holds its type-to-
 * component lookup privately and rewrites an unmapped name to `text`, so the requested
 * type survives only in `colrender` and `table` must be supplied again.
 */
export function withCollectionColumns(definitions, colRender, relationTables) {
  return definitions.map((definition, idx) =>
    colRender[idx] === COLLECTION_TYPE
      ? {
          ...definition,
          name: COLLECTION_TYPE,
          component: Collection,
          table: relationTables[COLLECTION_TYPE],
        }
      : definition
  );
}
