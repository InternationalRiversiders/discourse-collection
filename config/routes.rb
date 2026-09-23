# frozen_string_literal: true

DiscourseCollection::Engine.routes.draw do
  # Literal segments (mine / subscribed / invites inbox) must precede `:id`.
  get "/collections" => "collections#index"
  get "/collections/mine" => "collections#mine"
  get "/collections/subscribed" => "collections#subscribed"
  get "/collections/invites" => "collections#invites_inbox"
  get "/collections/:id" => "collections#show"
  post "/collections" => "collections#create"
  put "/collections/:id" => "collections#update"
  put "/collections/:id/appearance" => "collections#update_appearance"
  put "/collections/:id/read_notifications" => "collections#read_notifications"
  post "/collections/:id/topics" => "collections#add_topic"
  get "/collections/:id/topics" => "collections#topics"
  get "/collections/:id/topics/:topic_id/selected_replies" => "collections#selected_replies"
  get "/collections/:id/topics/:topic_id/selected_replies/count" => "collections#selected_replies_count"
  get "/collections/:id/topics/:topic_id" => "collections#collected_topic"
  patch "/collections/:id/topics/:topic_id" => "collections#update_collected_topic"
  put "/collections/:id/topics/:topic_id/note" => "collections#rewrite_topic_note"
  delete "/collections/:id/topics/:topic_id" => "collections#remove_topic"
  delete "/collections/:id/teamworkers/:user_id" => "collections#remove_maintainer"
  get "/collections/:id/subscribers" => "collections#subscribers"
  post "/collections/:id/subscription" => "collections#subscribe"
  delete "/collections/:id/subscription" => "collections#unsubscribe"
  post "/collections/:id/invites" => "collections#create_invite"
  get "/collections/:id/invites" => "collections#collection_invites"
  delete "/collections/:id/invites/:invite_id" => "collections#revoke_invite"
  post "/collections/invites/:invite_id/accept" => "collections#accept_invite"
  post "/collections/invites/:invite_id/reject" => "collections#reject_invite"
  delete "/collections/:id" => "collections#destroy"
end

Discourse::Application.routes.draw do
  # Engine 挂根路径:API 路由为顶层路径(不带插件名前缀,避免与资源名叠词)
  mount ::DiscourseCollection::Engine, at: "/"
end
