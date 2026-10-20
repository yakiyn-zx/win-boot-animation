# win-boot-animation

给 Windows 桌面应用装上「点击图标 → 全屏播放启动动画 → 应用窗口就位」的开机效果。原生 WPF 播放器，防闪架构，默认带声音。

## 这是什么

一个 WorkBuddy Skill，把任意本地 mp4 变成某款 Windows 桌面应用（Electron / 普通 Win32 均可）的启动动画：

- 点击应用快捷方式 → 先全屏播放片头（**默认带声音**，Esc 跳过，播放中再点一次立即结束）
- 片头播放期间应用在后台加载，动画结束瞬间工作台就位（无白屏、无闪现）
- 无浏览器、无单例、不劫持；用户态运行，不需要管理员权限，不联网

## 适合谁

- 给豆包、WorkBuddy 这类桌面应用加上品牌化启动动画
- 任何你想「点开先来一段动画」的 Windows 程序

## 组成

| 文件 | 作用 |
|---|---|
| `scripts/launcher.vbs` | 启动器（快捷方式的新目标），负责遮罩 + 拉起播放器，再交给守护进程 |
| `scripts/play.ps1` | WPF 全屏置顶播放器：默认带声音、左键切换静音、Esc 跳过、播完定格打标记 |
| `scripts/wait-kiosk.ps1` | 守护进程：等播放器上屏 → 启动应用 → 全程钉住动画 → 视频结束且窗口就绪后收尾 |
| `scripts/veil.py` | 点击瞬间深色遮罩，消除「开头闪一下」 |
| `scripts/lnktool.py` | 快捷方式「等长替换」手术工具（不改 IDList，避免 lnk 损坏） |
| `scripts/wbutil.ps1` / `wbhelper.cs`+`wbhelper.dll` | 窗口查找 / 置顶 / 抢焦点的 P/Invoke 封装 |
| `references/` | .lnk 手术方法论、踩坑记录（pitfalls）、片头提取说明 |

## 使用前必改（`scripts/launcher.vbs` 顶部）

```vbs
base   = "<PATH_TO_SKILL_FOLDER>\boot-animation"   ' 含 play.ps1 的目录
python = "<PATH_TO_PYTHON_EXE>"                   ' 任意 Python 3.x
app    = "<PATH_TO_YOUR_APP_EXE>"                 ' 你的应用主程序
```

## 安装流程（简述）

1. 把本仓库放到本机某处，记下 `base` 目录
2. 编辑 `launcher.vbs` 的 `base / python / app`（以及 `appProc / appTitle / titleTag`）
3. 准备一段 mp4 片头，放到 `base\videos\intro.mp4`
4. 用 `scripts/lnktool.py subst` 把应用桌面 / 开始菜单快捷方式的目标换成 `launcher.vbs`（等长替换，保留图标）
5. 点图标验证

详细踩坑与回退方法见 [`references/pitfalls.md`](references/pitfalls.md)。

## 要求

- Windows 10 / 11
- Python 3.x（仅用于遮罩与 lnk 手术；播放器本体是 PowerShell + .NET/WPF）
- PowerShell 5.1+（含 `-STA`），.NET Framework / .NET 桌面运行时

## License

MIT — 见 [LICENSE](LICENSE)。

---

## English

A WorkBuddy Skill that adds a fullscreen boot animation (any local mp4) to a Windows
desktop app: click the shortcut → intro plays (sound on by default, Esc to skip) → the
real app loads behind it and takes over the moment the video ends. Native WPF player,
flicker-free, no admin, no network.

Edit the three paths at the top of `scripts/launcher.vbs`, drop your intro at
`videos/intro.mp4`, and retarget the app's shortcut to `launcher.vbs` with
`scripts/lnktool.py subst`. See `references/pitfalls.md` for the gory details and rollback.
