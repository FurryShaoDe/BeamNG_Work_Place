let lapData = [];
let currentSort = { field: 'time', ascending: true };

// 时间字符串转毫秒
function timeToMs(timeStr) {
  if (!timeStr || timeStr === '--:--.--') return Infinity;
  const parts = timeStr.split(/[:.]/);
  if (parts.length === 3) {
    return parseInt(parts[0]) * 60000 + parseInt(parts[1]) * 1000 + parseInt(parts[2]);
  }
  return Infinity;
}

// 获取动力类型图标
function getPowerTypeIcon(powerType) {
  return powerType === '电车' ? '⚡' : '⛽';
}

// 获取起步方式图标
function getStartTypeIcon(startType) {
  return startType === '静态起步' ? '🛑' : '🚦';
}

// 渲染表格
function renderTable(data) {
  const tbody = document.querySelector("#lapTable tbody");
  tbody.innerHTML = "";

  if (data.length === 0) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td colspan="11" style="text-align: center; padding: 40px;">没有找到匹配的记录</td>`;
    tbody.appendChild(tr);
    return;
  }

  data.forEach((item, index) => {
    const tr = document.createElement("tr");
    tr.className = `rank-${index + 1}`;
    tr.innerHTML = `
      <td><strong>${index + 1}</strong></td>
      <td class="car-cell">${item.car || '未知车辆'}</td>
      <td>${item.track || '未知赛道'}</td>
      <td class="hide-mobile">${item.layout || '--'}</td>
      <td class="time-cell">${item.time || '--:--.--'}</td>
      <td class="power-cell">${item.power ? item.power + ' hp' : '--'}</td>
      <td class="${getDrivetrainClass(item.drivetrain)}">${item.drivetrain || '--'}</td>
      <td>${getPowerTypeIcon(item.power_type || '')} ${item.power_type || '--'}</td>
      <td class="hide-mobile">${getStartTypeIcon(item.start_type || '')} ${item.start_type || '--'}</td>
      <td class="hide-mobile"><span class="control-type ${getControlTypeClass(item.control_type)}">${item.control_type || '--'}</span></td>
      <td>${item.date || '--'}</td>
    `;
    tbody.appendChild(tr);
  });

  // 更新统计信息
  updateStats(data);
}

// 填充筛选选项
function populateFilters(data) {
  const tracks = [...new Set(data.map(item => item.track).filter(Boolean))];
  const cars = [...new Set(data.map(item => item.car).filter(Boolean))];
  const layouts = [...new Set(data.map(item => item.layout).filter(Boolean))];
  
  const trackSelect = document.getElementById("trackSelect");
  const carSelect = document.getElementById("carSelect");
  const layoutSelect = document.getElementById("layoutSelect");
  
  // 填充赛道选项
  tracks.forEach(track => {
    const option = document.createElement("option");
    option.value = track;
    option.textContent = track;
    trackSelect.appendChild(option);
  });
  
  // 填充车辆选项
  cars.forEach(car => {
    const option = document.createElement("option");
    option.value = car;
    option.textContent = car;
    carSelect.appendChild(option);
  });
  
  // 填充布局选项
  layouts.forEach(layout => {
    const option = document.createElement("option");
    option.value = layout;
    option.textContent = layout;
    layoutSelect.appendChild(option);
  });
}

// 应用筛选
function applyFilters() {
  const track = document.getElementById("trackSelect").value;
  const car = document.getElementById("carSelect").value;
  const drivetrain = document.getElementById("drivetrainSelect").value;
  const layout = document.getElementById("layoutSelect").value;
  const startType = document.getElementById("startTypeSelect").value;
  const powerType = document.getElementById("powerTypeSelect").value;
  
  let filtered = lapData;
  
  if (track !== "all") {
    filtered = filtered.filter(item => item.track === track);
  }
  
  if (car !== "all") {
    filtered = filtered.filter(item => item.car === car);
  }
  
  if (drivetrain !== "all") {
    filtered = filtered.filter(item => item.drivetrain === drivetrain);
  }
  
  if (layout !== "all") {
    filtered = filtered.filter(item => item.layout === layout);
  }
  
  if (startType !== "all") {
    filtered = filtered.filter(item => item.start_type === startType);
  }
  
  if (powerType !== "all") {
    filtered = filtered.filter(item => item.power_type === powerType);
  }
  
  // 应用当前排序
  filtered = sortData(filtered, currentSort.field, currentSort.ascending);
  
  renderTable(filtered);
}

// 初始化事件监听
function initEventListeners() {
  // 表头点击排序
  document.querySelectorAll('.sortable').forEach(header => {
    header.addEventListener('click', () => {
      const field = header.dataset.sort;
      
      // 如果是同一字段，切换排序方向
      if (currentSort.field === field) {
        currentSort.ascending = !currentSort.ascending;
      } else {
        currentSort = { field, ascending: true };
      }
      
      updateSortIndicator();
      applyFilters();
    });
  });
  
  // 筛选器变化
  document.getElementById("trackSelect").addEventListener("change", applyFilters);
  document.getElementById("carSelect").addEventListener("change", applyFilters);
  document.getElementById("drivetrainSelect").addEventListener("change", applyFilters);
  document.getElementById("layoutSelect").addEventListener("change", applyFilters);
  document.getElementById("startTypeSelect").addEventListener("change", applyFilters);
  document.getElementById("powerTypeSelect").addEventListener("change", applyFilters);
  
  // 重置按钮
  document.getElementById("resetFilters").addEventListener("click", () => {
    document.getElementById("trackSelect").value = "all";
    document.getElementById("carSelect").value = "all";
    document.getElementById("drivetrainSelect").value = "all";
    document.getElementById("layoutSelect").value = "all";
    document.getElementById("startTypeSelect").value = "all";
    document.getElementById("powerTypeSelect").value = "all";
    applyFilters();
  });
}

// 初始化页面
function initPage() {
  // 从data.json读取数据
  fetch("data.json")
    .then(res => {
      if (!res.ok) throw new Error(`HTTP错误 ${res.status}`);
      return res.json();
    })
    .then(data => {
      if (!Array.isArray(data)) {
        console.error("数据格式错误：应为数组");
        return;
      }
      
      lapData = data;
      
      // 设置游戏版本和更新时间
      if (data.length > 0) {
        const latest = data.reduce((latest, item) => {
          return new Date(item.date) > new Date(latest.date) ? item : latest;
        }, data[0]);
        
        document.getElementById("gameVersion").textContent = latest.game_version || "0.38.3";
        document.getElementById("updateTime").textContent = latest.date || "2025-12-30";
      }
      
      // 初始排序：按圈速从快到慢
      lapData = sortData(lapData, 'time', true);
      
      populateFilters(lapData);
      updateSortIndicator();
      applyFilters();
      initEventListeners();
    })
    .catch(err => {
      console.error("读取数据失败:", err);
      const tbody = document.querySelector("#lapTable tbody");
      tbody.innerHTML = `<tr><td colspan="11" style="text-align: center; padding: 40px; color: #ff6b6b;">数据加载失败: ${err.message}</td></tr>`;
    });
}

// 页面加载完成后初始化
document.addEventListener("DOMContentLoaded", initPage);