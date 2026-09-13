import { apiInitializer } from "discourse/lib/api";

// Reverse-lookup fields injected by TopicViewSerializer (docs/07): the
// topic level `collections` (id+name) and the post level `selected_by_collection_ids`.
// Registering them as model fields makes them tracked arrays, so collecting a topic
// from the picker can update the chips in place instead of reloading the topic.
export default apiInitializer((api) => {
  api.addModelField("topic", "collections", {
    type: "array",
    defaultValue: () => [],
  });
  api.addModelField("post", "selected_by_collection_ids", {
    type: "array",
    defaultValue: () => [],
  });
});
