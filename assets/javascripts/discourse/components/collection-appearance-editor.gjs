import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import { popupAjaxError } from "discourse/lib/ajax-error";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import { i18n } from "discourse-i18n";
import { updateCollectionAppearance } from "../lib/collection-api";

export default class CollectionAppearanceEditor extends Component {
  @service dialog;

  @tracked avatar = this.args.model.avatar_upload ?? null;
  @tracked background = this.args.model.background_upload ?? null;
  @tracked saving = false;
  @tracked savedAvatarId = this.args.model.avatar_upload?.id ?? null;
  @tracked savedBackgroundId = this.args.model.background_upload?.id ?? null;

  avatarUploader = this.args.enabled ? this.#makeUploader("avatar") : null;
  backgroundUploader = this.args.enabled
    ? this.#makeUploader("background")
    : null;

  willDestroy() {
    super.willDestroy(...arguments);
    this.avatarUploader?.teardown();
    this.backgroundUploader?.teardown();
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
      this.avatarUploader?.uploading ||
      this.avatarUploader?.processing ||
      this.backgroundUploader?.uploading ||
      this.backgroundUploader?.processing
    );
  }

  get changes() {
    const changes = {};
    for (const key of ["avatar", "background"]) {
      const id = this[key]?.id ?? null;
      if (
        id !== (key === "avatar" ? this.savedAvatarId : this.savedBackgroundId)
      ) {
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
      this.savedAvatarId = this.avatar?.id ?? null;
      this.savedBackgroundId = this.background?.id ?? null;
      this.args.onSaved(collection);
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

  <template>{{yield this}}</template>
}
