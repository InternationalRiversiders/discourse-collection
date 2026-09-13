import DUserLink from "discourse/ui-kit/d-user-link";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";

// The one way this plugin draws a user: avatar, then username, as core's own user link —
// an anchor to the profile carrying the `data-user-card` hook that opens their card (the
// gesture core's own topic lists use). The user hash is whatever the server sent for
// them: the `users` entry a reading row's user_id points at (docs/04 §1), or a
// collection's owner, one of its team, an invitation's inviter or invitee. No user drawn
// means no entry — an account that is gone leaves nothing behind.
//
// Face and name are one target, so they are one anchor: a second link beside the first
// would send the same click two ways. It must also stay an anchor of its own, never
// nested inside another link: an Ember LinkTo around it prevents the click, and core's
// card handler skips a prevented click. `@hideTitle` drops the avatar's tooltip where
// the name beside it already says the same.
export default <template>
  {{#if @user}}
    <DUserLink class="collection-user" @username={{@user.username}} ...attributes>
      {{dAvatar @user imageSize="small" hideTitle=@hideTitle}}
      <span class="collection-user__username">{{@user.username}}</span>
    </DUserLink>
  {{/if}}
</template>;
