import { cached } from "@glimmer/tracking";
import { apiInitializer } from "discourse/lib/api";
import { withCollectionColumns } from "../lib/data-explorer-columns";

export default apiInitializer((api) => {
  api.modifyClass("component:query-result", (SuperClass) =>
    class extends SuperClass {
      @cached
      get columnComponents() {
        return withCollectionColumns(
          super.columnComponents,
          this.colRender,
          this._relationTables
        );
      }
    }
  );

  // The admin dashboard's embedded reports render rows through the same
  // `query-row-content`, but build their definitions from a narrowed component set.
  api.modifyClass("component:admin-dashboard-card", (SuperClass) =>
    class extends SuperClass {
      @cached
      get columnComponents() {
        return withCollectionColumns(
          super.columnComponents,
          this.args.payload?.colrender ?? {},
          this.relationTables
        );
      }
    }
  );
});
