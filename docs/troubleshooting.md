# Troubleshooting

All diagnostics go to one file:

```powershell
Get-Content "$env:USERPROFILE\.dsh\logs\permission-notify.log" -Tail 40
```

| log line | meaning |
| --- | --- |
| `mounted: defaultPreset=… appId=… sound=…` | plugin is live in the host process |
| `permission preset -> auto (created)` | default preset applied to a session |
| `defaultPreset "auto" is not available` | the auto-review bundle is not enabled in this profile |
| `notify kind=… body="…" snippet="…"` | an event produced a notification |
| `[helper] toast shown via appId …` | Windows accepted the toast |
| `[helper] toast failed: …` | toast rejected (identity / settings) |
| `[activate] ok via …` | a toast click focused the DSH window |
| `[activate] no window matching …` | dsh window not found (renamed? minimized to tray?) |

## Toast does not appear (but sound plays)

1. Check the identity — the shortcut must exist and carry the AUMID:

```powershell
$sh = New-Object -ComObject Shell.Application
$f = $sh.Namespace("$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
$i = $f.ParseName('DeepSeek Harness.lnk')
$f.GetDetailsOf($i, 0)          # shows the shortcut; AUMID needs IPropertyStore
```

If your DSH build uses a different AppUserModelID, override it in the patch:

```yaml
      config:
        appId: com.deepseek.dsh   # <- yours
```

2. Windows settings → **System → Notifications**: the “DeepSeek Harness” app entry must be enabled,
   “Do not disturb / 专注助手” off.
3. `[helper] toast failed: appId '…' 的通知被系统关闭或不受支持` means the identity is not registered
   for notifications on this machine.

## Click does nothing

```powershell
Get-ItemProperty 'HKCU:\Software\Classes\dshnotify\shell\open\command'
```

Expected value: `"C:\WINDOWS\System32\wscript.exe" //nologo "<install>\assets\activate.vbs" "%1"`.
Missing → re-run `install.ps1` (it is idempotent).

Also verify `assets\activate.ps1` logs an attempt: `[activate] target pid=… hwnd=…`.
If it logs `ALT+SetForegroundWindow landed on '…'` and the window still does not come forward,
something (often enterprise security software) is blocking synthetic keystrokes; the script then
tries `AttachThreadInput`, which is logged as well.

## Black console window flashes on click

The protocol handler is calling `powershell.exe` directly. Re-run `install.ps1`; it registers
`wscript.exe //nologo …\activate.vbs` instead, which starts PowerShell hidden.

## Nothing happens at turn end

* `notifyTurnEnd` must be `true`, and the turn must end with `completed` or `max-tokens`
  (aborted / error turns are intentionally silent).
* Sub-agent sessions never notify; only the root session does.
* `minIntervalMs` (default 1200 ms) drops a second notification of the same kind.

## Auto review is not applied

`defaultPreset: auto` only works while `@deepseek-ai/dsh-experimental-auto-review` is enabled for the
profile (Web sidebar → Plugins, or add the bundle to `dsh.profile.bundles`). Otherwise the log gets
`defaultPreset "auto" is not available (have: workspace-write, danger-full-access)` and nothing is
changed. Pick a concrete preset instead if you do not want Auto review.

Also note that Auto review spends extra tokens: every tool call is reviewed by the model before it
runs.

## Plugin does not load after editing files

HMR recomposes on `cordis.patch.yml` changes but does not re-import changed plugin modules. Touch the
patch (or restart the app) after editing `package/index.js`, then look for a fresh `mounted:` line.

## Uninstall / start over

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

This removes the managed patch block, the `node_modules` junction and the `dshnotify:` protocol.
