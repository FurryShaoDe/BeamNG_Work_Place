# BEAMNG.DRIVE 多赛道圈速榜

> 纯靠各路 AI 写的代码，这个 GitHub Pages 也没整明白

## 项目说明

| 项目 | 说明 |
| --- | --- |
| 技术栈 | AI 生成的代码 + GitHub Pages |
| 数据来源 | 手动提交 |
| 更新频率 | 跑了就更新 |
| 灵感来源 | [键盘车神教的圈速榜网站](https://kbracer.github.io) |

## 目录结构

```
BeamNG_Work_Place/
├── 一键启动.bat                # 双击启动【圈速榜】本地服务器（端口 8000）
├── Lap_Time_Leaderboard/      # 圈速榜网页源码（GitHub Pages 部署目录）
│   ├── index.html             # 主页
│   ├── main.js                # 核心逻辑
│   ├── record-form.js         # 成绩录入表单
│   ├── theme-editor.js        # 主题调色盘
│   ├── data.json              # 圈速数据
│   ├── favicon.svg            # 网站图标
│   ├── server.py              # 本地服务器（含录入接口）
│   └── CNAME                  # 自定义域名
├── Mod/
│   └── LapLog_Project/        # 圈速记录模组 + 本地分析台（详见其 README.md）
│       ├── LapLog/            # BeamNG 模组（游戏内 HUD app + vehicle controller）
│       ├── LapLog_Viewer/     # 本地分析台（Python + 自绘 canvas，端口 8010）
│       └── 一键启动查看器.bat  # 双击启动分析台并打开浏览器
└── .github/workflows/         # GitHub Actions 部署工作流
```

> 两个本地服务互不依赖，可同时跑：圈速榜 **8000**（录入/展示成绩）、分析台 **8010**（分析自己的 `lapLogs` 存档）。

## 本地预览

**最简单的方式：双击项目根目录的「一键启动.bat」**（需已安装 Python）。

启动器会自动：

1. 启动本地服务器（独立窗口运行，**关闭该窗口即停止服务**）
2. 自动打开浏览器访问 http://localhost:8000

如果服务器已在运行，再次双击会直接打开浏览器，不会重复启动。
没装 Python 时会给出提示。

也可以手动启动：

```bash
cd Lap_Time_Leaderboard
python server.py
```

打开浏览器访问 http://localhost:8000 即可查看效果。

> 如果只是临时看看效果，`python -m http.server` 也可以，但没有录入功能。

## 本地录入成绩（推荐）

`python server.py` 启动后，网页顶部会出现「＋ 录入成绩」按钮：

1. 跑完一圈 → 填写赛道/车辆/圈速等 → 提交，数据**直接写入本地 `data.json`**
2. 全部录完 → 提交并推送，线上 GitHub Pages 即为最新数据：

```bash
git add Lap_Time_Leaderboard/data.json
git commit -m "更新圈速数据"
git push
```

> 线上网站（GitHub Pages）只读展示，录入功能自动隐藏。

## 圈速记录模组与分析台（Mod/LapLog_Project/）

| 部分 | 说明 |
| --- | --- |
| `Mod/LapLog_Project/LapLog/` | BeamNG.drive 的圈速记录模组（由 flintt-ghost-racer-enhanced 派生）。当前 **1.0.3 / format 5**：样本 24 列 = 原 16 列 + 四轮垂直接地载荷 + 车身侧倾/俯仰 + **转向两列**（1.0.2/format 4 的载荷与姿态已实机确认）。装到 `<用户目录>/mods/unpacked/LapLog/`，进游戏在 UI Apps 里添加。文档：`LapLog/README.md`（英文，权威）/ `LapLog/README.zh-CN.md`（中文）。 |
| `Mod/LapLog_Project/LapLog_Viewer/` | 本地分析台：轨迹图、通道曲线（速度/踏板/档位/G/**转向**/悬架载荷/车身姿态）、**转向平衡图**（5° 分箱包络 + 小角度斜率 + 平台值，带速度段与剔除打滑）、悬架示意（正视图+侧视图，播放时实时形变）、ΔT、共享游标、实时播放、CSV 导出、删除记录；旧版按车辆存放的库单列在 `vehicles` 分组。浏览只读，只有"删除"会写 `lapLogs/_trash/`。 |

```bash
双击 Mod/LapLog_Project/一键启动查看器.bat      # 端口 8010，自动开浏览器
python Mod/LapLog_Project/LapLog_Viewer/server.py --port 8010 --root "…\BeamNG.drive\current"
```

⚠️ 改过 `LapLog_Viewer/` 里的代码后必须**重启查看器**（服务端是常驻进程，静态文件却是每次请求现读磁盘）；
页面检测到前后端版本不一致时会在顶部与面板里提示重启。细节（界面说明、接口、加新采样参数改哪里、计时精度与采样率结论）
见 `Mod/LapLog_Project/README.md` 与 `Mod/LapLog_Project/LapLog/README.md`（中文版 `LapLog/README.zh-CN.md`；`LapLog/NOTICE.md` 顶部另有中文说明，署名与许可证以英文原文为准）。

## 部署到 GitHub Pages

网页源码位于 `Lap_Time_Leaderboard/` 子目录，通过 GitHub Actions 自动部署：

1. 仓库 **Settings → Pages** → Source 选择 **GitHub Actions**
2. 推送代码到 `main` 分支后，`.github/workflows/pages.yml` 会自动构建并部署
3. 自定义域名在 **Settings → Pages → Custom domain** 中配置
