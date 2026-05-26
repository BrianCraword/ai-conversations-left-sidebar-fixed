# Changelog — AI Conversations Left Sidebar

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/). The version here stays in sync with
`about.json` and the `apiInitializer("x.x.x")` call.

---

## [2.0.1] — 2026-05-25

Rename editor no longer navigates into the conversation when clicked.

### Prior state
Clicking inside the inline rename input opened the conversation instead of
placing the caret. The editor appeared and was editable, but the click "fell
through" to the chat.

### Root cause
Conversation rows are themselves `<a>` anchors. The rename editor is inserted
inside that anchor, so a click anywhere within it — including in the input —
triggered the anchor's default navigation. The handlers used `stopPropagation`
only, which halts bubbling but leaves the anchor's default action intact, so the
link still fired.

### What changed
- Added `mousedown` + `click` handlers that call `preventDefault()` (not just
  `stopPropagation()`) on the editor, the rename input, the edit/delete buttons,
  and the save/cancel buttons — cancelling the anchor's navigation.
- Because preventing the `mousedown` default also suppresses the input's native
  focus, the editor explicitly refocuses the input on a non-input press, and
  leaves input presses alone so caret placement still works.

### Result
Clicking into the rename field places the caret and lets you type; it no longer
opens the conversation. Edit/delete/save/cancel presses likewise never navigate.

---

## [2.0.0] — 2026-05-25

Clean standalone rebuild of the left conversations-sidebar behavior, plus a new
rename feature.

### Prior state
The concern shipped as a patched component (search v1.x, CSS v2.2). Across its
history it had: two left-toggle elements split between this component and the
right-sidebar component (orphan bleed into the open right panel on mobile); a
left chevron that hardcoded a single native control (`.btn-sidebar-toggle`) and
therefore silently no-opped on mobile, where that control does not exist; a dead
`vc-left-sidebar-open` fallback class that nothing styled; no rename feature; no
house standards (settings/i18n/changelog); page-shell width overrides that
belong to the styling layer; and a delete-button injection that ran once on the
first pass and missed conversation rows that loaded afterward. The last item was
reproduced live this session: 40 rows present, 0 delete buttons.

### Root cause
Split ownership of the left toggle, a viewport-blind toggle mechanism, and
button injection tied to a single early pass rather than to row appearance.

### What changed
- **One owned left chevron** (`#vc-left-sidebar-toggle`) with a viewport-AWARE
  resolver chain: `.btn-sidebar-toggle` → `#toggle-hamburger-menu` →
  `.hamburger-dropdown button`. It clicks the first control that exists,
  `console.info`s which fired, and `console.warn`s if none do (so an upstream
  change surfaces instead of failing silently). Chevron direction tracks the
  real open-state class `body.has-sidebar-page`; the dead `vc-left-sidebar-open`
  appears nowhere. A mandatory mobile show-rule (`display:flex`) is included —
  without it the chevron computes `display:none` and never appears.
- **Robust button injection.** A document observer re-runs delete + edit
  injection whenever the panel or new rows appear, fixing the async-row race.
- **NEW inline rename.** A per-row edit button (`.vc-edit-btn`) swaps the row
  label for an inline input with save/cancel; on save it issues
  `PUT /t/-/:id.json { title }` — the route confirmed against current Discourse
  `topics_controller` (`PostRevisor` tracks `:title`). Enter saves, Escape
  cancels; the visible label updates on success and restores on failure.
- **Group-gated permissions.** Delete and edit are gated by `group_list`
  settings (`ai_conv_delete_allowed_groups`, `ai_conv_edit_allowed_groups`,
  default `staff`), resolved against the current user's groups, with a TL1+/staff
  fallback preserving the prior gate's intent when client group data is absent.
- **House standards added:** `settings.yml`, namespaced `locales/en.yml` (keys
  directly under the locale, resolved via `themePrefix` — the structure
  validated in the right-sidebar i18n fix), this changelog, and a single
  responsibility + boundary header in every file. Version synced.
- **Scope tightened.** Removed the `.sidebar-wrapper` 400px width override and
  the `.f-nav` hide (page-shell concerns → styling component). All `!important`
  removed from baseline; the `.vc-hidden` collapse uses panel-scoped specificity
  instead.
- **Retained verbatim in behavior:** `buildSearchBox`, the filter + Escape-clear,
  `updateHeaderVisibility` (section and flat-DOM paths), the `.vc-hidden` filter
  mechanism, delete via `ajax("/t/:id.json", DELETE)` with confirm + removal
  animation, and the SPA `onPageChange` re-init.

### Result
One chevron, one owner, one viewport-correct mechanism; buttons that survive
async row loads; a working rename path; permissions gated by group; and a
baseline the styling component can paint over without conflict.
