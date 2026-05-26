/* ============================================================================
   AI CONVERSATIONS LEFT SIDEBAR — api-initializer
   ----------------------------------------------------------------------------
   SINGLE RESPONSIBILITY:
     Behavior for the LEFT conversations sidebar —
       • live filter/search over conversation rows,
       • per-row DELETE (deletes the underlying topic),
       • per-row EDIT / rename (new),
       • the ONE left chevron (#vc-left-sidebar-toggle) that opens/closes the
         native Discourse conversations sidebar.

   THIS COMPONENT DOES NOT OWN (the boundary):
     - The right (AI Memories) sidebar or right chevron (#vc-sidebar-toggle).
       It injects NO right toggle and reads body.vc-right-sidebar-open only to
       hide its own chevron when the right panel is open.
     - The greeting / title.
     - The cohesive visual system / page-shell width / grid. Ship only BASELINE
       styling for this component's own injected elements; widths and the grid
       belong to the styling component (built last).

   v2.0.0 (clean rebuild) — PRIOR STATE: the concern shipped with two left-toggle
     elements split across two components, a left chevron that hardcoded a single
     native control (`.btn-sidebar-toggle`) and therefore silently no-opped on the
     viewport where that control is absent, a dead `vc-left-sidebar-open` fallback
     class, no rename feature, no house standards, and a delete-button injection
     that raced the async row render (rows arrived after injection ran → no
     buttons). ROOT CAUSE: split ownership, a viewport-blind mechanism, and
     injection timing tied to a single early pass. WHAT CHANGED: one owned left
     chevron with a viewport-AWARE resolver chain (.btn-sidebar-toggle →
     #toggle-hamburger-menu → .hamburger-dropdown button, console.info which
     fired, console.warn if none); a robust row observer that (re)injects delete +
     edit buttons whenever rows appear; a NEW inline rename feature
     (PUT /t/-/:id.json {title}, confirmed against current Discourse source);
     group-gated permissions; namespaced i18n via themePrefix; and house
     standards. RESULT: one chevron, one owner, one reliable mechanism that works
     on both viewports, buttons that survive async row loads, and a rename path.
   ============================================================================ */

import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

