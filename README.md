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
├── Lap_Time_Leaderboard/   # 网页源码（GitHub Pages 部署目录）
│   ├── index.html          # 主页
│   ├── main.js             # 核心逻辑
│   ├── record-form.js      # 成绩录入表单
│   ├── theme-editor.js     # 主题调色盘
│   ├── data.json           # 圈速数据
│   ├── favicon.svg         # 网站图标
│   ├── server.py           # 本地服务器（含录入接口）
│   └── CNAME               # 自定义域名
└── .github/workflows/      # GitHub Actions 部署工作流
```

## 本地预览

在 `Lap_Time_Leaderboard` 目录下启动本地服务：

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

## 部署到 GitHub Pages

网页源码位于 `Lap_Time_Leaderboard/` 子目录，通过 GitHub Actions 自动部署：

1. 仓库 **Settings → Pages** → Source 选择 **GitHub Actions**
2. 推送代码到 `main` 分支后，`.github/workflows/pages.yml` 会自动构建并部署
3. 自定义域名在 **Settings → Pages → Custom domain** 中配置
