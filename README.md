# VoiceIMEHelper

Hammerspoon Spoon 插件：在语音输入法使用完成后，自动切换回原先的输入法。

本插件的最原始想法，参考自：https://github.com/Paxxs/Doubao-ime-hammerspoon

## 功能

通常我们在日常键盘输入的时候，都有自己习惯使用的输入法。但如豆包等最新的语音输入法又实在非常好用。所以就希望平时还是用常用的输入法来输入，然后用豆包输入法的全局快捷键（比如“右 Option”）来触发语音输入，在语音输入结束后再由插件把输入法自动切换回原先的输入法，保证总体比较好的使用体验。

这个插件的功能是：当检测到输入法切换时，通过麦克风使用状态判断是否启动了语音输入法（如豆包输入法）。在语音输入完成（麦克风从"正在使用"变为"未使用"）时，自动切换回原先的输入法，避免干扰原先的输入法使用习惯。

## 工作原理

1. **监听输入法切换**：通过 `hs.keycodes.inputSourceChanged` 监听系统输入法变化
2. **检测语音输入法启动**：当输入法切换后，延迟一段时间检查麦克风状态。如果麦克风从"未使用"变为"正在使用"，判定为语音输入法启动
3. **自动切回原输入法**：持续监听麦克风状态，当麦克风从"正在使用"变为"未使用"时，自动切换回之前记录的输入法

## 安装

需要预先在 http://www.hammerspoon.org/ 下载和安装 Hammerspoon，然后按后续的步骤安装和配置 `VoiceIMEHelper.spoon` 插件。

### 方法一：直接复制

将 `VoiceIMEHelper.spoon` 目录复制到 Hammerspoon 的 Spoons 目录：

```bash
cp -r VoiceIMEHelper.spoon ~/.hammerspoon/Spoons/
```

### 方法二：符号链接（推荐用于开发）

```bash
ln -s /path/to/Voice-IME-Helper/VoiceIMEHelper.spoon ~/.hammerspoon/Spoons/VoiceIMEHelper.spoon
```

## 使用方法

在 `~/.hammerspoon/init.lua` 中添加：

```lua
hs.loadSpoon("VoiceIMEHelper")
spoon.VoiceIMEHelper.voiceIMEPatterns = {"语音", "Voice", "Dictation", "Doubao", "豆包"}
spoon.VoiceIMEHelper:start()
```

注意：在当前版本中， `voiceIMEPatterns` 这一行虽然不是必须的，但通常增加这个设置之后，可以避免一些少见的、无法正确切换回原先输入法的情况！

因为目前在记录切换到语音输入法前的原始输入法时，为了判断其自身是不是语音输入法，也会检查麦克风状态，但这个检查过程会涉及一个数秒长的持续时间窗口。而 Mac 系统常常在应用程序之间做切换时，也会触发输入法变更的事件，于是在通过全局快捷键启动语音输入时，插件就有可能还来不及完成对前一个输入法的判断，也就不会用它来更新对前置输入法的记录。于是在插件把输入法切换回来的时候，很有可能就不是我们想要的那一个了。

## 配置

在调用 `:start()` 之前，可以调整以下参数：

```lua
-- 输入法切换后，延迟多久开始检查麦克风状态（秒）
-- 默认 0.5 秒，给语音输入法启动的时间
spoon.VoiceIMEHelper.checkDelay = 0.5

-- 麦克风状态轮询间隔（秒）
-- 默认 0.3 秒
spoon.VoiceIMEHelper.checkInterval = 0.3

-- 等待麦克风变为"正在使用"的超时时间（秒）
-- 默认 3.0 秒，超时后取消检测
spoon.VoiceIMEHelper.checkTimeout = 3.0

```lua
-- 麦克风停止使用后，延迟多久切换回原输入法（秒）
-- 默认 1.0 秒，防止语音输入法短暂停顿导致过早切换
spoon.VoiceIMEHelper.restoreDelay = 1.0

-- 可选：通过输入法名称过滤，只在切换到特定输入法时激活
-- 默认 nil，监听所有输入法切换
-- 例如：只在名称包含"语音"、"Voice"、"Dictation"或"Doubao"时激活
spoon.VoiceIMEHelper.voiceIMEPatterns = {"语音", "Voice", "Dictation", "Doubao", "豆包"}

-- 日志级别："debug"（详细）、"info"（正常）、"warning"（警告）
spoon.VoiceIMEHelper.logLevel = "info"
```

## API

| 方法 | 说明 |
|------|------|
| `:init()` | 初始化（由 `hs.loadSpoon` 自动调用） |
| `:start()` | 开始监听输入法切换和麦克风状态 |
| `:stop()` | 停止所有监听 |
| `:getState()` | 获取当前状态（`"IDLE"` / `"CHECKING"` / `"MONITORING"`） |
| `:getPreviousSourceID()` | 获取记录的待恢复输入法 ID |
| `:triggerManualRestore()` | 手动触发恢复到之前保存的输入法 |
| `:setLogLevel(level)` | 设置日志级别（`"debug"` / `"info"` / `"warning"` / `"error"`） |
| `:bindHotkeys(mapping)` | 绑定快捷键（支持 `restore` 操作） |

## 状态机

```
IDLE ──(输入法切换)──► CHECKING ──(麦克风开始使用)──► MONITORING
  ▲                       │                              │
  │                     (超时)                         (麦克风停止使用)
  │                       │                              │
  └───────────────────────┘                              │
  ▲                                                      │
  └──────────────────────────────────────────────────────┘
```

## 高级用法

### 通过快捷键手动触发恢复

如果你希望在语音输入法没有自动触发切换时，能手动恢复到之前的输入法：

```lua
hs.loadSpoon("VoiceIMEHelper")
spoon.VoiceIMEHelper:start()

-- 绑定快捷键 Cmd+Shift+R 手动恢复
spoon.VoiceIMEHelper:bindHotkeys({
    restore = {{"cmd", "shift"}, "r"}
})
```

### 调试模式

如果遇到问题，可以开启详细日志：

```lua
spoon.VoiceIMEHelper:setLogLevel("debug")
spoon.VoiceIMEHelper:start()
```

然后在 Hammerspoon 控制台查看日志。

## 注意事项

- `hs.keycodes.inputSourceChanged` 同一时间只能注册一个回调。如果你的 Hammerspoon 配置中有其他代码使用该回调，可能会产生冲突。
- 麦克风的"正在使用"状态是通过 `hs.audiodevice:inUse()` 检测的，它反映的是系统级别的音频设备占用状态。
- 如果语音输入法没有触发输入法切换事件（例如使用全局快捷键直接在当前输入法内启动语音输入），本插件无法自动检测。此时可以使用 `:triggerManualRestore()` 手动恢复。
- 某些语音输入法可能不切换输入法，而是在当前输入法内直接启动语音输入。这种情况下，Spoon 可能无法正常工作。

## License

MIT License
