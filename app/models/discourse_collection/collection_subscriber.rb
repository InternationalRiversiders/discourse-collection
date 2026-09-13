# frozen_string_literal: true

module DiscourseCollection
  class CollectionSubscriber < ActiveRecord::Base
    self.table_name = "collection_subscribers"

    belongs_to :collection, class_name: "DiscourseCollection::Collection"
    belongs_to :user
  end
end

# == Schema Information
#
# Table name: collection_subscribers
#
#  created_at    :datetime         not null
#  collection_id :integer          not null, primary key
#  user_id       :integer          not null, primary key
#
# Indexes
#
#  index_collection_subscribers_on_user_id_and_collection_id  (user_id,collection_id)
#
# Foreign Keys
#
#  collection_subscribers_collection_id_fkey  (collection_id => collections.id) ON DELETE => cascade
#  collection_subscribers_user_id_fkey        (user_id => users.id) ON DELETE => cascade
#