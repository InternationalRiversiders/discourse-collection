import { apiInitializer } from "discourse/lib/api";
import Collection from "../components/result-types/collection";

// Data Explorer maps a relation type to its cell component in a module-private lookup,
// so the `collection` type this plugin registers server-side would land on the text
// fallback — an empty cell — without a component of its own. The definitions are handed
// to each row from one getter, which is the only place the mapping can be reached.
export default apiInitializer((api) => {
  api.modifyClass("component:query-result", (SuperClass) =>
    class extends SuperClass {
      get columnComponents() {
        return super.columnComponents.map((definition) =>
          definition.name === "collection"
            ? { ...definition, component: Collection }
            : definition
        );
      }
    }
  );
});
