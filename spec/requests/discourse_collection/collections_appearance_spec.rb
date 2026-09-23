# frozen_string_literal: true

RSpec.describe DiscourseCollection::CollectionsController do
  fab!(:owner, :user)
  fab!(:maintainer, :user)
  fab!(:stranger, :user)
  fab!(:collection)

  before do
    SiteSetting.collection_enabled = true
    Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true)
    Fabricate(:collection_teamworker, collection:, user: maintainer, is_owner: false)
  end

  it "allows maintainers to change images without gaining metadata permissions" do
    sign_in(maintainer)
    image = Fabricate(:upload, user: maintainer)
    put "/collections/#{collection.id}/appearance.json", params: { avatar_upload_id: image.id }, as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("avatar_upload", "id")).to eq(image.id)
    expect(UploadReference.where(target: collection).pluck(:upload_id)).to eq([image.id])

    put "/collections/#{collection.id}.json", params: { name: "Changed" }
    expect(response.status).to eq(403)

    put "/collections/#{collection.id}/appearance.json", params: { avatar_upload_id: nil }, as: :json
    expect(response.status).to eq(200)
    expect(collection.reload.avatar_upload_id).to be_nil
    expect(UploadReference.where(target: collection)).to be_empty
    expect(Upload.exists?(image.id)).to eq(true)
  end

  it "refuses outsiders even when they uploaded the image" do
    sign_in(stranger)
    image = Fabricate(:upload, user: stranger)
    put "/collections/#{collection.id}/appearance.json", params: { avatar_upload_id: image.id }, as: :json
    expect(response.status).to eq(403)
    expect(collection.reload.avatar_upload_id).to be_nil
  end

  it "rejects foreign and secure uploads without partially changing the collection" do
    sign_in(owner)
    avatar = Fabricate(:upload, user: owner)
    [Fabricate(:upload, user: stranger), Fabricate(:upload, user: owner, secure: true)].each do |image|
      put "/collections/#{collection.id}/appearance.json",
          params: { avatar_upload_id: avatar.id, background_upload_id: image.id }, as: :json
      expect(response.status).to eq(400)
      expect(collection.reload.avatar_upload_id).to be_nil
      expect(UploadReference.where(target: collection)).to be_empty
    end
  end

  it "retains another maintainer's background when only the avatar is changed" do
    background = Fabricate(:upload, user: maintainer)
    collection.update!(background_upload_id: background.id)
    sign_in(owner)
    avatar = Fabricate(:upload, user: owner)
    put "/collections/#{collection.id}/appearance.json", params: { avatar_upload_id: avatar.id }, as: :json
    expect(response.status).to eq(200)
    expect(collection.reload.background_upload_id).to eq(background.id)
    expect(UploadReference.where(target: collection).pluck(:upload_id)).to contain_exactly(avatar.id, background.id)
  end
end
