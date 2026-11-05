# How it works — and the Windows traps behind it

Everything here was derived from the shipped dsh desktop app (`app.asar`) plus empirical tests on
Windows 11 (`10.0.26100`). Versions at the time of writing: `@deepseek-ai/*` `0.2.1-rc.3`.

## 1. dsh plugin shape

dsh is composed with [cordis](https://github.com/deepseek-ai/cordis): a profile lists bundle layers,
each layer adds patch entries to a plugin tree, and a plugin is just an ESM module exporting:

```js
export const name = 'permission-notify'
export const Config = Schema.object({ /* @deepseek-ai/schemastery */ })
export function apply(ctx, config) { /* … */ }
```

`ctx` gives you services (`ctx.get('sessions')`, `ctx.inject([...], cb)`), events
(`ctx.on('session/event', (session, event) => …)`) and effects (`ctx.effect(fn, 'label')`).
A plugin is loaded by name from the profile's `node_modules` (a junction into `~/.dsh/plugins/…` is
enough), which is why this repository ships a plain `package/` directory instead of a build pipeline.

### Patch syntax

Adding a plugin to `cordis.patch.yml` requires **`- insert:`**; a bare `- id: …` entry means
"override an existing entry" and fails with `patch: entry "…" not found`:

```yaml
- insert:
    - id: permission-notify
      name: dsh-plugin-permission-notify
      config:
        defaultPreset: auto
```

## 2. The permission half

`@deepseek-ai/dsh-permission-presets` owns a process catalog (`{name → {sandbox, approval}}`) plus a
**session-only** `auto` preset, registered by `@deepseek-ai/dsh-experimental-auto-review` through
`permissionPresets.registerAuto(admit)`. The package README states the constraint directly:
*“Auto 不能成为默认值”* — it is intentionally absent from the `permission` settings namespace.

The service exposes enough to work around it:

| API | use |
| --- | --- |
| `permissionPresets.names` | currently selectable presets (configured ones + `auto` while live) |
| `permissionPresets.current(session)` | effective preset of a session |
| `permissionPresets.set(session, name)` | append `permission/preset` and write the two knobs |

So the plugin listens on **`agent/created`**, filters to root sessions
(`session.header.origin !== 'subagent'`, no `parentSession`), and calls `set(session, 'auto')`.
On mount it does the same for existing sessions when `applyToExistingSessions` is on.
Because the presets service pins the initial permission in its own `session/created` listener and
this plugin is appended after the built-in layers, the switch lands *after* pinning.

### dsh 0.2.2: appends are blocked during `session/created`

dsh 0.2.2 announced store-owned sessions with a new guard:

```
session "…" cannot append before session/created completes
```

The `SessionStore.announce()` method dispatches `session/created` synchronously and only flips
`entry.announcement = "complete"` afterwards, so **any** `session.append` from a creation listener
throws — including `permissionPresets.set()`. That is why the built-in preset service migrated its
pinning from `session/created` to `agent/created` (emitted through `ctx.serial` after the session is
live). This plugin follows the same event:

```js
child.on('agent/created', ({ agent }) => applyDefault(agent?.session, 'created'))
```

and keeps belt-and-braces handling for older/newer shapes:

* a `session/created` listener that defers one macrotask before touching the session;
* a retry (50 ms) whenever a `set()` rejects with the announcement guard, so a future runtime that
  re-introduces the ordering cannot silently drop the preset.

Both paths are covered by `tools/verify.ps1` (fake agent-created path, deferred path, guard-retry path).


## 3. Why the Windows toast did not show at first

A toast from an **unpackaged** Win32 program requires its AppUserModelID (AUMID) to be registered as
a Start Menu shortcut carrying `System.AppUserModel.ID`. Without it:

* `CreateToastNotifier("anything")` succeeds,
* `notifier.Setting` may return an empty string (looks fine),
* `Show()` returns without error,
* and **Windows silently drops the toast** — the classic “sound, but no popup” symptom.

The real identity is in the app's own shortcut:

```
C:\Users\<you>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\DeepSeek Harness.lnk
  System.AppUserModel.ID = com.deepseek.dsh
```

Reading it needs `IShellLinkW` + `IPropertyStore` (`PKEY_AppUserModel_ID` = `{9F4C2855-…}, 5`); a
probe that guesses names (`DeepSeek Harness`, `com.deepseek.harness`) reports `Setting = ''` and the
toast never appears. With `com.deepseek.dsh` the toast is delivered as “DeepSeek Harness” and lands
in the notification center.

Custom sound: put `ms-winsoundevent:Notification.Default` in the toast XML; a `<audio silent="true"/>`
toast plus a separate sound process is both slower and less reliable.

## 4. The detached-PowerShell trap

The plugin spawns PowerShell to raise the toast. With

```js
spawn('powershell.exe', args, { detached: true, stdio: 'ignore' })
```

the child exits with code **0** and does nothing at all — no toast, no log line. Repro matrialled:
`detached: true` fails, plain `spawn(..., { stdio: 'ignore' })` works. So the helper is spawned as a
normal child; `unref()` is not used.

## 5. Click → back to dsh

Two independent problems:

**a) A click needs an activation path.** For unpackaged Win32 apps the documented way is a COM
activator (`ToastActivatorCLSID` + `LocalServer32`). That means shipping and registering a COM
server. A much cheaper path is *protocol activation*:

```xml
<toast activationType="protocol" launch="dshnotify:activate"> … </toast>
```

with `HKCU\Software\Classes\dshnotify\shell\open\command` pointing at a launcher:

```
wscript.exe //nologo "<install>\assets\activate.vbs" "%1"
```

`wscript` (not `powershell.exe`) is used because a `powershell.exe` protocol handler flashes a black
console window on every click. `activate.vbs` starts `activate.ps1` with a hidden window.

**b) A background process cannot steal the foreground.** `SetForegroundWindow` is ignored under the
foreground lock; `SwitchToThisWindow` and `WScript.Shell.AppActivate` did nothing in tests. What did
work was sending one synthetic `ALT` keystroke first (which releases the lock), then
`SetForegroundWindow`, then verifying with `GetForegroundWindow`. `activate.ps1` falls back to
`AttachThreadInput` + `SetForegroundWindow` and logs every attempt.

Relaunching `DeepSeek Harness.exe` is *not* a workaround: the app has a single-instance lock and its
`second-instance` handler focuses the window — but Windows still refused to raise it from a
background launch in tests.

## 6. Snippet source

`assistant/message` session events carry `event.data.message.content[]`; text blocks are concatenated,
code fences collapsed to `[代码]`, whitespace flattened and clipped to `snippetChars`. The plugin keeps
one snippet per session and attaches it as the toast's third line
(`ToastGeneric` supports at most three text lines: title / status / snippet).

## 7. Live-reload behaviour

The desktop profile performs HMR recomposition when `cordis.patch.yml` changes, so a fresh install is
usually mounted within ~15 s (log line `mounted: …`). HMR does **not** reload a plugin when only its
JS files change, so after editing `package/index.js` either touch the patch or restart the app.
