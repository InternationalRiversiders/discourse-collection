# frozen_string_literal: true

Fabricator(:collection, class_name: "DiscourseCollection::Collection") do
  name "Sample collection"
  description ""
  topic_count 0
  last_topic_added_at nil
end

Fabricator(:collection_teamworker, class_name: "DiscourseCollection::CollectionTeamworker") do
  collection
  user
  is_owner false
end

Fabricator(:collection_subscriber, class_name: "DiscourseCollection::CollectionSubscriber") do
  collection
  user
end

Fabricator(:collection_invite, class_name: "DiscourseCollection::CollectionInvite") do
  collection
  inviter { Fabricate(:user) }
  invitee { Fabricate(:user) }
  action_type DiscourseCollection::CollectionInvite::ACTION_TYPE_MAINTAINER
  accept nil
end

Fabricator(:collection_topic, class_name: "DiscourseCollection::CollectionTopic") do
  collection
  topic
  note nil
end

Fabricator(
  :collection_topic_selected_reply,
  class_name: "DiscourseCollection::CollectionTopicSelectedReply",
) do
  collection
  topic
  post
end
