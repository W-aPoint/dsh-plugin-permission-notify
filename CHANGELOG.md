# Changelog

## v0.2.1 — 2026-11-05

**Fixes for dsh 0.2.2-rc.1** (the desktop app updated on 2026-11-04):

- The permission half no longer appends during `session/created`. dsh 0.2.2 announces
  store-owned sessions and rejects appends until the announcement completes
  (`session "…" cannot append before session/created completes`). The plugin now hooks
  **`agent/created`** (append-legal, same event the built-in preset service pins on) and keeps a
  deferred `session/created` fallback for older runtimes; a rejection with the announcement guard is
  retried once on the next macrotask.
- The installer no longer deletes everything between its own marker comments. dsh's plugin manager
  can append unrelated entries (`plugin-market`, `web`, …) *inside* that span; the new
  `Remove-ManagedBlock` removes only the `- insert:` item that contains `id: permission-notify`,
  so reinstalling or uninstalling keeps other plugin configuration.
- The installer also cleans orphaned `popupSeconds` / `minIntervalMs` keys left behind by older
  versions of the managed block.

Notifications were unaffected by the update (the log kept recording `toast shown`); the click
protocol and `dshnotify:` registration are unchanged.

## v0.2.0 — 2026-10-28

- Default permission preset (`auto` / any configured preset) applied to root sessions.
- Native Windows toast notifications for turn end / approval / user questions, with the system sound.
- Toast body quotes the tail of the latest assistant answer (`includeSnippet`, `snippetChars`).
- Clicking a toast focuses the DSH window (`dshnotify:` protocol → `activate.ps1`, ALT + `SetForegroundWindow`).
- Verified foreground-lock behaviour, AppUserModelID requirement and the detached-PowerShell trap.
