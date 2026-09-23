import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { createCollection, updateCollection } from "../../lib/collection-api";
import CollectionAppearanceEditor from "../collection-appearance-editor";
import CollectionAppearanceFields from "../collection-appearance-fields";

// The one form behind both writes on a collection: creating it (docs/03 §2) and
// renaming / re-describing it (docs/05 §1). Fields, limits and layout are identical, so
// @model.mode picks the wording (collections.create.* / collections.edit.*, two
// parallel locale blocks) and the endpoint. Only create lands the author somewhere
// new — unless the caller passes `onCreated` (the topic picker reopens itself around the
// form and decides what happens next); editing leaves the page in place and hands it the
// updated collection.
export default class CollectionFormModal extends Component {
  @service router;
  @service siteSettings;

  @tracked editingAppearance = this.args.model.canManageMetadata === false;
  @tracked description = this.args.model.description ?? "";
  @tracked name = this.args.model.name ?? "";
  @tracked savedName = this.args.model.name ?? "";
  @tracked savedDescription = this.args.model.description ?? "";
  @tracked saveNotice = "";
  @tracked showErrors = false;
  @tracked submitting = false;

  get hasMetadataChanges() {
    return (
      this.showMetadata &&
      (this.name.trim() !== this.savedName ||
        this.description !== this.savedDescription)
    );
  }

  get showAppearance() {
    return !this.isCreate && this.args.model.canManageAppearance;
  }

  get showMetadata() {
    return this.isCreate || this.args.model.canManageMetadata !== false;
  }

