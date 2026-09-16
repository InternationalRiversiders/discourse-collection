import { on } from "@ember/modifier";
import { action } from "@ember/object";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";
import { updateTopicNote } from "../../lib/collection-api";
import emojiText from "../../lib/emoji-text";

// Mirrors CollectionTopic::NOTE_MAX_LENGTH — the note column's own limit. The editor stops
// the text at it; the endpoint rejects anything longer with a 422 (docs/04 §4) regardless.
const NOTE_MAX_LENGTH = 100;

/**
 * The note editor the topic page's picker opens on its pencil (docs/04 §4). The picker reads
 * the note it opens on first (docs/04 §8) and hands it over, so this modal only edits. An
 * emptied box saves "", which the server stores as nil: blank is the clear gesture, not a
 * lost note.
 *
 * It is a modal of its own and the modal service holds one at a time, so the picker goes
 * down with it and is reopened by the caller once the editing is over — the same exchange
 * as the create form.
 */
export default class CollectionNoteModal extends Component {
  @tracked noteDraft = this.args.model.note ?? "";
  @tracked saving = false;

  @action
  close() {
    this.args.closeModal?.();
  }

  @action
  updateDraft(event) {
    this.noteDraft = event.target.value;
  }

  @action
  async save() {
    this.saving = true;
    try {
      await updateTopicNote(
        this.args.model.collectionId,
        this.args.model.topicId,
        this.noteDraft
      );
      this.close();
    } catch (err) {
      popupAjaxError(err);
    } finally {
      this.saving = false;
    }
  }

  <template>
    <DModal
      class="collection-note-modal"
      @closeModal={{this.close}}
      @title={{i18n "collections.reading.edit_note"}}
    >
      <:body>
        <div class="collection-note">
          {{! The row that opened this carried the collection's name, and the editor has
          taken the picker's place, so the name is restated here. }}
          <p class="collection-note__collection">
            {{emojiText this.args.model.collectionName}}
          </p>
          <textarea
            class="collection-note__input"
            rows="3"
            maxlength={{NOTE_MAX_LENGTH}}
            placeholder={{i18n "collections.reading.note_placeholder"}}
            value={{this.noteDraft}}
            {{on "input" this.updateDraft}}
          ></textarea>
        </div>
      </:body>

      <:footer>
        <button
          type="button"
          class="btn collection-note__cancel"
          {{on "click" this.close}}
        >
          {{i18n "collections.reading.cancel_note"}}
        </button>
        <button
          type="button"
          class="btn btn-primary collection-note__save"
          disabled={{this.saving}}
          {{on "click" this.save}}
        >
          {{i18n "collections.reading.save_note"}}
        </button>
      </:footer>
    </DModal>
  </template>
}
