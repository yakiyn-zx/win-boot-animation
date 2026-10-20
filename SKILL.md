---
name: win-boot-animation
display_name: Windows 应用启动动画安装器
display_name_en: Windows App Boot Animation Installer
description: 把一段本地视频（游戏/IDE 片头、DSH 启动动画插件提取的片头等）安装成 Windows 桌面应用的启动动画——点击应用图标后先全屏播放片头、再打开应用本体，且全程无窗口闪烁。内含完整的防闪架构（深色遮罩 + WPF 原生播放器 + 置顶守护进程）、.lnk 快捷方式等长替换手术工具、DSH 插件片头提取方法和全部踩坑记录。触发词：启动动画、片头、开场动画、boot animation、intro video、点击图标先播动画、WorkBuddy 启动动画、DSH 启动动画。
description_zh: 把本地视频安装成 Windows 桌面应用的启动动画，点击图标先全屏播片头再开应用，全程无窗口闪烁。
description_en: Install a local video as the boot animation of a Windows desktop app, full-screen intro first then the app opens, with zero window flashing.
category: productivity
version: 1.0.0
author: 你的开发者名称（上架前务必替换）
agent_created: true
---

# Windows 应用启动动画安装器

把任意本地视频做成 Windows 桌面应用（尤其 Electron 应用）的启动动画：点击图标 → 全屏片头 → 应用就位，一次完成，中间不闪任何窗口。

## 安全边界

- 全部操作用户态完成，**不需要管理员权限**，不改系统目录、不动注册表。
- 修改快捷方式前**强制先备份**，任何一步出错都可按「回退」一节原样恢复。
- 不联网、不上传任何数据：播放器、视频、日志全部在本地。

## 架构总览

```
点击图标（快捷方式目标 = 启动器 .vbs）
  ├─ 0ms    全屏深色遮罩立即盖上（点击穿透，盖住旧屏幕与播放器启动白窗）
  ├─ 0ms    启动 WPF 播放器（原生窗口，无边框全屏置顶；不用浏览器——Edge 后台进程会劫持）
  ├─ 0ms    启动守护进程（wait-kiosk.ps1）
  ├─ ~1s    播放器上屏 → 守护立即置顶 + 撤遮罩（无缝衔接）
  ├─ ~1s    应用已在运行？→ 不启动新实例（单实例应用会激活已有窗口=闪）
  │         未在运行？→ 后台启动，冷启动时间与片头重叠
  ├─ 7s     视频播放（默认带声音，点击切换静音，Esc 跳过）
  ├─ 7s     视频放完 → 播放器定格最后一帧 + 标题打 <tag>-DONE 标记
  └─ 就绪   应用窗口就绪+2s 稳定 → 关动画、激活应用（永不停在白屏）
          视频结束时一个窗口都没有（托盘化）？→ 立刻 spawn 实例，
          在仍置位的片头后面把窗口拉出来，再走上面的就绪判定
```

## 组件（scripts/）

| 文件 | 作用 |
|---|---|
| `launcher.vbs` | 启动器，快捷方式的新目标；wscript 运行无控制台窗口；防重入守卫；全部路径集中在顶部配置区 |
| `play.ps1` | WPF 播放器（`-STA` 运行）：全屏置顶、**默认带声音**（`-Muted` 可静音）、点击切换静音、Esc 跳过、播完定格打标记、30s 自关兜底 |
| `wait-kiosk.ps1` | 守护进程：等窗口上屏→置顶→按需启动应用→150ms 置顶循环→等 `<tag>-DONE` 标记→激活应用 |
| `stop-intro.ps1` | 快速通道：播放中再次点击图标→立即结束动画并聚焦应用 |
| `veil.py` | 深色遮罩（Python ctypes 原生窗口）：点击到上屏之间的无缝覆盖 |
| `wbutil.ps1` | 共享工具库：进程/窗口检测、播放器窗口按标题查找、置顶与强制前台、日志 |
| `wbhelper.cs` + `build-helper.ps1` | P/Invoke Win32 助手源码与编译脚本（预编译成 DLL，守护启动 2s→0.3s） |
| `lnktool.py` | .lnk 手术工具：`dump` 看结构 / `subst` 等长替换快捷方式目标 |

## 安装流程（按序执行）

### 1. 准备目录与视频

```bash
mkdir -p ~/.workbuddy/boot-animation/videos
cp <提取或下载的片头>.mp4 ~/.workbuddy/boot-animation/videos/intro.mp4
cp -r <skill>/scripts/* ~/.workbuddy/boot-animation/
powershell -NoProfile -ExecutionPolicy Bypass -File ~/.workbuddy/boot-animation/build-helper.ps1
```

视频来源：DSH 插件包提取方法见 `references/dsh-extraction.md`（zip 内嵌 base64 或运行中实例的 media 路由）。

### 2. 配置启动器

编辑 `boot-animation/launcher.vbs` 顶部配置区（6 个路径/参数）：

- `base` = 本脚本目录
- `python` = python.exe 绝对路径
- `app` = 目标应用 exe 绝对路径
- `appProc` = 应用进程名（不带 .exe，如 `WorkBuddy`）
- `appTitle` = 应用主窗口标题通配符（如 `WorkBuddy*`）。**必须 ASCII**：vbs 宿主按 GBK 读文件，中文模式会变乱码永远匹配不上（还会把 keeper 搞死）。真实标题是非 ASCII 时（如豆包的 `… - 豆包`）直接填 `*`——进程名过滤已经够强，任何有标题窗口就是主窗口
- `titleTag` = 播放器窗口标题标记（默认 `WB-INTRO`，多应用并存时改唯一）

