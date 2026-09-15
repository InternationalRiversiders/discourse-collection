import { i18n } from "discourse-i18n";

// What the reading feed can be ordered by (docs/04 §1). Each value is both the `sort`
// query value the endpoint accepts and the suffix of its label under
// collections.reading.sort.
export const READING_SORT_FIELDS = ["added_at", "topic_created_at", "topic_bumped_at"];

export const READING_SORT_DEFAULT = "added_at";

// The reading feed's sortable keys name a timestamp, so a row prints the one it is
// ordered by — the list order and the times on it then always agree. The topic keys read
// a column of the row's topic card; anything else falls back to the collection time.
export function readingSortTime(sort, row) {
  switch (sort) {
    case "topic_created_at":
      return { label: i18n("collections.reading.created"), value: row.topic.created_at };
    case "topic_bumped_at":
      return { label: i18n("collections.reading.last_reply"), value: row.topic.bumped_at };
    default:
      return { label: i18n("collections.reading.added"), value: row.added_at };
  }
}
