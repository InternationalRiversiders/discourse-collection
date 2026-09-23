# frozen_string_literal: true

class AddCollectionReadingDefaults < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      ALTER TABLE collections
        ADD COLUMN default_topic_sort CHARACTER VARYING(32) NOT NULL DEFAULT 'added_at',
        ADD COLUMN default_topic_order CHARACTER VARYING(4) NOT NULL DEFAULT 'desc';
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE collections
        DROP COLUMN default_topic_sort,
        DROP COLUMN default_topic_order;
    SQL
  end
end
