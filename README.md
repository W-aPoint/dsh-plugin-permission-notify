# dsh-plugin-permission-notify

A **DeepSeek Harness (dsh) plugin** that does two things:

1. **Makes “Auto review” the default permission preset.** dsh deliberately keeps the experimental
   `auto` preset out of the “future sessions” default; this plugin re-applies it to every root
   session (on creation and on mount).
2. **Raises native Windows notifications** — a real Windows toast (with the system sound) whenever a
   turn finishes or the agent is blocked on a decision. The toast quotes the **tail of the latest
   assistant answer**, and **clicking it brings the DSH window back to the foreground**.

Plain ESM, no build step, no npm dependencies (it only uses `@deepseek-ai/schemastery`, which ships
with dsh).

```
回答完成 · data_base
「…可以确定了——总盘子已经定型，后面只是把几十到几百人挪一下…」      ← real snippet, not a template
点击通知 → DSH 窗口回到前台
```

## Install (Windows)

```powershell
git clone https://github.com/W-aPoint/dsh-plugin-permission-notify.git
cd dsh-plugin-permission-notify
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The installer is idempotent and does three things:

1. copies `package/` to `%USERPROFILE%\.dsh\plugins\dsh-plugin-permission-notify`;
2. junctions it into `~/.dsh/profiles/desktop/node_modules`;
3. appends a marked `- insert:` block to the profile's `cordis.patch.yml`
   (backup written next to it), and registers the `dshnotify:` protocol used by toast clicks.

Restart DeepSeek Harness (or wait for the desktop HMR to pick the patch up). Check
`~/.dsh/logs/permission-notify.log` to confirm `mounted:`.

## Configuration

Edit the managed block in `~/.dsh/profiles/desktop/cordis.patch.yml`, or re-run `install.ps1`
with flags (`-DefaultPreset off`, `-SkipExistingSessions`, `-NoSound`, `-Uninstall`).

| key | default | meaning |
| --- | --- | --- |
| `defaultPreset` | `auto` | preset applied to root sessions: `auto`, `workspace-write`, `danger-full-access`, any configured preset name, or `off` |
| `applyToExistingSessions` | `true` | also switch sessions that already exist when the plugin mounts |
| `notifyTurnEnd` | `true` | notify when a turn finishes (`turn/end` with `completed`/`max-tokens`) |
| `notifyApproval` | `true` | notify on `approval/asked` (includes calls denied by Auto review) |
| `notifyQuestion` | `true` | notify on `ask_user_question` |
| `sound` | `true` | play the system notification sound |
| `includeSnippet` | `true` | quote the tail of the latest assistant answer in the toast |
| `snippetChars` | `120` | snippet length budget |
| `clickToFocus` | `true` | clicking the toast focuses the DSH window |
| `appId` | `com.deepseek.dsh` | Windows AppUserModelID used for the toast |
| `minIntervalMs` | `1200` | de-duplication window per notification kind |
| `logFile` | `~/.dsh/logs/permission-notify.log` | delivery log |

## How it works (short version)

* **Permission half** — on `session/created` (and on mount) the plugin calls
  `ctx.permissionPresets.set(session, 'auto')` for root sessions only. Sub-agent sessions are left
  alone. If the `@deepseek-ai/dsh-experimental-auto-review` bundle is not installed, `auto` is not an
  available preset and the plugin logs a warning instead of failing.
* **Notification half** — listens to `session/event` for `turn/end`, `approval/asked` and
  `tool/call(ask_user_question)`, keeps the newest `assistant/message` text per session as the
  snippet, then spawns `assets/notify.ps1` which raises a Windows toast.
* **Click half** — the toast uses protocol activation (`dshnotify:activate`). The protocol is
  registered in `HKCU\Software\Classes` at install time and launches `activate.vbs` →
  `activate.ps1`, which releases the Windows foreground lock with a synthetic `ALT` and then calls
  `SetForegroundWindow`, verifying the result.

Why the toast identity is `com.deepseek.dsh`, why a detached PowerShell child silently does
nothing, and how the foreground lock was solved: see **[docs/how-it-works.md](docs/how-it-works.md)**.

## Requirements

* Windows 10/11 with the **DeepSeek Harness desktop app** installed (that is where the
  `com.deepseek.dsh` AppUserModelID comes from).
* The `@deepseek-ai/dsh-experimental-auto-review` bundle enabled in the profile, if you want the
  `auto` preset (`install.ps1` warns when it is missing).
* PowerShell 5.1 (shipped with Windows). No admin rights: everything lives in `HKCU` and `~/.dsh`.

## Verifying

```powershell
# raises a real clickable toast
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-notify.ps1

# offline logic tests against a fake cordis context (no dsh restart needed)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify.ps1

# delivery log
Get-Content "$env:USERPROFILE\.dsh\logs\permission-notify.log" -Tail 20
```

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Removes the managed patch block, the `node_modules` junction and the `dshnotify:` protocol.
The copied plugin files stay in `~/.dsh/plugins/` (delete them manually if you want).

## 中文说明

这个插件给 **DeepSeek Harness（桌面端）** 补两件事：

1. **把「自动审查」变成默认权限**。dsh 本身不允许把实验性的 `auto` 预设设成「未来会话默认值」，
   插件在会话创建和自身挂载时，对**根会话**重新应用你指定的预设（默认 `auto`）；子代理会话不动。
2. **原生 Windows 通知**。回答结束、需要确认操作、`ask_user_question` 等你做选择时弹系统 Toast，
   带系统提示音；正文会引用**最近一条回答的片段**（不是固定模板），**点击通知会把 DSH 窗口拉回前台**。

核心结论（详见 [docs/how-it-works.md](docs/how-it-works.md)）：

* Windows 对未打包的桌面程序发 Toast，要求 AppUserModelID 对应开始菜单里带
  `System.AppUserModel.ID` 的快捷方式；猜一个字符串会「`Show()` 不报错但什么都不显示」。
  DSH 桌面端的快捷方式里注册的是 `com.deepseek.dsh`，直接用就行。
* 用 `powershell.exe` 发 Toast 时不能 `spawn(..., { detached: true })`：进程会以退出码 0 结束
  却不干活。改成普通子进程 + `stdio: 'ignore'`。
* 点击 Toast 回前台：未打包程序的正规做法是注册 COM 激活器；这里改用 `dshnotify:` 协议 +
  一次合成 `ALT` 解除前台锁再 `SetForegroundWindow`，并用 `wscript` 隐藏窗口启动，避免黑窗闪一下。

配置项、安装/卸载、验证、排错都在上面英文段落和 [docs/](docs/) 里；日志在
`~\.dsh\logs\permission-notify.log`。

## License

[MIT](LICENSE) © 2026 WyyyD
