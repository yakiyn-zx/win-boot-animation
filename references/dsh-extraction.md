# 从 DSH 启动动画插件包提取片头视频

DSH（DeepSeek Harness）的 `dsh-boot-animation` 插件包**不能**装进 WorkBuddy——它是 cordis 插件体系（`shell.overlay` / `sidebar.footer` 槽位、`ctx.inject` 动态注入），与 WorkBuddy 的技能/MCP/连接器体系不兼容。但包内的片头视频可以提取出来，做成 WorkBuddy 自己的启动动画（本 skill 的主题）。

## 插件包结构（v0.4.2）

```
dsh-boot-animation-main.zip
├── lib/
│   ├── client.js          # 前端注入代码
│   └── clips.data.js      # ~12MB base64：4 段片头视频内嵌在此
├── cordis.patch.yml       # 插件清单（槽位声明）
└── submission/            # 提交材料
```

## 提取方法 A：从 zip 内嵌 base64（离线）

1. 解压 zip，定位 `lib/clips.data.js`
2. 该文件是 base64 数据（可能带 JS 包装），按 `data:video/mp4;base64,` 或裸 base64 段切分
3. base64 解码得到 4 个 mp4
4. 校验：文件头 4 字节应为 `ftyp`（偏移 4-8），解析 moov/mvhd 拿时长

```bash
python - <<'EOF'
import base64, re, struct
raw = open('clips.data.js','rb').read()
# 找到所有 base64 长串（视频通常 > 100KB）
for i, m in enumerate(re.finditer(rb'[A-Za-z0-9+/=]{100000,}', raw)):
    data = base64.b64decode(m.group(0))
    if data[4:8] == b'ftyp':
        out = f'clip{i}.mp4'
        open(out,'wb').write(data)
        print(out, len(data))
EOF
```

## 提取方法 B：从运行中的 DSH 实例（在线，最省事）

插件已在 DSH 里加载运行时（实测端口 **19387**）：

```bash
# 1) 状态/清单（确认插件在跑、拿到视频路由）
curl -s http://127.0.0.1:19387/status
curl -s http://127.0.0.1:19387/videos

# 2) 直接拉视频（media 路由，支持 Range）
curl -s -D - -o cyberpunk.mp4 http://127.0.0.1:19387/media/<file>.mp4

# 3) 校验
python -c "d=open('cyberpunk.mp4','rb').read(12); print(d[4:8])"   # 应输出 b'ftyp'
```

实测：`cyberpunk.mp4` 1,856,280 字节，时长 7.05s。

## 4 段片头与选择

DSH 插件内含 4 段片头（intro/clip 各段），用户按需选段； WorkBuddy 落地时选了**赛博朋克（cyberpunk）**那段（7.05s）。只保留一段：播放器和 keeper 都是单视频设计，多段需要自行扩展播放列表。

## 放进本 skill 的安装流程

提取出的 mp4 复制到安装目录的 `videos\intro.mp4`（或任意名，同步改 launcher.vbs 里 `-Video` 参数），然后按 SKILL.md 的安装步骤走。
