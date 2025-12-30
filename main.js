let lapData = [];
let ascending = true;

// 时间字符串转毫秒
function timeToMs(timeStr) {
  const [min, rest] = timeStr.split(":");
  const [sec, ms] = rest.split(".");
  return parseInt(min) * 60000 + parseInt(sec) * 1000 + parseInt(ms);
}

// 渲染表格
function renderTable(data) {
  const tbody = document.querySelector("#lapTable tbody");
  tbody.innerHTML = "";

  data.forEach((item, index) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${index + 1}</td>
      <td>${item.driver}</td>
      <td>${item.track}</td>
      <td>${item.time}</td>
      <td>${item.car}</td>
      <td>${item.date}</td>
    `;
    tbody.appendChild(tr);
  });
}

// 渲染赛道选项
function renderTrackOptions(data) {
  const select = document.getElementById("trackSelect");
  const tracks = [...new Set(data.map(item => item.track))]; // 去重
  tracks.forEach(track => {
    const option = document.createElement("option");
    option.value = track;
    option.textContent = track;
    select.appendChild(option);
  });
}

// 点击表头排序
document.getElementById("timeHeader").addEventListener("click", () => {
  const filtered = getFilteredData();
  filtered.sort((a, b) => ascending ? timeToMs(a.time) - timeToMs(b.time) : timeToMs(b.time) - timeToMs(a.time));
  ascending = !ascending;
  renderTable(filtered);
});

// 根据赛道筛选
function getFilteredData() {
  const select = document.getElementById("trackSelect");
  const track = select.value;
  return track === "all" ? lapData : lapData.filter(item => item.track === track);
}

// 赛道切换事件
document.getElementById("trackSelect").addEventListener("change", () => {
  const filtered = getFilteredData();
  renderTable(filtered);
});

// 读取数据
fetch("data.json")
  .then(res => res.json())
  .then(data => {
    lapData = data;
    renderTrackOptions(data);
    renderTable(data); // 默认显示全部
  })
  .catch(err => console.error("读取数据失败", err));
