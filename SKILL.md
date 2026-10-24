---
name: win-boot-animation
display_name: Windows 应用启动动画安装器
display_name_en: Windows App Boot Animation Installer
description: 把一段本地视频（游戏/IDE 片头、DSH 启动动画插件提取的片头等）安装成 Windows 桌面应用的启动动画——点击应用图标后先全屏播放片头、再无缝进入应用界面，且全程无窗口闪烁、无白屏。内含完整的防闪架构（深色遮罩 + WPF 原生播放器 + 置顶守护进程 + 内容就绪预加载）、全屏工作区与客户区像素级对齐、.lnk 快捷方式等长替换手术工具、DSH 插件片头提取方法和全部踩坑记录。触发词：启动动画、片头、开场动画、boot animation、intro video、点击图标先播动画、启动无白屏、动画播完卡住、动画和工作台一样大、WorkBuddy 启动动画、DSH 启动动画。
description_zh: 把本地视频安装成 Windows 桌面应用的启动动画，点击图标先全屏播片头再无缝进入应用，全程无闪烁无白屏。
description_en: Install a local video as the boot animation of a Windows desktop app — fullscreen intro first, then seamless handover to the already-loaded app, with zero flashing or white screens.
category: productivity
version: 1.2.0
author: 你的开发者名称（上架前务必替换）
agent_created: true
---

# Windows 应用启动动画安装器

把任意本地视频做成 Windows 桌面应用（尤其 Electron 应用）的启动动画：点击图标 → 全屏片头 → 已加载完成的应用就位，中间不闪窗口、不白屏、不露边。

## 安全边界

- 全部操作用户态完成，**不需要管理员权限**，不改系统目录、不动注册表。
- 修改快捷方式前**强制先备份**，任何一步出错都可按「回退」一节原样恢复。
- 不联网、不上传任何数据：播放器、视频、日志全部在本地。

## 架构总览

```
点击图标（快捷方式目标 = 启动器 .vbs）
  ├─ 0ms    遮罩先自己把应用窗口藏到屏幕外，再盖上同尺寸深色遮罩
  ├─ 0ms    启动 WPF 播放器（原生窗口，无边框全屏置顶、铺满主屏工作区；不用浏览器——Edge 后台进程会劫持）
  ├─ 0ms    启动守护进程（wait-kiosk.ps1）
  ├─ ~1s    播放器上屏 → 守护立即置顶 + 撤遮罩（无缝衔接）
  ├─ ~1s    应用已在运行？→ 不启动新实例（单实例应用会激活已有窗口=闪）
  │         未在运行？→ 后台启动，冷启动时间与片头重叠
  │        （无论冷热）应用所有大窗口一律藏到屏幕外，动画期间屏幕上只有动画
  ├─ 视频播放（默认带声音，点击切换静音，Esc 跳过）
  ├─ 视频放完 → 播放器定格最后一帧 + 标题打 <tag>-DONE 标记
  ├─ 就绪   内容探针确认页面真的画出来了（冷启动时边藏边等，最长 HoldCapS）
  └─ 交接   应用窗口先摆到动画那个矩形（含边框补偿）→ 立刻关闭动画 →
            激活应用：用户看到的是"动画最后一帧 → 已加载完的界面"，无白屏、无露边
```

### 两条启动路径

| 路径 | 条件 | 行为 |
|---|---|---|
| 冷启动 | 应用进程不存在 | 启动实例 → 窗口出现即藏到屏幕外 → 探针等页面加载 → 播完交接 |
| 热启动 | 进程已存在（含托盘化） | 不启新实例 → 直接藏窗口 → 立即视为就绪 → 播完交接；托盘化的窗口会被重新显示 |

### 预加载：为什么不再白屏

Electron 应用冷启动时窗口先出现、页面仍全白（实测约 3.5 秒），旧版本只等"窗口句柄出现"就交接，于是用户看到白屏。

现在用的是**内容就绪检测**：

1. 窗口一出现就移到屏幕外（实测：移出屏幕不影响页面加载）
2. `ready-probe.py` 每 0.25s 对应用所有大窗口做一次 `PrintWindow` 截图（不受动画遮挡影响），算中心区域灰度标准差：白屏 ≈ 0，已加载 ≈ 30+
3. 连续两次 ≥ 阈值（默认 15）→ 判定就绪，记录"真正画出内容的那个窗口句柄"
4. 视频播完 + 页面就绪 → 才允许交接；页面慢就留着动画最后一帧等（上限 `-HoldCapS`）

## 组件（scripts/）

