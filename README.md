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

### 游戏自动录入（BeamNG 计时赛）
1. 把 `beamng_lap_bridge.lua` 复制到 BeamNG 用户目录的 `lua/ge/extensions/` 下
   （0.39+ 默认：`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\lua\ge\extensions\`；
   旧版：`Documents\BeamNG.drive\lua\ge\extensions\`；游戏设置 → 管理用户文件夹 可查看）
2. 启动 `python server.py`，保持运行（自动探测用户目录）
3. 游戏内跑计时赛（Time Trial / Quick Race）：**每过一圈成绩自动写入 data.json**，
   网页上实时出现新记录，无需手动填写
4. 自动采集：圈速/赛道/布局/车辆/马力（多引擎取和）/驱动/动力（油车·电车·混动）/
   模组/游戏版本/日期；控制设备用默认值「手柄」（可改 `server.py` 顶部常量）
5. 新赛道第一次出现时，网页「待确认赛道」面板确认显示名（或直接编辑 `track_map.json`）

> 游戏侧数据流：beamng_lap_bridge.lua → 用户目录 beamng_lap_bridge/records.jsonl
> → server.py 轮询去重 → data.json