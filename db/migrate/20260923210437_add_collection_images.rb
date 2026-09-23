# frozen_string_literal: true

class AddCollectionImages < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      ALTER TABLE collections
        ADD COLUMN avatar_upload_id INTEGER REFERENCES uploads(id) ON DELETE SET NULL,
        ADD COLUMN background_upload_id INTEGER REFERENCES uploads(id) ON DELETE SET NULL;
      CREATE INDEX index_collections_on_avatar_upload_id ON collections (avatar_upload_id);
      CREATE INDEX index_collections_on_background_upload_id ON collections (background_upload_id);
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE collections
        DROP COLUMN avatar_upload_id,
        DROP COLUMN background_upload_id;
    SQL
  end
end