| 文件 | 作用 |
|---|---|
| `launcher.vbs` | 启动器，快捷方式的新目标；wscript 运行无控制台窗口；防重入守卫；全部路径集中在顶部配置区 |
| `play.ps1` | WPF 播放器（`-STA` 运行）：**无边框全屏置顶**（默认铺满主屏工作区；`-Width/-Height` 可切成窗口化）、**默认带声音**（`-Muted` 可静音）、点击切换静音、Esc 跳过、播完定格打标记、30s 自关兜底 |
| `wait-kiosk.ps1` | 守护进程：等窗口上屏→置顶→按需启动应用→**全程把应用窗口藏在屏幕外**→内容就绪检测→摆位并快速关闭动画→激活应用 |
| `stop-intro.ps1` | 快速通道：播放中再次点击图标→立即结束动画并聚焦应用 |
| `veil.py` | 深色遮罩（Python ctypes 原生窗口）：铺满主屏工作区（与动画同矩形）；`--app <exe>` 会在画遮罩前先把应用窗口藏起来，避免应用边框从遮罩四周露出 |
| `ready-probe.py` | 内容就绪探针：`PrintWindow` + 灰度标准差，判断页面是白屏还是已渲染；`--app <exe>` 模式每轮自动刷新进程与窗口列表 |
| `winframe.py` | 窗口几何工具：`workarea` 主屏工作区（全屏目标矩形）、`measure` 列出窗口外框/客户区/边框增量，`delta`、`align-target`（按**实测**边框算目标外框）、`check-client`（校验客户区落点） |
| `wbutil.ps1` | 共享工具库：进程/窗口检测（按 PID 枚举、尺寸过滤、标题优先级）、客户区对齐、窗口停放/复位、置顶与强制前台、日志 |
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
编码不是 H.264 时先按「视频编码要求」转码。

`veil.py` / `ready-probe.py` / `winframe.py` 需要 python（启动器配置区里的 `python` 路径）。若目标机器没有 python：
遮罩会缺失（最多少量闪窗）、内容探针会退回纯计时交接（仍能工作，只是不再有"预加载"效果），不会装坏。

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

## 全屏与像素级对齐

默认**全屏**：片头播放器、遮罩、应用的**客户区**三者落在同一个矩形上——**主屏工作区**（屏幕减去任务栏），否则会出现三类观感问题（本 skill 都踩过）：

| 现象 | 原因 | 正确做法 |
|---|---|---|
| 动画结束后工作台比动画小、四周露动画边 | 只把应用外框设成动画尺寸，客户区被标题栏/边框吃掉（实测 1120×630 外框 → 1105×622 客户区） | 设尺寸时按**客户区**为目标：外框 = 目标 + 该窗口实测边框增量 |
| 动画播放时能看到工作台白边/白边闪一下 | 应用窗口的外框**大于**无边框动画窗口，摆在屏幕上必露边 | 动画期间应用窗口一律藏到屏幕外（`x=-4000`），播完再摆进来 |
| 底部约 40px 内容被任务栏压住 | 目标取了整块屏幕，而应用窗口不是 topmost | 目标取**工作区**（`SystemParametersInfo(SPI_GETWORKAREA)`），不是整屏 |

要点：

- **全屏 = 工作区，不是整屏**：播放器（WPF `SystemParameters.WorkArea`）、遮罩（`SPI_GETWORKAREA`）、守护（`winframe.py workarea`）三处取同一个矩形；任务栏始终可见，应用内容不会被压住。
- **判据用"覆盖"，不用"相等"**：应用客户区必须**完全包含**动画矩形（少 1px 就露边），多出的几像素落在屏幕外或任务栏后面，看不出来。`Test-ClientOnIntroRect` 同时返回 `ok`（逐像素相等）和 `covers`（完全覆盖）。
- **边框增量必须按窗口实测**（`winframe.py delta`）。Electron 窗口的 style 声称 `WS_CAPTION`，但应用自己绘制标题栏，`AdjustWindowRectEx` 会报 16×39 而实际只有 15×8；同一窗口在移动后还会重绘标题栏，实测出现过 15×7 / 15×8 / 15×15 三种增量。
- **校准要闭环**：设置后量一次客户区落点，不足就按差值补；写入缓存的最终外框，后续只用 `SetWindowPos`（实测移入 3-8ms，露边窗口期可忽略）。
- **校准要在屏幕外做**：校准需要移动窗口，若此时动画还在屏幕上，那几帧就会露边。`Set-AppWindowRect -Offscreen` 就是为此；离屏时用"客户区相对外框的偏移"推算正确位置，因此不需要窗口在可见区域内。
- **关动画要快**：交接时先摆位（不动 z-order），再用窗口句柄取 PID 直接结束播放器（`Close-Kiosk` 走 WMI 有几百毫秒延迟，期间必露边）。
- 想回到窗口化：三处同填一个尺寸（见下）。

## 关键规则（违反必闪）

