# frozen_string_literal: true

RSpec.describe DiscourseCollection::Collection::Update do
  fab!(:owner, :user)
  fab!(:other_user, :user)
  fab!(:admin, :admin)

  def add_owned_collection(user)
    Fabricate(:collection, name: "Original", topic_count: 7).tap do |collection|
      Fabricate(:collection_teamworker, collection:, user:, is_owner: true)
    end
  end

  describe described_class::Contract, type: :model do
    subject(:contract) { described_class.new(**params) }

    let(:params) { { name: "Renamed", description: "" } }

    context "with a name and/or description" do
      it { is_expected.to be_valid }
    end

    context "with neither name nor description" do
      let(:params) { {} }

      it "is invalid" do
        expect(contract).not_to be_valid
        expect(contract.errors[:base]).to include(
          I18n.t("discourse_collection.errors.nothing_to_update"),
        )
      end
    end

    context "with a blank name" do
      let(:params) { { name: "   " } }

      it "is invalid" do
        expect(contract).not_to be_valid
      end
    end

    context "with a name longer than the maximum" do
      let(:params) { { name: "a" * (SiteSetting.collection_name_max_length + 1) } }

      it "is invalid" do
        expect(contract).not_to be_valid
      end
    end
  end

  describe "staff-action registration (docs/10 §3)" do
    it "registers the audit custom types in UserHistory.staff_actions" do
      expect(UserHistory.staff_actions).to include(
        :collection_name_change,
        :collection_intro_change,
        :collection_topic_note_change,
        :collection_owner_change,
      )
    end
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    let(:collection) { add_owned_collection(owner) }
    let(:guardian) { Guardian.new(actor) }
    let(:dependencies) { { guardian: } }
    let(:actor) { owner }
    let(:params) { { id: collection.id, name: "Renamed" } }

    context "when the contract fails" do
      let(:params) { { id: collection.id, name: "" } }

      it { is_expected.to fail_a_contract }
    end

    context "when the collection does not exist" do
      let(:params) { { id: -999, name: "Renamed" } }

      it { is_expected.to fail_to_find_a_model(:collection) }
    end

    context "when the acting user is an outsider" do
      let(:actor) { other_user }

      it { is_expected.to fail_a_policy(:can_manage_metadata) }
    end

    context "when the acting user is the owner" do
      it { is_expected.to run_successfully }

      it "renames the collection and bumps updated_at without touching counts" do
        collection.update!(updated_at: 1.day.ago)

        expect { result }.to change { collection.reload.name }.from("Original").to("Renamed")

        expect(collection.topic_count).to eq(7)
        expect(collection.updated_at).to be > 1.day.ago
      end

      it "can clear the description with an empty string" do
        collection.update!(description: "something")

        params[:description] = ""

        expect { result }.to change { collection.reload.description }.to("")
      end

      it "does not log an audit row for a routine owner rename" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_name_change").count
        }
      end
    end

    context "when the acting user is staff managing someone else's collection" do
      let(:actor) { admin }

      it { is_expected.to run_successfully }

      it "renames the collection" do
        expect { result }.to change { collection.reload.name }.from("Original").to("Renamed")
      end

      it "logs a collection_name_change audit row (old name in context, docs/10 §2)" do
        result

        history = UserHistory.find_by(custom_type: "collection_name_change")
        expect(history).to be_present
        expect(history.action).to eq(UserHistory.actions[:custom_staff])
        expect(history.acting_user_id).to eq(admin.id)
        expect(history.subject).to eq("Collection (#{collection.id})")
        expect(history.context).to eq("Original")
        expect(history.previous_value).to eq("Original")
        expect(history.new_value).to eq("Renamed")
      end
    end

    context "when an admin renames a collection they own" do
      let(:actor) { admin }
      let(:collection) { add_owned_collection(admin) }

      it { is_expected.to run_successfully }

      it "renames the collection" do
        expect { result }.to change { collection.reload.name }.from("Original").to("Renamed")
      end

      it "logs nothing (staff standing was not needed, docs/10 §1)" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_name_change").count
        }
      end
    end

    context "when an admin changes the description of a collection they own" do
      let(:actor) { admin }
      let(:collection) { add_owned_collection(admin) }
      let(:params) { { id: collection.id, description: "new desc" } }

      before { collection.update!(description: "old desc") }

      it { is_expected.to run_successfully }

      it "logs nothing (staff standing was not needed, docs/10 §1)" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_intro_change").count
        }
      end
    end

    context "when an admin co-maintaining the collection renames it" do
      let(:actor) { admin }
      let(:collection) { add_owned_collection(owner) }

      before { Fabricate(:collection_teamworker, collection:, user: admin, is_owner: false) }

      it { is_expected.to run_successfully }

      it "logs the name change (a co-maintainer holds no metadata edit of their own)" do
        expect { result }.to change {
          UserHistory.where(custom_type: "collection_name_change").count
        }.by(1)
      end
    end

    context "when staff resubmit the same name" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, name: "Original" } }

      it { is_expected.to run_successfully }

      it "does not log a name change (nothing was renamed)" do
        expect { result }.not_to change {
          UserHistory.where(custom_type: "collection_name_change").count
        }
      end
    end

    context "when staff change the description of someone else's collection" do
      let(:actor) { admin }
      let(:params) { { id: collection.id, description: "new desc" } }

      before { collection.update!(description: "old desc") }

      it { is_expected.to run_successfully }

      it "logs a collection_intro_change audit row" do
        result

        history = UserHistory.find_by(custom_type: "collection_intro_change")
        expect(history).to be_present
        expect(history.action).to eq(UserHistory.actions[:custom_staff])
        expect(history.acting_user_id).to eq(admin.id)
        expect(history.subject).to eq("Collection (#{collection.id})")
        expect(history.context).to eq("Original")
        expect(history.previous_value).to eq("old desc")
        expect(history.new_value).to eq("new desc")
      end
    end
  end
end
