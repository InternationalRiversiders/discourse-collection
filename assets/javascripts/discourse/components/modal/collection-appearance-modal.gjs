import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import { popupAjaxError } from "discourse/lib/ajax-error";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DPickFilesButton from "discourse/ui-kit/d-pick-files-button";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { updateCollectionAppearance } from "../../lib/collection-api";

export default class CollectionAppearanceModal extends Component {
  @service dialog;

  @tracked avatar = this.args.model.avatar_upload ?? null;
  @tracked background = this.args.model.background_upload ?? null;
  @tracked saving = false;

  avatarUploader = this.#makeUploader("avatar");
  backgroundUploader = this.#makeUploader("background");

  willDestroy() {
    super.willDestroy(...arguments);
    this.avatarUploader.teardown();
    this.backgroundUploader.teardown();
  }

  get fields() {
    return [
      {
        key: "avatar",
        image: this.avatar,
        uploader: this.avatarUploader,
        label: i18n("collections.appearance.avatar"),
      },
      {
        key: "background",
        image: this.background,
        uploader: this.backgroundUploader,
        label: i18n("collections.appearance.background"),
      },
    ];
  }

  get uploading() {
    return (
      this.avatarUploader.uploading ||
      this.avatarUploader.processing ||
      this.backgroundUploader.uploading ||
      this.backgroundUploader.processing
    );
  }

  get changes() {
    const changes = {};
    for (const key of ["avatar", "background"]) {
      const id = this[key]?.id ?? null;
      if (id !== (this.args.model[`${key}_upload`]?.id ?? null)) {
        changes[`${key}_upload_id`] = id;
      }
    }
    return changes;
  }

  get disabled() {
    return this.saving || this.uploading;
  }

  get saveDisabled() {
    return this.disabled || Object.keys(this.changes).length === 0;
  }

  @action
  remove(key) {
    this.#setImage(key, null);
  }

  @action
  close() {
    if (!this.saving) {
      this.args.closeModal();
    }
  }

  @action
  async save() {
    if (this.saveDisabled) {
      return;
    }
    this.saving = true;
    try {
      const collection = await updateCollectionAppearance(
        this.args.model.id,
        this.changes
      );
      this.args.model.onSaved(collection);
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  #makeUploader(key) {
    return new UppyUpload(getOwner(this), {
      id: `collection-${key}`,
      type: `collection_${key}`,
      maxFiles: 1,
      validateUploadedFilesOptions: { imagesOnly: true },
      isUploadedFileAllowed: (file) => {
        if (/\.(jpe?g|png|gif|webp)$/i.test(file.name)) {
          return true;
        }
        this.dialog.alert(i18n("collections.appearance.hint"));
        return false;
      },
      uploadDone: (upload) => {
        if (!this.isDestroying) {
          this.#setImage(key, upload);
        }
      },
    });
  }

  #setImage(key, upload) {
    if (key === "avatar") {
      this.avatar = upload;
    } else {
      this.background = upload;
    }
  }

  <template>
    <DModal
      @closeModal={{this.close}}
      @title={{i18n "collections.appearance.title"}}
    >
      <:body>
        <div class="collection-appearance">
          <p class="collection-appearance__hint">{{i18n
              "collections.appearance.hint"
            }}</p>
          {{#each this.fields key="key" as |field|}}
            <section class="collection-appearance__field --{{field.key}}">
              <h3>{{field.label}}</h3>
              <div class="collection-appearance__preview">
                {{#if field.image}}
                  <img alt={{field.label}} src={{field.image.url}} />
                {{else}}
                  {{dIcon "collection"}}
                {{/if}}
              </div>
              <div class="collection-appearance__controls">
                <label
                  class="btn btn-default collection-appearance__picker
                    {{if this.disabled 'disabled'}}"
                  for="collection-{{field.key}}-file"
                >
                  {{dIcon "upload"}}
                  {{i18n "collections.appearance.upload"}}
                  <DPickFilesButton
                    @acceptedFormatsOverride=".jpg,.jpeg,.png,.gif,.webp"
                    @fileInputDisabled={{this.disabled}}
                    @fileInputId="collection-{{field.key}}-file"
                    @registerFileInput={{field.uploader.setup}}
                  />
                </label>
                {{#if field.image}}
                  <DButton
                    @action={{fn this.remove field.key}}
                    @disabled={{this.disabled}}
                    @icon="trash-can"
                    @label="collections.appearance.remove"
                  />
                {{/if}}
              </div>
            </section>
          {{/each}}
          <p class="collection-appearance__hint" role="status">
            {{#if this.uploading}}
              {{i18n "collections.appearance.uploading"}}
            {{else}}
              {{i18n "collections.appearance.public_hint"}}
            {{/if}}
          </p>
        </div>
      </:body>
      <:footer>
        <DButton
          class="btn-primary collection-appearance__save"
          @action={{this.save}}
          @disabled={{this.saveDisabled}}
          @label="collections.appearance.save"
        />
        <DButton
          @action={{this.close}}
          @disabled={{this.saving}}
          @label="cancel"
        />
      </:footer>
    </DModal>
  </template>
}
