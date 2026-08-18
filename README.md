# BEAMNG.DRIVE 多赛道圈速榜

> 纯靠各路 AI 写的代码，这个 GitHub Pages 也没整明白

## 🛠 项目说明
- **技术栈**：AI 生成的代码 + GitHub Pages
- **数据来源**：手动提交
- **更新频率**：跑了就更新
- **灵感来源**：键盘车神教的圈速榜网站

### 本地预览方式
在终端执行以下命令启动本地服务：
```bash
python server.py
```
打开浏览器，输入地址 http://localhost:8000 即可查看 HTML 效果。

### 本地录入成绩（推荐）
`python server.py` 启动后，网页顶部会出现「＋ 录入成绩」按钮：
- 跑完一圈 → 填写赛道/车辆/圈速等 → 提交，数据**直接写入本地 data.json**
- 全部录完 → `git add data.json && git commit && git push`，线上 GitHub Pages 即为最新数据
- 线上网站（GitHub Pages）只读展示，录入功能自动隐藏

> 如果只是临时看看效果，`python -m http.server` 也可以，但没有录入功能。