  get #keyPrefix() {
    return `collections.${this.args.model.mode}`;
  }

  get title() {
    return i18n(`${this.#keyPrefix}.title`);
  }

  get nameLabel() {
    return i18n(`${this.#keyPrefix}.name_label`);
  }

  get descriptionLabel() {
    return i18n(`${this.#keyPrefix}.description_label`);
  }

  get nameConstraint() {
    return i18n(`${this.#keyPrefix}.name_constraint`, {
      min: this.nameMin,
      max: this.nameMax,
    });
  }

  get descriptionConstraint() {
    return i18n(`${this.#keyPrefix}.description_constraint`, {
      max: this.descriptionMax,
    });
  }

  get cancelLabel() {
    return i18n(`${this.#keyPrefix}.cancel`);
  }

  get submitLabel() {
    return this.showAppearance
      ? i18n("collections.edit.save_metadata")
      : i18n(`${this.#keyPrefix}.submit`);
  }

  get isCreate() {
    return this.args.model.mode === "create";
  }

  get nameMin() {
    return this.siteSettings.collection_name_min_length;
  }

  get nameMax() {
    return this.siteSettings.collection_name_max_length;
  }

  get descriptionMax() {
    return this.siteSettings.collection_description_max_length;
  }

  get nameError() {
    const name = this.name.trim();
    if (name.length === 0) {
      return i18n(`${this.#keyPrefix}.errors.name_blank`);
    }
    if (name.length < this.nameMin || name.length > this.nameMax) {
      return i18n(`${this.#keyPrefix}.errors.name_length`, {
        min: this.nameMin,
        max: this.nameMax,
      });
    }
    return null;
  }

  get descriptionError() {
    if (this.description.length > this.descriptionMax) {
      return i18n(`${this.#keyPrefix}.errors.description_too_long`, {
        max: this.descriptionMax,
      });
    }
    return null;
  }

  @action
  selectEditor(appearance) {
    this.editingAppearance = appearance;
    this.saveNotice = "";
  }

  @action
  close() {
    if (!this.submitting) {
      this.args.closeModal?.();
    }
  }

  @action
  updateName(event) {
    this.name = event.target.value;
  }

  @action
  updateDescription(event) {
    this.description = event.target.value;
  }

  @action
  async submit(images) {
    if (this.submitting || images.uploading || !this.showMetadata) {
      return;
    }
    this.saveNotice = "";
    this.showErrors = true;
    if (this.nameError || this.descriptionError) {
      return;
    }

    this.submitting = true;
    try {
      const collection = await this.#write();
      this.#finished(collection);
      this.savedName = collection.name;
      this.savedDescription = collection.description ?? "";
      if (Object.keys(images.changes).length === 0) {
        this.args.closeModal?.();
      } else {
        this.saveNotice = i18n("collections.edit.metadata_saved");
      }
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.submitting = false;
    }
  }

  @action
  appearanceSaved(collection) {
    this.args.model.onSaved?.(collection);
    if (!this.hasMetadataChanges) {
      this.args.closeModal?.();
    } else {
      this.saveNotice = i18n("collections.edit.images_saved");
    }
  }

  #write() {
    const attributes = {
      name: this.name.trim(),
      description: this.description,
    };
    if (this.isCreate) {
      return createCollection(attributes);
    }
    return updateCollection(this.args.model.id, attributes);
  }

  // A brand new collection has no page to stay on, so reading it becomes the destination
  // unless the caller passes `onCreated` and decides for itself (the topic picker reopens
  // itself around the form). An edit reports back and the page mirrors what it renders.
  #finished(collection) {
    if (!this.isCreate) {
      this.args.model.onSaved?.(collection);
    } else if (this.args.model.onCreated) {
      this.args.model.onCreated(collection);
    } else {
      this.router.transitionTo("collectionsShow", collection.id);
    }
  }

  <template>
    <CollectionAppearanceEditor
      @closeModal={{this.close}}
      @enabled={{this.showAppearance}}
      @model={{@model}}
      @onSaved={{this.appearanceSaved}}
      as |images|
    >
      <DModal @closeModal={{images.close}} @title={{this.title}}>
        <:body>
          {{#if this.showAppearance}}
            {{#if this.showMetadata}}
              <div
                aria-label={{this.title}}
                class="collection-form__tabs"
                role="group"
              >
                <DButton
                  aria-pressed={{if this.editingAppearance "false" "true"}}
                  @action={{fn this.selectEditor false}}
                  @disabled={{or this.submitting images.saving}}
                  @label="collections.edit.basic_info"
                />
                <DButton
                  aria-pressed={{if this.editingAppearance "true" "false"}}
                  @action={{fn this.selectEditor true}}
                  @disabled={{or this.submitting images.saving}}
                  @label="collections.appearance.edit"
                />
              </div>
            {{/if}}
            <div
              class="collection-form-panel"
              hidden={{if this.editingAppearance false true}}
            >
              <CollectionAppearanceFields @editor={{images}} />
            </div>
          {{/if}}
          {{#if this.showMetadata}}
            <div
              class="collection-form collection-form-panel"
              hidden={{this.editingAppearance}}
            >
              <label class="collection-form__field" for="collection-form-name">
                <span class="collection-form__label">{{this.nameLabel}}</span>
                <input
                  class="collection-form__input"
                  disabled={{this.submitting}}
                  id="collection-form-name"
                  maxlength={{this.nameMax}}
                  type="text"
                  value={{this.name}}
                  {{on "input" this.updateName}}
                />
                <span
                  class="collection-form__hint"
                >{{this.nameConstraint}}</span>
                {{#if this.showErrors}}
                  {{#if this.nameError}}
                    <p class="collection-form__error">{{this.nameError}}</p>
                  {{/if}}
                {{/if}}
              </label>

              <label
                class="collection-form__field"
                for="collection-form-description"
              >
                <span class="collection-form__label">
                  {{this.descriptionLabel}}
                </span>
                <textarea
                  class="collection-form__textarea"
                  disabled={{this.submitting}}
                  id="collection-form-description"
                  maxlength={{this.descriptionMax}}
                  rows="3"
                  value={{this.description}}
                  {{on "input" this.updateDescription}}
                ></textarea>
                <span class="collection-form__hint">
                  {{this.descriptionConstraint}}
                </span>
                {{#if this.showErrors}}
                  {{#if this.descriptionError}}
                    <p class="collection-form__error">
                      {{this.descriptionError}}
                    </p>
                  {{/if}}
                {{/if}}
              </label>
            </div>
          {{/if}}
          {{#if this.saveNotice}}
            <p
              class="collection-form__save-notice"
              role="status"
            >{{this.saveNotice}}</p>
          {{/if}}
        </:body>

        <:footer>
          {{#if this.editingAppearance}}
            <DButton
              class="btn-primary collection-appearance__save"
              @action={{images.save}}
              @disabled={{images.saveDisabled}}
              @label="collections.edit.save_images"
            />
            <DButton
              @action={{images.close}}
              @disabled={{images.saving}}
              @label="cancel"
            />
          {{else}}
            <button
              class="btn collection-form__cancel"
              type="button"
              {{on "click" this.close}}
            >
              {{this.cancelLabel}}
            </button>
            <button
              class="btn btn-primary collection-form__submit"
              disabled={{or this.submitting images.uploading}}
              type="button"
              {{on "click" (fn this.submit images)}}
            >
              {{#if this.isCreate}}
                {{dIcon "plus"}}
              {{/if}}
              {{this.submitLabel}}
            </button>
          {{/if}}
        </:footer>
      </DModal>
    </CollectionAppearanceEditor>
  </template>
}
