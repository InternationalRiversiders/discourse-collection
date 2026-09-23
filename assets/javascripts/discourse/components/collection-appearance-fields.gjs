import { fn } from "@ember/helper";
import DButton from "discourse/ui-kit/d-button";
import DPickFilesButton from "discourse/ui-kit/d-pick-files-button";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

export default <template>
  <div class="collection-appearance">
    <p class="collection-appearance__hint">{{i18n
        "collections.appearance.hint"
      }}</p>
    {{#each @editor.fields key="key" as |field|}}
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
              {{if @editor.disabled 'disabled'}}"
            for="collection-{{field.key}}-file"
          >
            {{dIcon "upload"}}
            {{i18n "collections.appearance.upload"}}
            <DPickFilesButton
              @acceptedFormatsOverride=".jpg,.jpeg,.png,.gif,.webp"
              @fileInputDisabled={{@editor.disabled}}
              @fileInputId="collection-{{field.key}}-file"
              @registerFileInput={{field.uploader.setup}}
            />
          </label>
          {{#if field.image}}
            <DButton
              @action={{fn @editor.remove field.key}}
              @disabled={{@editor.disabled}}
              @icon="trash-can"
              @label="collections.appearance.remove"
            />
          {{/if}}
        </div>
      </section>
    {{/each}}
    <p class="collection-appearance__hint" role="status">
      {{#if @editor.uploading}}
        {{i18n "collections.appearance.uploading"}}
      {{else}}
        {{i18n "collections.appearance.public_hint"}}
      {{/if}}
    </p>
  </div>
</template>
