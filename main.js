let lapData = [];
let currentSort = { field: 'time', ascending: true };

// 时间字符串转毫秒
function timeToMs(timeStr) {
  if (!timeStr || timeStr === '--:--.--' || timeStr === '') return Infinity;
  
  // 处理格式如 "1:23.456" 或 "2:05.123"
  const parts = timeStr.split(/[:.]/);
  
  if (parts.length === 3) {
    const minutes = parseInt(parts[0]) || 0;
    const seconds = parseInt(parts[1]) || 0;
    const milliseconds = parseInt(parts[2].padEnd(3, '0').substring(0, 3)) || 0;
    
    return minutes * 60000 + seconds * 1000 + milliseconds;
  }
  
  // 如果格式不正确，返回一个很大的数，使其排在最后
  return Infinity;
}

// 毫秒转时间字符串
function msToTime(ms) {
  if (ms === Infinity || ms === 0) return '--:--.--';
  
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  const milliseconds = ms % 1000;
  
  return `${minutes}:${seconds.toString().padStart(2, '0')}.${milliseconds.toString().padStart(3, '0').slice(0, 3)}`;
}

// 获取驱动方式对应的CSS类
function getDrivetrainClass(drivetrain) {
  if (!drivetrain) return '';
  if (drivetrain.includes('前驱')) return 'drivetrain-fwd';
  if (drivetrain.includes('后驱')) return 'drivetrain-rwd';
  if (drivetrain.includes('四驱')) return 'drivetrain-awd';
  return '';
}

// 获取控制方式对应的CSS类
function getControlTypeClass(controlType) {
  if (!controlType) return '';
  if (controlType.includes('方向盘')) return 'control-wheel';
  if (controlType.includes('手柄') || controlType.includes('游戏手柄')) return 'control-gamepad';
  if (controlType.includes('键盘')) return 'control-keyboard';
  return '';
}

