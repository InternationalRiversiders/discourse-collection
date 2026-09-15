import { trustHTML } from "@ember/template";
import { emojiUnescape } from "discourse/lib/text";
import { fancyTitle } from "discourse/lib/topic-fancy-title";
import { escapeExpression } from "discourse/lib/utilities";

/**
 * Renders user text this plugin carries as plain text — collection names and
 * descriptions, topic and reply excerpts — with its emoji.
 *
 * The order is core's own (components/user-status-picker.gjs) and is load-bearing:
 * emojiUnescape injects HTML and escapes nothing itself, so the text is escaped
 * first, and the result is markup, so it is marked safe last.
 */
export default function emojiText(text) {
  return trustHTML(emojiUnescape(escapeExpression(`${text ?? ""}`)));
}

/**
 * Renders a topic title: the wire's `fancy_title`, which core escapes with the emoji
 * escaped back to code (`Topic.fancy_title` runs `Emoji.unicode_unescape`, so an emoji
 * arrives as its code). Escaping it again is wrong, trusting it as it stands prints the
 * code — core reads the field through its own lib/topic-fancy-title.js#fancyTitle, and
 * this calls it.
 */
export function titleText(title, supportMixedTextDirection) {
  return trustHTML(fancyTitle(`${title ?? ""}`, supportMixedTextDirection));
}