1. **不用浏览器做播放器**——Edge 后台驻留进程会劫持 kiosk 启动（视频塞进用户自己的 profile，片头不播还闪窗）。用 play.ps1 原生 WPF 窗口。
2. **进程级检测应用是否在运行**，不是窗口级——托盘化/最小化时窗口检测会漏，误启第二实例触发单实例激活闪烁。Electron 排除 `--type=` 辅助进程。
3. **上屏即置顶**，不等标题就绪、不等应用启动；循环维持（默认 80ms）。
4. **视频结束用标题标记**（`<tag>-DONE`），不轮询进程（Edge 辅助进程 lingering 会把动画误判成 15-20s）。
5. **点击到上屏之间必须有遮罩**；keeper 开头不要清扫遮罩（会把刚拉起的误杀）。
6. **就绪看内容，不看窗口句柄**——Electron 窗口出现时页面还是白屏；用 `ready-probe.py` 的灰度标准差判定，视频播完 + 页面就绪才交接，页面慢就定格等（`-HoldCapS` 封顶）。
7. **动画期间应用窗口必须在屏幕外**——应用外框大于无边框动画窗口，留在屏幕上必露边；而且要**每轮重新藏**（应用会异步恢复自己记住的窗口位置，一次性藏必漏）。
8. **多窗口陷阱**——Electron 冷启动会同时存在多个同尺寸顶层窗口（无标题"影子"窗口 + 真主窗口），还可能先弹 136×39 的小窗。找窗口必须：过滤小尺寸、有标题优先、同优先级取面积最大；藏窗口要**全部藏**（任一都可能是显示白屏的那个）。
9. **收尾 = 视频结束 且 应用窗口就绪**；视频结束时**一个进程都没有**（托盘化）才 spawn 实例，进程在就只等窗口，绝不拉第二实例。
10. .lnk 手术只用**等长替换**，IDList 不可去、不可重建（重建的 IDListSize 差一错误必死）。
11. **vbs 配置区禁止非 ASCII**——宿主按 GBK 读 vbs，中文标题模式变乱码：匹配不上还是小事，`-like` 遇到乱码里的 `[` 会直接杀死 keeper 进程（日志停在"marker seen"，无任何报错）。非 ASCII 标题用 `*`。
12. **不要在 `Start-Process` 上用 `-NoNewWindow`**——若系统同时存在 `http_proxy` 与 `HTTP_PROXY` 环境变量，PowerShell 建环境字典时撞键直接抛异常（`已添加项。字典中的关键字:"http_proxy"...`），子进程根本起不来。要输出日志就让被启动的脚本自己写文件。

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
| `-PollMs` | `80` | 守护循环间隔（越小越不容易漏掉应用"偷偷挪回窗口"，代价是 CPU） |
| `-SettleMs` | `600` | 视频结束后确认窗口稳定的时长 |
| `-HoldCapS` | `4` | 视频结束后等页面就绪的上限（超时就按现有内容交接，兜底不卡死） |
| `-TotalCapS` | `90` | 全流程总上限 |
| `-WindowWaitS` | `12` | 等播放器窗口上屏的上限 |
| `-SelfCloseS` | `30` | 播放器自关兜底（视频时长+15 左右） |
| `-Muted` | 关 | 播放器静音开关：默认**带声音**播放；加 `-Muted` 恢复静音起播 |
| `-Width` / `-Height` | `0` / `0` | `0` = 全屏（主屏工作区，任务栏可见）；填具体值则窗口化并在屏幕居中。要改窗口大小必须同步 `wbutil.ps1` 的 `AppWinW/AppWinH` 与 `veil.py` 的 `VEIL_W/VEIL_H` |
| `-Video` | (必填) | 片头视频绝对路径 |

### 全屏 / 窗口化

默认全屏，三处都用 0（播放器不传 `-Width/-Height`），矩形自动取主屏工作区。要改成窗口化，三处同步填同一个尺寸：

```powershell
play.ps1     param([int]$Width = 1120, [int]$Height = 630)
wbutil.ps1   [int]$script:AppWinW = 1120;  [int]$script:AppWinH = 630
veil.py      VEIL_W, VEIL_H = 1120, 630
```

三者不一致就会出现"黑框比动画大"或"动画和应用一样大但应用内容更小"这类观感问题。

### 视频编码要求

WPF 播放器走 Media Foundation：**H.264 (avc1) + yuv420p + AAC 最稳**。HEVC 源在没装 HEVC 扩展的机器上会黑屏，install 时先用 ffmpeg 转一遍：

```bash
ffmpeg -i source.mp4 -c:v libx264 -crf 17 -preset slow -pix_fmt yuv420p \
       -c:a aac -b:a 192k -movflags +faststart intro.mp4
```

若片头带"XX生成"之类固定位置水印，用 `delogo` 在转码时一并去掉（位置全片固定才有效）：

```bash
ffmpeg -i source.mp4 -vf "delogo=x=4:y=4:w=100:h=36,delogo=x=460:y=262:w=102:h=54" ...
```

## 环境注意（Windows + 本 agent）

- 播放器必须 `powershell -STA` 启动（WPF 需要 STA 线程）。
- 系统执行策略：所有 .ps1 用 `powershell -NoProfile -ExecutionPolicy Bypass -File` 运行。
- 启动 .lnk 测试用 `cmd //c start "" "C:/path/x.lnk"`；Bash 工具会转换反斜杠，含反斜杠的命令走 PowerShell 工具。
- 测试时不要杀应用主进程（可能是当前会话宿主）。
- 更多工具层坑见 `references/pitfalls.md` 第 11 条。
