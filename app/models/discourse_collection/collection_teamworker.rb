# frozen_string_literal: true

module DiscourseCollection
  class CollectionTeamworker < ActiveRecord::Base
    self.table_name = "collection_teamworkers"

    belongs_to :collection, class_name: "DiscourseCollection::Collection"
    belongs_to :user
  end
end

# == Schema Information
#
# Table name: collection_teamworkers
#
#  created_at    :datetime         not null
#  is_owner      :boolean          default(FALSE), not null
#  collection_id :integer          not null, primary key
#  user_id       :integer          not null, primary key
#
# Indexes
#
#  uq_collection_teamworkers_single_owner  (collection_id) UNIQUE WHERE (is_owner)
#
# Foreign Keys
#
#  collection_teamworkers_collection_id_fkey  (collection_id => collections.id) ON DELETE => cascade
#  collection_teamworkers_user_id_fkey        (user_id => users.id) ON DELETE => cascade
#