### 3. 打造等长启动器文件名并复制

新启动器文件名必须与目标 exe **字符数相同**（`WorkBuddy.exe`→`WorkBuddy.vbs`）。把 launcher.vbs 复制到应用安装目录并改名：

```bash
cp launcher.vbs "D:/path/to/app/App.vbs"   # 与 App.exe 等长
```

等长改名对照与原理见 `references/lnk-format.md`。

### 4. 备份并手术快捷方式

```bash
# 备份桌面 + 开始菜单两处
cp "$DESKTOP/App.lnk" backup/desktop-App.lnk.orig
cp "$STARTMENU/App.lnk" backup/startmenu-App.lnk.orig

# 结构体检 → 生成测试副本 → dump 验证
python lnktool.py dump "$DESKTOP/App.lnk"
python lnktool.py subst "$DESKTOP/App.lnk" "$DESKTOP/AppAnim.lnk" App.exe App.vbs
python lnktool.py dump "$DESKTOP/AppAnim.lnk"
```

图标/显示名/任务栏分组自动保留（ICON_LOCATION 与 ExtraData 不动）。

### 5. 端到端测试

双击测试副本 `AppAnim.lnk`，确认：遮罩一瞬 → 片头 → 应用就位。查 `launch.log` 时间线。应用开着/关着/最小化/托盘化四种状态各测一次。

### 6. 落地

测试通过后对两处真实快捷方式做 subst（先写 .tmp 再原子替换 mv）。

### 7. 回归测试清单

- 前台窗口采样：动画期间应 100% 是播放器窗口
- 播放中点图标 → 2 秒内结束动画并聚焦
- 应用冷启动（未运行）路径：加载与片头重叠，无片头后等待

## 关键规则（违反必闪）

1. **不用浏览器做播放器**——Edge 后台驻留进程会劫持 kiosk 启动（视频塞进用户自己的 profile，片头不播还闪窗）。用 play.ps1 原生 WPF 窗口。
2. **进程级检测应用是否在运行**，不是窗口级——托盘化/最小化时窗口检测会漏，误启第二实例触发单实例激活闪烁。Electron 排除 `--type=` 辅助进程。
3. **上屏即置顶**，不等标题就绪、不等应用启动；150ms 循环维持。
4. **视频结束用标题标记**（`<tag>-DONE`），不轮询进程（Edge 辅助进程 lingering 会把动画误判成 15-20s）。
5. **点击到上屏之间必须有遮罩**；keeper 开头不要清扫遮罩（会把刚拉起的误杀）。
6. **收尾 = 视频结束 且 应用窗口就绪+2s 稳定**；视频结束时**一个窗口都没有**（托盘化）要立刻 spawn 实例（在仍置位的片头后面拉起窗口），不能干等 HoldCapS——否则用户盯着定格画面白等 10 秒。
7. .lnk 手术只用**等长替换**，IDList 不可去、不可重建（重建的 IDListSize 差一错误必死）。
8. **vbs 配置区禁止非 ASCII**——宿主按 GBK 读 vbs，中文标题模式变乱码：匹配不上还是小事，`-like` 遇到乱码里的 `[` 会直接杀死 keeper 进程（日志停在"marker seen"，无任何报错）。非 ASCII 标题用 `*`。

完整根因分析与更多坑见 `references/pitfalls.md`（14 条，全部实战验证）。

## 回退

```bash
cp backup/desktop-App.lnk.orig "$DESKTOP/App.lnk"
cp backup/startmenu-App.lnk.orig "$STARTMENU/App.lnk"
```

并删除安装目录下的启动器与 boot-animation 目录。

## 参数速查（wait-kiosk.ps1 / play.ps1）

| 参数 | 默认 | 说明 |
|---|---|---|
| `-App` | (必填) | 应用 exe 绝对路径 |
| `-AppProcess` | `WorkBuddy` | 应用进程名（无 .exe） |
| `-AppTitleLike` | `WorkBuddy*` | 主窗口标题通配符 |
| `-TitleTag` | `WB-INTRO` | 播放器标题标记（结尾自动派生 `-DONE`） |
| `-SettleMs` | `2000` | 视频结束后等应用窗口稳定的时长 |
| `-HoldCapS` | `10` | 视频结束后等应用窗口就绪的上限 |
| `-TotalCapS` | `90` | 全流程总上限 |
| `-WindowWaitS` | `12` | 等播放器窗口上屏的上限 |
| `-SelfCloseS` | `30` | 播放器自关兜底（视频时长+15 左右） |
| `-Muted` | 关 | 播放器静音开关：默认**带声音**播放；加 `-Muted` 恢复静音起播 |

## 环境注意（Windows + 本 agent）

- 播放器必须 `powershell -STA` 启动（WPF 需要 STA 线程）。
- 系统执行策略：所有 .ps1 用 `powershell -NoProfile -ExecutionPolicy Bypass -File` 运行。
- 启动 .lnk 测试用 `cmd //c start "" "C:/path/x.lnk"`；Bash 工具会转换反斜杠，含反斜杠的命令走 PowerShell 工具。
- 测试时不要杀应用主进程（可能是当前会话宿主）。
- 更多工具层坑见 `references/pitfalls.md` 第 11 条。