// 渲染表格
function renderTable(data) {
  const tbody = document.querySelector("#lapTable tbody");
  tbody.innerHTML = "";

  if (data.length === 0) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td colspan="9" class="no-data">没有找到匹配的记录</td>`;
    tbody.appendChild(tr);
    return;
  }

  // 按当前排序规则排序数据
  const sortedData = sortData(data, currentSort.field, currentSort.ascending);
  
  // 渲染排序后的数据，排名自动生成
  sortedData.forEach((item, index) => {
    const tr = document.createElement("tr");
    
    // 为前三名添加特殊样式
    if (index < 3) {
      tr.className = `rank-${index + 1}`;
    }
    
    tr.innerHTML = `
      <td><strong>${index + 1}</strong></td>
      <td class="car-cell">${item.car || '未知车辆'}</td>
      <td>${item.track || '未知赛道'}</td>
      <td>${item.layout || '标准布局'}</td>
      <td class="time-cell">${item.time || '--:--.--'}</td>
      <td class="power-cell">${item.power ? item.power + ' hp' : '--'}</td>
      <td class="${getDrivetrainClass(item.drivetrain)}">${item.drivetrain || '--'}</td>
      <td class="hide-mobile"><span class="control-type ${getControlTypeClass(item.control_type)}">${item.control_type || '--'}</span></td>
      <td>${item.date || '--'}</td>
    `;
    tbody.appendChild(tr);
  });

  // 更新统计信息
  updateStats(sortedData);
}

// 更新统计信息
function updateStats(data) {
  document.getElementById('totalRecords').textContent = data.length;
  
  // 最快圈速（从所有数据中找）
  const allTimes = lapData
    .map(item => timeToMs(item.time))
    .filter(ms => ms !== Infinity);
    
  if (allTimes.length > 0) {
    const fastest = Math.min(...allTimes);
    document.getElementById('fastestTime').textContent = msToTime(fastest);
  } else {
    document.getElementById('fastestTime').textContent = '--:--.--';
  }
  
  // 平均马力（从当前显示的数据中计算）
  const validPower = data
    .filter(item => item.power && !isNaN(item.power))
    .map(item => Number(item.power));
    
  if (validPower.length > 0) {
    const avgPower = Math.round(validPower.reduce((a, b) => a + b, 0) / validPower.length);
    document.getElementById('avgPower').textContent = avgPower;
  } else {
    document.getElementById('avgPower').textContent = '0';
  }
}

// 填充筛选选项
function populateFilters(data) {
  const tracks = [...new Set(data.map(item => item.track).filter(Boolean))];
  const cars = [...new Set(data.map(item => item.car).filter(Boolean))];
  const layouts = [...new Set(data.map(item => item.layout).filter(Boolean))];
  
  const trackSelect = document.getElementById("trackSelect");
  const carSelect = document.getElementById("carSelect");
  const layoutSelect = document.getElementById("layoutSelect");
  
  // 清除现有选项（除了第一个）
  while (trackSelect.options.length > 1) trackSelect.remove(1);
  while (carSelect.options.length > 1) carSelect.remove(1);
  while (layoutSelect.options.length > 1) layoutSelect.remove(1);
  
  // 填充赛道选项
  tracks.sort().forEach(track => {
    const option = document.createElement("option");
    option.value = track;
    option.textContent = track;
    trackSelect.appendChild(option);
  });
  
  // 填充车辆选项
  cars.sort().forEach(car => {
    const option = document.createElement("option");
    option.value = car;
    option.textContent = car;
    carSelect.appendChild(option);
  });
  
  // 填充布局选项
  layouts.sort().forEach(layout => {
    const option = document.createElement("option");
    option.value = layout;
    option.textContent = layout;
    layoutSelect.appendChild(option);
  });
}

// 排序函数
function sortData(data, field, ascending) {
  return [...data].sort((a, b) => {
    let aVal = a[field];
    let bVal = b[field];
    
    // 特殊处理时间字段
    if (field === 'time') {
      aVal = timeToMs(aVal);
      bVal = timeToMs(bVal);
    }
    
    // 处理数值字段
    if (field === 'power') {
      aVal = Number(aVal) || 0;
      bVal = Number(bVal) || 0;
    }
    
    // 处理空值
    if (aVal === undefined || aVal === null) aVal = '';
    if (bVal === undefined || bVal === null) bVal = '';
    
    // 字符串字段（包括日期）
    if (typeof aVal === 'string' && typeof bVal === 'string') {
      // 如果是日期字段，转换为时间戳比较
      if (field === 'date') {
        aVal = new Date(aVal).getTime() || 0;
        bVal = new Date(bVal).getTime() || 0;
      } else {
        // 普通字符串比较
        return ascending ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
      }
    }
    
    // 数值字段（包括时间戳）
    if (ascending) {
      return aVal < bVal ? -1 : aVal > bVal ? 1 : 0;
    } else {
      return bVal < aVal ? -1 : bVal > aVal ? 1 : 0;
    }
  });
}

// 应用筛选
function applyFilters() {
  const track = document.getElementById("trackSelect").value;
  const car = document.getElementById("carSelect").value;
  const drivetrain = document.getElementById("drivetrainSelect").value;
  const layout = document.getElementById("layoutSelect").value;
  
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
  
  renderTable(filtered);
}

// 更新排序指示器
function updateSortIndicator() {
  // 清除所有排序指示器
  document.querySelectorAll('th').forEach(th => {
    th.classList.remove('sort-asc', 'sort-desc');
  });
  
  // 添加当前排序指示器
  const currentHeader = document.querySelector(`th[data-sort="${currentSort.field}"]`);
  if (currentHeader) {
    currentHeader.classList.add(currentSort.ascending ? 'sort-asc' : 'sort-desc');
  }
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
  document.getElementById("layoutSelect").addEventListener("change", applyFilters);
  document.getElementById("carSelect").addEventListener("change", applyFilters);
  document.getElementById("drivetrainSelect").addEventListener("change", applyFilters);
  
  // 重置按钮
  document.getElementById("resetFilters").addEventListener("click", () => {
    document.getElementById("trackSelect").value = "all";
    document.getElementById("layoutSelect").value = "all";
    document.getElementById("carSelect").value = "all";
    document.getElementById("drivetrainSelect").value = "all";
    applyFilters();
  });
}

// 初始化页面
function initPage() {
  // 从data.json读取数据
  fetch("data.json")
    .then(res => {
      if (!res.ok) {
        throw new Error(`HTTP错误 ${res.status}: 无法加载数据文件`);
      }
      return res.json();
    })
    .then(data => {
      if (!Array.isArray(data)) {
        console.error("数据格式错误：应为数组");
        showError("数据格式错误：应为数组格式");
        return;
      }
      
      if (data.length === 0) {
        console.warn("数据文件为空");
        showMessage("数据文件为空，请添加圈速记录");
        return;
      }
      
      lapData = data;
      
      // 设置游戏版本和更新时间
      if (data.length > 0) {
        // 查找最新的日期
        const sortedByDate = [...data].sort((a, b) => {
          const dateA = new Date(a.date || 0);
          const dateB = new Date(b.date || 0);
          return dateB - dateA;
        });
        
        const latest = sortedByDate[0];
        
        document.getElementById("gameVersion").textContent = latest.game_version || "0.38.3";
        document.getElementById("updateTime").textContent = latest.date || "2025-12-30";
      }
      
      populateFilters(lapData);
      updateSortIndicator();
      applyFilters();
      initEventListeners();
    })
    .catch(err => {
      console.error("读取数据失败:", err);
      showError(`数据加载失败: ${err.message}`);
    });
}

// 显示错误信息
function showError(message) {
  const tbody = document.querySelector("#lapTable tbody");
  tbody.innerHTML = `<tr><td colspan="9" class="error-message">${message}</td></tr>`;
  
  document.getElementById('totalRecords').textContent = '0';
  document.getElementById('fastestTime').textContent = '--:--.--';
  document.getElementById('avgPower').textContent = '0';
}

// 显示信息
function showMessage(message) {
  const tbody = document.querySelector("#lapTable tbody");
  tbody.innerHTML = `<tr><td colspan="9" class="no-data">${message}</td></tr>`;
  
  document.getElementById('totalRecords').textContent = '0';
  document.getElementById('fastestTime').textContent = '--:--.--';
  document.getElementById('avgPower').textContent = '0';
}

// 页面加载完成后初始化
document.addEventListener("DOMContentLoaded", initPage);