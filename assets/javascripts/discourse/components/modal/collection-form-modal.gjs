import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DModal from "discourse/ui-kit/d-modal";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { createCollection, updateCollection } from "../../lib/collection-api";

// The one form behind both writes on a collection: creating it (docs/03 §2) and
// renaming / re-describing it (docs/05 §1). Fields, limits and layout are identical, so
// @model.mode picks the wording (collections.create.* / collections.edit.*, two
// parallel locale blocks) and the endpoint. Only create lands the author somewhere
// new; editing leaves the page in place and hands it the updated collection.
export default class CollectionFormModal extends Component {
  @service router;
  @service siteSettings;

  @tracked description = this.args.model.description ?? "";
  @tracked name = this.args.model.name ?? "";
  @tracked showErrors = false;
  @tracked submitting = false;

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
    return i18n(`${this.#keyPrefix}.submit`);
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
  close() {
    this.args.closeModal?.();
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
  async submit() {
    this.showErrors = true;
    if (this.nameError || this.descriptionError) {
      return;
    }

    this.submitting = true;
    try {
      const collection = await this.#write();
      this.#finished(collection);
      this.close();
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.submitting = false;
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

  // A brand new collection has no page to stay on, so reading it becomes the
  // destination; an edit reports back and the page mirrors what it renders.
  #finished(collection) {
    if (this.isCreate) {
      this.router.transitionTo("collectionsShow", collection.id);
    } else {
      this.args.model.onSaved?.(collection);
    }
  }

  <template>
    <DModal @closeModal={{this.close}} @title={{this.title}}>
      <:body>
        <div class="collection-form">
          <label class="collection-form__field" for="collection-form-name">
            <span class="collection-form__label">{{this.nameLabel}}</span>
            <input
              id="collection-form-name"
              class="collection-form__input"
              maxlength={{this.nameMax}}
              type="text"
              value={{this.name}}
              {{on "input" this.updateName}}
            />
            <span class="collection-form__hint">{{this.nameConstraint}}</span>
            {{#if this.showErrors}}
              {{#if this.nameError}}
                <p class="collection-form__error">{{this.nameError}}</p>
              {{/if}}
            {{/if}}
          </label>

          <label class="collection-form__field" for="collection-form-description">
            <span class="collection-form__label">
              {{this.descriptionLabel}}
            </span>
            <textarea
              id="collection-form-description"
              class="collection-form__textarea"
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
      </:body>

      <:footer>
        <button
          type="button"
          class="btn collection-form__cancel"
          {{on "click" this.close}}
        >
          {{this.cancelLabel}}
        </button>
        <button
          type="button"
          class="btn btn-primary collection-form__submit"
          disabled={{this.submitting}}
          {{on "click" this.submit}}
        >
          {{#if this.isCreate}}
            {{dIcon "plus"}}
          {{/if}}
          {{this.submitLabel}}
        </button>
      </:footer>
    </DModal>
  </template>
}
