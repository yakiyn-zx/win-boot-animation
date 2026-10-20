# Windows .lnk 手术方法论（等长替换）

把快捷方式目标从 `app.exe` 改到启动器（如 `app.vbs`），同时**保留显示名、图标、任务栏分组**的完整方法。全部经验来自实战（WorkBuddy.lnk 926 字节，5 项 IDList）。

## .lnk 文件结构（Shell Link 二进制格式）

```
偏移 0    76 字节 Header
           0x00  4  HeaderSize = 76
           0x04 16  LinkCLSID = 00021401-0000-0000-C000-000000000046
           0x14  4  LinkFlags（见下表）
           0x34  4  FileSize（目标文件大小）
           0x38  4  IconIndex
           0x3C  4  ShowCmd
偏移 76  LinkTargetIDList（IDList）—— 2 字节 TermID(0x0000) 结尾
偏移 ..  LinkInfo（含 LocalBasePath，ANSI NUL 结尾，无长度字段）
偏移 ..  StringData（按 flags 依次出现，均带 2 字节字符数前缀）：
           0x04 NAME / 0x08 RELATIVE_PATH / 0x10 WORKING_DIR /
           0x20 ARGUMENTS / 0x40 ICON_LOCATION（UTF-16LE）
偏移 ..  ExtraData（TrackerDataBlock 0xA0000003 + PropertyStoreDataBlock 0xA0000009 …）
偏移 ..  4 字节 TerminalBlock (0x00000000)
```

IDList 由若干 Item 串成，每项 = 2 字节 ItemSize + 数据 + 2 字节 TermID(0x0000)。文件项（叶子）type=0x32，目录项 type=0x31。典型 5 项：This PC GUID → 盘符 → 各级目录 → 文件项。**文件项内部同时存 ANSI 名字和 UTF-16 名字各一份**，还有 0xBEEF 扩展偏移等长度字段。

## 核心原则：纯等长字节替换

**唯一稳妥的手术方式**：让新启动器文件名与旧 exe 文件名**字符数相同**（如 `WorkBuddy.exe` → `WorkBuddy.vbs`，13 字符；`App.exe` → `app.vbs`，7 字符），然后只做字节级替换：

1. IDList 文件项内：ANSI 名字（含结尾 NUL）+ UTF-16 名字（含结尾 NUL）各替换一次
2. LinkInfo LocalBasePath：整条路径的叶子名替换

文件大小不变、所有长度/偏移字段原样有效。ICON_LOCATION、WORKING_DIR、ExtraData 一律不动——**ExtraData 里没有目标路径副本**（Tracker 只有机器名+GUID，PropertyStore 里那段是 AppUserModel.ID 如 `WorkBuddy.WorkBuddy`，用于任务栏分组）。

等长文件名速查（挑一个和原 exe 等长的）：
| exe 叶子名 | 等长启动器名 |
|---|---|
| `WorkBuddy.exe` (13) | `WorkBuddy.vbs` |
| `App.exe` (7) | `app.vbs` |
| `Code.exe` (8) | `code.vbs` |
| `idea64.exe` (10) | `idea64.vbs` |
| `chrome.exe` (10) | `chrome.vbs` |

字符数不一时，可在同目录造名：`App.exe`→`App1.vbs`（不行，7≠7 可以！`App1.vbs` 也是 8 字符……以实际数为准），原则只有一条：**新名字字符数 == 旧名字字符数**。

## 血泪教训（都是实测失败换来的）

1. **LinkTargetIDList 绝对不能去掉**。整文件重建（去 IDList + 重建 LinkInfo + 丢 ExtraData）→ "没有应用程序与此操作的指定文件关联"；对照实验证明仅去 IDList 也必失败。IDList 是壳层解析快捷键的必需结构。
2. **重建 IDList 时 IDListSize 差一即死**。头部 `IDListSize` 字段= 所有 Item 字节数 + 2 字节 TermID。写 `len(new_idlist) - 2`（TermID 重复扣除）→ 壳层解析错位 2 字节 → 同样的"没有应用程序关联"报错。**等长替换完全绕开这个坑**。
3. **丢 ExtraData 不能救活错误的重建**（ExtraData 无路径副本，丢了也没用）。
4. 改名前先用 `lnktool.py dump` 确认结构：IDListSize 字段 vs 实际 walked 字节数必须一致（dump 会打印 MISMATCH）。
5. 文件项里名字出现次数必须恰好 1 次（ANSI 1、UTF-16 1），多了说明有第二条路径副本要一并处理。
6. **动手前备份原文件**，改完先 `dump` 验证再替换真实文件；测试用独立 lnk 文件名（如 `AppAnim.lnk`）跑通再落地。

## 操作序列

```bash
# 1) 备份（两个位置：桌面 + 开始菜单）
cp "$DESKTOP/App.lnk" backup/desktop-App.lnk.orig
cp "$STARTMENU/App.lnk" backup/startmenu-App.lnk.orig

# 2) 结构体检
python lnktool.py dump "$DESKTOP/App.lnk"

# 3) 生成测试副本并 dump 验证（新叶子名必须等长）
python lnktool.py subst "$DESKTOP/App.lnk" "$DESKTOP/AppAnim.lnk" App.exe App.vbs
python lnktool.py dump "$DESKTOP/AppAnim.lnk"

# 4) 双击测试副本端到端跑通后，落地（先写临时文件再原子替换）
python lnktool.py subst "$DESKTOP/App.lnk" "$DESKTOP/App.lnk.tmp" App.exe App.vbs
mv "$DESKTOP/App.lnk.tmp" "$DESKTOP/App.lnk"
```

## 回退

```bash
cp backup/desktop-App.lnk.orig "$DESKTOP/App.lnk"
cp backup/startmenu-App.lnk.orig "$STARTMENU/App.lnk"
```

## 已知限制

- 本工具只做**等长替换**。不等长改名需要重建 IDList（危险）或借助第三方库，不在本 skill 范围内。
- 带 `--type=` 参数启动的 Electron 应用同理：进程级判断要排除辅助进程（`CommandLine -notlike '*--type=*'`），见 pitfalls.md。
