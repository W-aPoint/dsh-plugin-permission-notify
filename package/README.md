# dsh-plugin-permission-notify

DeepSeek Harness 宿主侧插件（纯 ESM，无需构建、无编译步骤）：

1. **默认权限 = 自动审查**：把 `auto`（Auto review）或任意权限预设设为会话默认值。
   dsh 刻意不把 Auto 放进「未来会话默认值」，本插件在 `session/created` 与插件挂载时
   对**根会话**调用 `permissionPresets.set(session, preset)`；子会话/委派会话不动。
2. **Windows 原生通知**：回答结束（`turn/end` 且 `completed`/`max-tokens`）、
   需要确认操作（`approval/asked`）、需要你选择（`ask_user_question`）时，
   用 Windows Toast 通知提醒，带系统提示音，正文里引用**最近一条回答的片段**；
   点击通知会把 DSH 窗口切到前台。

## 通知内容

Toast 最多三行文本：`DeepSeek Harness · <项目目录>` / 状态（如「回答完成 — pwsh」）/
最近一条 assistant 回答的前 `snippetChars` 个字符（代码块折叠成 `[代码]`，换行压平成空格）。
片段来源是 `assistant/message` 会话事件；某轮还没有任何正文时（例如刚发工具调用就问问题）
第三行会省略。

## 点击跳转

未打包的 Win32 程序想在点 Toast 时回前台，正规做法是注册 COM 激活器（ToastActivatorCLSID）；
这里改用更轻的 **协议激活**：Toast XML 用
`activationType="protocol" launch="dshnotify:activate"`，安装脚本把 `dshnotify:` 注册到
`HKCU\Software\Classes\dshnotify\shell\open\command`，指向 `assets\activate.vbs`（无窗口启动
`activate.ps1`）。`activate.ps1` 先发一次 ALT 解除 Windows 前台锁，再 `SetForegroundWindow`，
失败则退到 `AttachThreadInput` 重试，全部结果写日志。

## 通知身份（为什么能弹出来）

Windows 的 Toast 对**未打包**的桌面程序要求「开始菜单快捷方式上带 AppUserModelID」。
DSH 桌面端的开始菜单快捷方式带的是 `com.deepseek.dsh`（`System.AppUserModel.ID`），
所以插件直接把 `appId` 设为它，通知就会以「DeepSeek Harness」的身份显示，并进入通知中心。
用别的字符串（例如猜出来的 `DeepSeek Harness`）会「`Show()` 不报错但什么都不显示」。

## 配置

```yaml
- insert:
    - id: permission-notify
      name: dsh-plugin-permission-notify
      config:
        defaultPreset: auto            # auto | workspace-write | danger-full-access | off
        applyToExistingSessions: true  # 挂载时是否也改现存根会话
        notifyTurnEnd: true            # 回答完成
        notifyApproval: true           # 需要确认操作（含自动审查拦下的调用）
        notifyQuestion: true           # ask_user_question 需要选择
        sound: true                    # 系统提示音
        includeSnippet: true           # 正文附带最近一条回答的片段
        snippetChars: 120              # 片段最大字符数
        clickToFocus: true             # 点击通知把 DSH 切到前台
        appId: com.deepseek.dsh        # Windows AppUserModelID
        minIntervalMs: 1200            # 同类提示去重间隔
        logFile: ''                    # 留空 -> ~/.dsh/logs/permission-notify.log
```

## 依赖的服务

| 服务 | 用途 | 缺失时 |
| --- | --- | --- |
| `permissionPresets` / `sessions` | 写默认权限预设 | 只做通知，日志记一条警告 |
| `@deepseek-ai/dsh-experimental-auto-review` | 提供 `auto` 预设 | `defaultPreset: auto` 不生效，改用其他预设名 |

## 通知实现

`assets/notify.ps1`：接 base64(JSON)，用 `Windows.UI.Notifications.ToastNotificationManager`
以 `appId` 发 Toast；`sound: true` 时在 XML 里挂 `ms-winsoundevent:Notification.Default`，
关掉时用 `silent="true"`。Toast 失败（通知被系统关闭/身份不可用）时只写日志并退回
`SystemSounds::Exclamation` 响一声；任何异常都不影响宿主进程。
