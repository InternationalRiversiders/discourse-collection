import { on } from "@ember/modifier";
import { action } from "@ember/object";
import Component from "@glimmer/component";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

// The one confirmation whose outcome cannot be taken back: un-collecting a topic drops
// that topic's selected replies with it (docs/04 §5 / §7). So it says how many rows are at
// stake and offers a look at them, which is why it is a modal of its own instead of core's
// dialog.confirm — a dialog carries neither an extra action nor a modal on top of itself.
//
// The list it opens is a modal too, and the modal service holds one at a time, so the
// caller runs this and re-runs it after every look, and reads the answer off closeModal's
// payload (see controllers/collections-show.js and
// components/post-menu/collection-post-menu-button.gjs).
export default class RemoveTopicModal extends Component {
  // The wording belongs to the caller: the reading page already is that collection, while
  // the topic picker has to name it.
  get message() {
    return i18n(this.args.model.messageKey, {
      count: this.args.model.count,
      name: this.args.model.name,
    });
  }

  @action
  close() {
    this.args.closeModal?.();
  }

  @action
  viewReplies() {
    this.args.closeModal?.({ viewReplies: true });
  }

  @action
  confirm() {
    this.args.closeModal?.({ confirmed: true });
  }

  <template>
    <DModal
      class="remove-topic-modal"
      @closeModal={{this.close}}
      @title={{i18n "collections.topic.remove_title"}}
    >
      <:body>
        {{! Plain interpolation, so the message is escaped: the collection name inside it
        is user text and the count is a number. }}
        <p class="remove-topic__message">{{this.message}}</p>
      </:body>

      <:footer>
        <button
          type="button"
          class="btn remove-topic__view"
          {{on "click" this.viewReplies}}
        >
          {{i18n "collections.reading.view_all_replies"}}
        </button>
        <button
          type="button"
          class="btn remove-topic__cancel"
          {{on "click" this.close}}
        >
          {{i18n "cancel_value"}}
        </button>
        <button
          type="button"
          class="btn btn-danger remove-topic__confirm"
          {{on "click" this.confirm}}
        >
          {{i18n "collections.topic.uncollect"}}
        </button>
      </:footer>
    </DModal>
  </template>
}
