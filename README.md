# 🏁 BeamNG.Drive 圈速排行榜

> 一个轻量级、响应式的 BeamNG.Drive 圈速记录与查询工具。

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![HTML5](https://img.shields.io/badge/HTML5-E34F26?logo=html5&logoColor=white)
![CSS3](https://img.shields.io/badge/CSS3-1572B6?logo=css3&logoColor=white)
![JavaScript](https://img.shields.io/badge/JavaScript-F7DF1E?logo=javascript&logoColor=black)

这是一个纯前端实现的静态网页，无需后端数据库，非常适合个人记录或小团队分享 BeamNG.Drive 游戏中的 Time Attack 成绩。它支持多维度的筛选、排序和统计功能。

## ✨ 功能特性

- **📊 多维度筛选**：支持按赛道、车辆、驱动形式、动力类型（油/电）、起步方式等进行组合筛选。
- **🔄 动态排序**：点击表头即可对任意列进行升序/降序排列，智能识别时间格式。
- **📱 响应式设计**：完美适配桌面端和移动端，移动端自动调整布局。
- **📈 实时统计**：实时计算当前筛选结果下的总记录数、最快圈速和平均马力。
- **🎨 极简美学**：深色玻璃拟态风格，高对比度设计，视觉体验舒适。

## 🚀 在线预览

[GitHub Pages 演示链接](https://furryshaode.github.io/BeamNG.Time_Attack/)

## 📦 安装与运行

本项目为纯静态页面，无需安装 Node.js 或其他依赖。

### 克隆仓库
```bash
git clone https://github.com/你的用户名/BeamNG.Time_Attack.git
cd BeamNG.Time_Attack
```

### 运行方式

**方法一：使用 VS Code Live Server (推荐)**
1. 在 VS Code 中安装 "Live Server" 插件。
2. 右键点击 `index.html`，选择 "Open with Live Server"。

**方法二：使用 Python**
```bash
# Python 3
python -m http.server
```
然后在浏览器访问 `http://localhost:8000`

**方法三：直接打开**
直接双击 `index.html` 即可。
*注意：部分浏览器直接打开可能会因 CORS 安全策略导致无法读取 `data.json`，推荐使用本地服务器运行。*

## 📝 数据管理

所有的圈速数据都存储在 `data.json` 文件中。

### 数据格式
每一条记录是一个 JSON 对象，包含以下字段：

```json
  {
    "car": "Hirochi SBR4 RWD Base(DCT)",
    "track": "Hirochi赛车场",
    "layout": "短途竞速环道",
    "time": "01:08.769",
    "start_type": "动态起步",
    "power_type": "油车",
    "game_version": "0.38.3",
    "control_type": "手柄",
    "drivetrain": "后驱",
    "power": 209,
    "date": "2025-12-30"
  }
```

### 如何添加新成绩
1. 打开 `data.json`。
2. 按照上述格式，在数组中添加一个新的对象。
3. 保存文件，刷新网页即可看到更新。

## 🛠️ 技术栈

- **HTML5**：语义化标签构建结构。
- **CSS3**：Flexbox 布局，CSS 变量，渐变与动画效果。
- **Vanilla JavaScript (ES6+)**：原生 JS 实现数据获取、DOM 操作、排序算法和事件处理，无第三方库依赖。

## 📄 许可证

本项目采用 [MIT License](LICENSE) 开源协议。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！如果你有新的功能建议或发现了 Bug，请随时告诉我。

---

<div align="center">
  Made with ❤️ by ShaoDe
</div>
