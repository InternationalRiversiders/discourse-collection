import { module, test } from "qunit";
import Collection from "discourse/plugins/discourse-collection/discourse/components/result-types/collection";
import { withCollectionColumns } from "discourse/plugins/discourse-collection/discourse/lib/data-explorer-columns";

// The shape core hands a row: a column it could not map comes back named `text`, carrying
// the relation table it derived from that same name (lib/result-columns.js of
// discourse-data-explorer).
function definitionsFor(names) {
  return names.map((name) => ({
    name,
    component: undefined,
    table: { relation: name },
    hidden: false,
  }));
}

module("Unit | Lib | data-explorer-columns", function () {
  test("points a collection column back at its cell and its relation table", function (assert) {
    const definitions = definitionsFor(["text", "text"]);
    const colRender = { 1: "collection" };
    const relationTables = { collection: { 7: { id: 7, name: "Reading list" } } };

    const mapped = withCollectionColumns(definitions, colRender, relationTables);

    assert.strictEqual(
      mapped[1].name,
      "collection",
      "restores the type core downgraded to text"
    );
    assert.strictEqual(
      mapped[1].component,
      Collection,
      "renders the cell through the plugin's component"
    );
    assert.strictEqual(
      mapped[1].table,
      relationTables.collection,
      "reads the relation table core rebuilt from the downgraded type"
    );
  });

  test("maps by column position, so a plain text column is left as it is", function (assert) {
    const definitions = definitionsFor(["text", "text"]);
    const relationTables = { collection: {} };

    const mapped = withCollectionColumns(definitions, { 0: "collection" }, relationTables);

    assert.strictEqual(
      mapped[0].component,
      Collection,
      "the column the colrender entry points at is the mapped one"
    );
    assert.strictEqual(mapped[1], definitions[1], "its neighbour is not even copied");
  });

  test("leaves every definition alone when no column is a collection", function (assert) {
    const definitions = definitionsFor(["topic", "text"]);

    const mapped = withCollectionColumns(definitions, { 0: "topic" }, {});

    assert.strictEqual(mapped[0], definitions[0], "core's topic column is untouched");
    assert.strictEqual(mapped[1], definitions[1], "so is the text column");
  });
});