export default apiInitializer("2.0.1", (api) => {
  const log = (...a) => console.log("[ai-left-sidebar]", ...a);

  // themePrefix is auto-injected in theme-component .gjs (do not import it).
  const t = (key, opts) => i18n(themePrefix(`ai_conv_left_sidebar.${key}`), opts);

  // --- Selectors ------------------------------------------------------------
  const PANEL_SELECTOR = ".sidebar-sections.ai-conversations-panel";
  const SEARCH_WRAPPER_ID = "vc-sidebar-search";
  const FILTER_INPUT_ID = "vc-sidebar-filter";
  const ROW_SELECTOR = ".sidebar-section-link.sidebar-row";
  const HEADER_SELECTOR = ".sidebar-section-header";
  const SECTION_SELECTOR = ".sidebar-section";
  const LEFT_TOGGLE_ID = "vc-left-sidebar-toggle";

  // Viewport-aware resolver chain for the native conversations-sidebar control.
  // Desktop exposes `.btn-sidebar-toggle`; mobile exposes `#toggle-hamburger-menu`.
  // Never hardcode one — the absent one silently no-ops on the other viewport.
  const NATIVE_TOGGLE_CHAIN = [
    ".btn-sidebar-toggle",
    "#toggle-hamburger-menu",
    ".hamburger-dropdown button",
  ];

  // --- Settings / permissions ----------------------------------------------

  function componentEnabled() {
    return settings.ai_conv_left_sidebar_enabled !== false;
  }
  function filterEnabled() {
    return settings.ai_conv_filter_enabled !== false;
  }

  // Resolve a comma/pipe-separated group_list setting into a name array.
  function parseGroups(raw) {
    if (!raw) return [];
    return String(raw)
      .split(/[|,]/)
      .map((s) => s.trim())
      .filter(Boolean);
  }

  // Is the current user in any of the named groups? "staff" is treated as a
  // virtual group (admin || moderator). Falls back to TL1+/staff if group data
  // is unavailable, preserving the prior gate's intent.
  function userInGroups(groupNames) {
    const user = api.getCurrentUser?.();
    if (!user) return false;
    if (!groupNames || groupNames.length === 0) return false;
    const wantsStaff = groupNames.includes("staff");
    if (wantsStaff && (user.staff || user.admin || user.moderator)) return true;
    const userGroups = (user.groups || []).map((g) => g.name);
    if (groupNames.some((g) => g !== "staff" && userGroups.includes(g))) return true;
    // Fallback when client group data isn't present: keep prior TL1+/staff intent.
    if (userGroups.length === 0) {
      return user.staff || user.trust_level >= 1;
    }
    return false;
  }

  function canDelete() {
    return userInGroups(parseGroups(settings.ai_conv_delete_allowed_groups || "staff"));
  }
  function canEdit() {
    return userInGroups(parseGroups(settings.ai_conv_edit_allowed_groups || "staff"));
  }
  // Anyone allowed to do anything in the sidebar (gate for filter + chevron too,
  // mirroring the prior staff||TL1 gate).
  function isAllowedUser() {
    const user = api.getCurrentUser?.();
    if (!user) return false;
    return user.staff || user.trust_level >= 1;
  }

  // --- Helpers --------------------------------------------------------------

  function topicIdFromRow(row) {
    const m = row.className.match(/ai-conversation-(\d+)/);
    return m ? m[1] : null;
  }

  // The visible label element within a row (used by rename to update in place).
  function rowLabelEl(row) {
    return (
      row.querySelector(".sidebar-section-link-content-text") ||
      row.querySelector(".sidebar-section-link-content") ||
      row
    );
  }

  // --- Search box -----------------------------------------------------------

  function buildSearchBox() {
    const wrapper = document.createElement("div");
    wrapper.id = SEARCH_WRAPPER_ID;
    wrapper.className = "vc-search-wrapper";
    const group = document.createElement("div");
    group.className = "vc-search-input-group";
    const input = document.createElement("input");
    input.type = "text";
    input.className = "vc-search-input";
    input.id = FILTER_INPUT_ID;
    input.placeholder = t("filter_placeholder");
    input.autocomplete = "off";
    const icon = document.createElement("span");
    icon.className = "vc-search-icon";
    icon.textContent = "🔍";
    group.append(input, icon);
    wrapper.appendChild(group);
    return wrapper;
  }

  // --- Delete + Edit buttons ------------------------------------------------

  function injectRowButtons(panel) {
    const allowDelete = canDelete();
    const allowEdit = canEdit();
    if (!allowDelete && !allowEdit) return;

    panel.querySelectorAll(ROW_SELECTOR).forEach((row) => {
      const topicId = topicIdFromRow(row);
      if (!topicId) return;

      // EDIT button (added before delete so the layout reads edit | delete)
      if (allowEdit && !row.querySelector(".vc-edit-btn")) {
        const editBtn = document.createElement("button");
        editBtn.className = "vc-edit-btn";
        editBtn.setAttribute("data-topic-id", topicId);
        editBtn.setAttribute("aria-label", t("edit_label"));
        editBtn.setAttribute("title", t("edit_label"));
        editBtn.textContent = "✎";
        editBtn.addEventListener("mousedown", (e) => {
          e.preventDefault();
          e.stopPropagation();
        });
        editBtn.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          startInlineRename(row, topicId, panel);
        });
        row.appendChild(editBtn);
      }

      // DELETE button
      if (allowDelete && !row.querySelector(".vc-delete-btn")) {
        const deleteBtn = document.createElement("button");
        deleteBtn.className = "vc-delete-btn";
        deleteBtn.setAttribute("data-topic-id", topicId);
        deleteBtn.setAttribute("aria-label", t("delete_label"));
        deleteBtn.setAttribute("title", t("delete_label"));
        deleteBtn.textContent = "×";
        deleteBtn.addEventListener("mousedown", (e) => {
          e.preventDefault();
          e.stopPropagation();
        });
        deleteBtn.addEventListener("click", async (e) => {
          e.preventDefault();
          e.stopPropagation();
          // eslint-disable-next-line no-alert
          if (!window.confirm(t("delete_confirm"))) return;
          try {
            await ajax(`/t/${topicId}.json`, { type: "DELETE" });
            row.style.transition = "opacity 0.3s, transform 0.3s";
            row.style.opacity = "0";
            row.style.transform = "translateX(-20px)";
            setTimeout(() => {
              row.remove();
              updateHeaderVisibility(panel);
              log("Deleted conversation:", topicId);
            }, 300);
          } catch (err) {
            console.error("[ai-left-sidebar] Delete error:", err);
            // eslint-disable-next-line no-alert
            window.alert(t("delete_failed"));
          }
        });
        row.appendChild(deleteBtn);
      }
    });
  }

  // --- Inline rename --------------------------------------------------------
  // Replaces the row label with an input + save/cancel. On save, PUT the topic
  // title (PUT /t/-/:id.json {title}) — confirmed against current Discourse
  // topics_controller (PostRevisor tracked field :title). Updates the visible
  // label on success; restores original on cancel/failure.

  function startInlineRename(row, topicId, panel) {
    if (row.querySelector(".vc-rename-input")) return; // already editing
    const labelEl = rowLabelEl(row);
    const original = labelEl.textContent.trim();

    row.classList.add("vc-renaming");
    const prevDisplay = labelEl.style.display;
    labelEl.style.display = "none";

    const editor = document.createElement("span");
    editor.className = "vc-rename-editor";

    const input = document.createElement("input");
    input.type = "text";
    input.className = "vc-rename-input";
    input.value = original;

    const save = document.createElement("button");
    save.className = "vc-rename-save";
    save.setAttribute("aria-label", t("edit_save_label"));
    save.setAttribute("title", t("edit_save_label"));
    save.textContent = "✓";

    const cancel = document.createElement("button");
    cancel.className = "vc-rename-cancel";
    cancel.setAttribute("aria-label", t("edit_cancel_label"));
    cancel.setAttribute("title", t("edit_cancel_label"));
    cancel.textContent = "×";

    editor.append(input, save, cancel);
    labelEl.parentElement.insertBefore(editor, labelEl);

    const teardown = (newText) => {
      editor.remove();
      labelEl.style.display = prevDisplay;
      row.classList.remove("vc-renaming");
      if (newText != null) labelEl.textContent = newText;
    };

    const commit = async () => {
      const newTitle = input.value.trim();
      if (!newTitle) {
        // eslint-disable-next-line no-alert
        window.alert(t("edit_empty"));
        input.focus();
        return;
      }
      if (newTitle === original) {
        teardown(null);
        return;
      }
      save.disabled = true;
      cancel.disabled = true;
      try {
        await ajax(`/t/-/${topicId}.json`, {
          type: "PUT",
          data: { title: newTitle },
        });
        teardown(newTitle);
        log("Renamed conversation:", topicId, "→", newTitle);
      } catch (err) {
        console.error("[ai-left-sidebar] Rename error:", err);
        // eslint-disable-next-line no-alert
        window.alert(t("edit_failed"));
        teardown(null); // restore original label
      }
    };

    save.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
    });
    save.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      commit();
    });
    cancel.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
    });
    cancel.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      teardown(null);
    });
    // The conversation row is itself an <a>, so a click anywhere inside it —
    // including inside our editor input — triggers the anchor's navigation
    // unless we cancel the default. stopPropagation alone is NOT enough (it
    // stops bubbling but leaves the anchor's default navigation intact), which
    // is why clicking into the field used to open the conversation. We cancel
    // the default at BOTH mousedown (where the anchor activates / focus is
    // stolen) and click, on the editor and the input. Because preventing the
    // mousedown default also suppresses the input's native focus, we refocus it
    // explicitly. Clicks on the editor chrome (not the input) keep focus where
    // the user expects.
    const swallow = (e) => {
      e.preventDefault();
      e.stopPropagation();
    };
    editor.addEventListener("mousedown", (e) => {
      e.stopPropagation();
      // Only block default (and refocus) when the press is NOT already on the
      // input, so the input's own caret placement still works.
      if (e.target !== input) {
        e.preventDefault();
        input.focus();
      }
    });
    editor.addEventListener("click", swallow);
    input.addEventListener("mousedown", (e) => e.stopPropagation());
    input.addEventListener("click", (e) => e.stopPropagation());
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") {
        e.preventDefault();
        commit();
      } else if (e.key === "Escape") {
        e.preventDefault();
        teardown(null);
      }
    });

    input.focus();
    input.select();
  }

  // --- Header visibility ----------------------------------------------------

  function updateHeaderVisibility(panel) {
    const sections = panel.querySelectorAll(SECTION_SELECTOR);
    if (sections.length > 0) {
      sections.forEach((section) => {
        const header = section.querySelector(HEADER_SELECTOR);
        const allRows = section.querySelectorAll(ROW_SELECTOR);
        const visibleRows = section.querySelectorAll(`${ROW_SELECTOR}:not(.vc-hidden)`);
        if (header && allRows.length > 0) {
          header.classList.toggle("vc-hidden", visibleRows.length === 0);
        }
      });
    } else {
      const headers = panel.querySelectorAll(HEADER_SELECTOR);
      headers.forEach((header, idx) => {
        const nextHeader = headers[idx + 1];
        let hasVisibleItem = false;
        let sibling = header.nextElementSibling;
        while (sibling && sibling !== nextHeader) {
          if (sibling.matches && sibling.matches(ROW_SELECTOR)) {
            if (!sibling.classList.contains("vc-hidden")) {
              hasVisibleItem = true;
              break;
            }
          }
          const row = sibling.querySelector?.(ROW_SELECTOR);
          if (row && !row.classList.contains("vc-hidden")) {
            hasVisibleItem = true;
            break;
          }
          sibling = sibling.nextElementSibling;
        }
        header.classList.toggle("vc-hidden", !hasVisibleItem);
        const wrapper = header.closest(".sidebar-section-header-wrapper");
        if (wrapper) wrapper.classList.toggle("vc-hidden", !hasVisibleItem);
      });
    }
  }

  // --- Filter ---------------------------------------------------------------

  function filterConversations(panel, query) {
    const normalized = query.toLowerCase().trim();
    panel.querySelectorAll(ROW_SELECTOR).forEach((row) => {
      const matches = normalized === "" || row.textContent.toLowerCase().includes(normalized);
      row.classList.toggle("vc-hidden", !matches);
    });
    updateHeaderVisibility(panel);
  }

  // --- Search init ----------------------------------------------------------

  function initEnhancedSearch() {
    const panel = document.querySelector(PANEL_SELECTOR);
    if (!panel) return;
    if (!isAllowedUser()) return;

    if (filterEnabled() && !document.getElementById(SEARCH_WRAPPER_ID)) {
      const searchBox = buildSearchBox();
      panel.insertBefore(searchBox, panel.firstChild);
      const input = document.getElementById(FILTER_INPUT_ID);
      if (input) {
        input.addEventListener("input", (e) => filterConversations(panel, e.target.value));
        input.addEventListener("keydown", (e) => {
          if (e.key === "Escape") {
            input.value = "";
            filterConversations(panel, "");
            input.blur();
          }
        });
      }
    }

    injectRowButtons(panel);
  }

  // --- Left chevron ---------------------------------------------------------

  function buildLeftToggleButton() {
    const btn = document.createElement("button");
    btn.id = LEFT_TOGGLE_ID;
    btn.setAttribute("aria-label", t("left_toggle_label"));
    btn.setAttribute("title", t("left_toggle_title"));
    const chevron = document.createElement("span");
    chevron.className = "vc-chevron-left";
    chevron.textContent = "‹";
    btn.appendChild(chevron);
    return btn;
  }

  // Resolve and click the first native control that exists in the current
  // viewport. console.info which fired; console.warn if none.
  function clickNativeSidebarToggle() {
    for (const sel of NATIVE_TOGGLE_CHAIN) {
      const el = document.querySelector(sel);
      if (el) {
        el.click();
        console.info("[ai-left-sidebar] Toggled conversations sidebar via", sel);
        return true;
      }
    }
    console.warn(
      "[ai-left-sidebar] No native sidebar control found in",
      NATIVE_TOGGLE_CHAIN,
      "— cannot toggle the conversations sidebar (upstream may have changed)."
    );
    return false;
  }

  function initLeftSidebarToggle() {
    const onListing =
      document.body.classList.contains("ai-bot-conversations-page") &&
      (window.location.pathname === "/discourse-ai/ai-bot/conversations" ||
        window.location.pathname === "/discourse-ai/ai-bot/conversations/");

    if (!onListing) {
      document.getElementById(LEFT_TOGGLE_ID)?.remove();
      return;
    }
    if (document.getElementById(LEFT_TOGGLE_ID)) return;

    const btn = buildLeftToggleButton();
    document.body.appendChild(btn);
    btn.addEventListener("click", () => clickNativeSidebarToggle());
    log("Left chevron initialized on listing page");
  }

  // --- Lifecycle ------------------------------------------------------------

  function removeAll() {
    document.getElementById(LEFT_TOGGLE_ID)?.remove();
    document.getElementById(SEARCH_WRAPPER_ID)?.remove();
  }

  function fullInit() {
    if (!componentEnabled()) {
      removeAll();
      return;
    }
    initLeftSidebarToggle();
    initEnhancedSearch();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", fullInit);
  } else {
    fullInit();
  }

  api.onPageChange(() => setTimeout(fullInit, 100));

  // Observe the document for the panel appearing (mobile hamburger opens it
  // late) AND for rows being added to the panel asynchronously. The prior code
  // injected buttons once on first pass and missed rows that arrived later
  // (verified live: 40 rows present, 0 delete buttons). This re-runs injection
  // whenever conversation content changes.
  let reinjectScheduled = false;
  function scheduleReinject() {
    if (reinjectScheduled) return;
    reinjectScheduled = true;
    setTimeout(() => {
      reinjectScheduled = false;
      if (!componentEnabled()) return;
      const panel = document.querySelector(PANEL_SELECTOR);
      if (panel && isAllowedUser()) {
        if (!document.getElementById(SEARCH_WRAPPER_ID) && filterEnabled()) {
          initEnhancedSearch();
        } else {
          injectRowButtons(panel);
        }
      }
    }, 120);
  }

  const documentObserver = new MutationObserver((mutations) => {
    if (!document.body.classList.contains("ai-bot-conversations-page")) return;
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        const isPanel = node.matches?.(PANEL_SELECTOR) || node.querySelector?.(PANEL_SELECTOR);
        const isRow = node.matches?.(ROW_SELECTOR) || node.querySelector?.(ROW_SELECTOR);
        if (isPanel || isRow) {
          scheduleReinject();
          return;
        }
      }
    }
  });
  documentObserver.observe(document.body, { childList: true, subtree: true });
});
