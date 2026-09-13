import { escapeExpression } from "discourse/lib/utilities";
import { i18n } from "discourse-i18n";

// Core's confirm dialog takes its message ALREADY TRANSLATED but its button label as
// an i18n KEY — d-button translates that one again. Passing the wrong kind lands in
// discourse-i18n's missing-translation fallback (a literal `[zh_CN.取消收录]` on the
// button), which is why the asymmetry lives here once instead of at every call site.
//
// The message renders as trusted HTML and a collection name is user text — the
// server only strips and length-checks it — so interpolated values are escaped.
//
// Deletion is red plugin-wide, so that is the default; a non-destructive confirm
// (accepting an invitation) opts out with danger: false.
export function confirmAction(
  dialog,
  { messageKey, labelKey, replacements = {}, danger = true }
) {
  const escaped = Object.fromEntries(
    Object.entries(replacements).map(([key, value]) => [
      key,
      escapeExpression(`${value}`),
    ])
  );

  return dialog.confirm({
    message: i18n(messageKey, escaped),
    confirmButtonLabel: labelKey,
    ...(danger ? { confirmButtonClass: "btn-danger" } : {}),
  });
}
