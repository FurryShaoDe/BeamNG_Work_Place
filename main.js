let lapData = [];
let currentSort = { field: 'time', ascending: true };

// 时间字符串转毫秒
function timeToMs(timeStr) {
  if (!timeStr || timeStr === '--:--.--' || timeStr === '') return Infinity;
  
  try {
    // 处理格式如 "1:23.456" 的时间
    const parts = timeStr.split(/[:.]/);
    if (parts.length === 3) {
      const minutes = parseInt(parts[0]) || 0;
      const seconds = parseInt(parts[1]) || 0;
      const milliseconds = parseInt(parts[2].padEnd(3, '0').slice(0, 3)) || 0;
      return minutes * 60000 + seconds * 1000 + milliseconds;
    }
    return Infinity;
  } catch (e) {
    console.warn(`无法解析时间格式: ${timeStr}`, e);
    return Infinity;
  }
}

// 毫秒转时间字符串
function msToTime(ms) {
  if (ms === Infinity || ms === null || ms === undefined) return '--:--.--';
  
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  const milliseconds = ms % 1000;
  
  return `${minutes}:${seconds.toString().padStart(2, '0')}.${milliseconds.toString().padStart(3, '0').slice(0, 3)}`;
}

// 获取驱动方式对应的CSS类
function getDrivetrainClass(drivetrain) {
  if (!drivetrain) return '';
  if (drivetrain.includes('前驱') || drivetrain === 'FWD') return 'drivetrain-fwd';
  if (drivetrain.includes('后驱') || drivetrain === 'RWD') return 'drivetrain-rwd';
  if (drivetrain.includes('四驱') || drivetrain === 'AWD') return 'drivetrain-awd';
  return '';
}

// 获取控制方式对应的CSS类
function getControlTypeClass(controlType) {
  if (!controlType) return '';
  if (controlType.includes('方向盘')) return 'control-wheel';
  if (controlType.includes('手柄') || controlType.includes('手柄')) return 'control-gamepad';
  if (controlType.includes('键盘')) return 'control-keyboard';
  return '';
}

// 获取动力类型图标
function getPowerTypeIcon(powerType) {
  if (!powerType) return '';
  return powerType === '电车' ? '⚡' : '⛽';
}

// 获取起步方式图标
function getStartTypeIcon(startType) {
  if (!startType) return '';
  return startType === '静态起步' ? '🛑' : '🚦';
}

// 渲染表格
function renderTable(data) {
  const tbody = document.querySelector("#lapTable tbody");
  
  if (!tbody) {
    console.error('找不到表格主体元素');
    return;
  }
  
  tbody.innerHTML = "";

  if (data.length === 0) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td colspan="11" style="text-align: center; padding: 40px;">没有找到匹配的记录</td>`;
    tbody.appendChild(tr);
    
    // 更新统计信息为空状态
    document.getElementById('totalRecords').textContent = '0';
    document.getElementById('fastestTime').textContent = '--:--.--';
    document.getElementById('avgPower').textContent = '0';
    return;
  }

  data.forEach((item, index) => {
    const tr = document.createElement("tr");
    
    // 为前三名添加特殊样式
    if (index < 3) {
      tr.className = `rank-${index + 1}`;
    }
    
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

// 更新统计信息
function updateStats(data) {
  const totalRecords = document.getElementById('totalRecords');
  const fastestTime = document.getElementById('fastestTime');
  const avgPower = document.getElementById('avgPower');
  
  if (!totalRecords || !fastestTime || !avgPower) {
    console.warn('统计信息元素未找到');
    return;
  }
  
  totalRecords.textContent = data.length;
  
  // 最快圈速
  if (data.length > 0) {
    const fastest = data.reduce((min, item) => {
      const ms = timeToMs(item.time);
      return ms < min ? ms : min;
    }, Infinity);
    fastestTime.textContent = msToTime(fastest);
    
    // 平均马力
    const validPower = data.filter(item => item.power && !isNaN(item.power)).map(item => parseInt(item.power));
    const avg = validPower.length > 0 
      ? Math.round(validPower.reduce((a, b) => a + b, 0) / validPower.length)
      : 0;
    avgPower.textContent = avg;
  } else {
    fastestTime.textContent = '--:--.--';
    avgPower.textContent = '0';
  }
}

// 填充筛选选项
function populateFilters(data) {
  console.log('开始填充筛选器，数据量:', data.length);
  
  // 获取所有筛选器元素
  const trackSelect = document.getElementById("trackSelect");
  const carSelect = document.getElementById("carSelect");
  const layoutSelect = document.getElementById("layoutSelect");
  
  // 检查元素是否存在
  if (!trackSelect) console.error('找不到 trackSelect 元素');
  if (!carSelect) console.error('找不到 carSelect 元素');
  if (!layoutSelect) console.error('找不到 layoutSelect 元素');
  
  if (!trackSelect || !carSelect || !layoutSelect) {
    console.error('部分筛选器元素未找到，无法填充选项');
    return;
  }
  
  // 从数据中提取唯一值
  const tracks = [...new Set(data.map(item => item.track).filter(Boolean))];
  const cars = [...new Set(data.map(item => item.car).filter(Boolean))];
  const layouts = [...new Set(data.map(item => item.layout).filter(Boolean))];
  
  console.log('提取到的唯一值 - 赛道:', tracks, '车辆:', cars, '布局:', layouts);
  
  // 清空现有选项（保留第一个"全部"选项）
  [trackSelect, carSelect, layoutSelect].forEach(select => {
    while (select.options.length > 1) {
      select.remove(1);
    }
  });
  
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
  
  console.log('筛选器填充完成');
}

// 排序函数
function sortData(data, field, ascending) {
  if (!Array.isArray(data)) {
    console.error('排序函数接收到非数组数据:', data);
    return [];
  }
  
  return [...data].sort((a, b) => {
    let aVal = a[field];
    let bVal = b[field];
    
    // 特殊处理时间字段
    if (field === 'time') {
      aVal = timeToMs(aVal);
      bVal = timeToMs(bVal);
    }
    
    // 处理数值字段
    if (field === 'power' || field === 'rank') {
      aVal = Number(aVal) || 0;
      bVal = Number(bVal) || 0;
    }
    
    // 处理空值
    if (aVal === null || aVal === undefined) aVal = ascending ? Infinity : -Infinity;
    if (bVal === null || bVal === undefined) bVal = ascending ? Infinity : -Infinity;
    
    // 字符串字段
    if (typeof aVal === 'string' && typeof bVal === 'string') {
      return ascending ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
    }
    
    // 数值字段
    if (ascending) {
      return aVal < bVal ? -1 : aVal > bVal ? 1 : 0;
    } else {
      return bVal < aVal ? -1 : bVal > aVal ? 1 : 0;
    }
  });
}

// 应用筛选
function applyFilters() {
  const track = document.getElementById("trackSelect")?.value || "all";
  const car = document.getElementById("carSelect")?.value || "all";
  const drivetrain = document.getElementById("drivetrainSelect")?.value || "all";
  const layout = document.getElementById("layoutSelect")?.value || "all";
  const startType = document.getElementById("startTypeSelect")?.value || "all";
  const powerType = document.getElementById("powerTypeSelect")?.value || "all";
  
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
  
  // 渲染表格
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
  console.log('初始化事件监听器');
  
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
  const filterIds = [
    'trackSelect', 'carSelect', 'drivetrainSelect', 
    'layoutSelect', 'startTypeSelect', 'powerTypeSelect'
  ];
  
  filterIds.forEach(id => {
    const element = document.getElementById(id);
    if (element) {
      element.addEventListener('change', applyFilters);
    } else {
      console.warn(`筛选器元素 ${id} 未找到`);
    }
  });
  
  // 重置按钮
  const resetBtn = document.getElementById("resetFilters");
  if (resetBtn) {
    resetBtn.addEventListener('click', () => {
      document.getElementById("trackSelect").value = "all";
      document.getElementById("carSelect").value = "all";
      document.getElementById("drivetrainSelect").value = "all";
      document.getElementById("layoutSelect").value = "all";
      document.getElementById("startTypeSelect").value = "all";
      document.getElementById("powerTypeSelect").value = "all";
      applyFilters();
    });
  } else {
    console.warn('重置按钮未找到');
  }
  
  console.log('事件监听器初始化完成');
}

// 初始化页面
function initPage() {
  console.log('开始初始化页面');
  
  // 从data.json读取数据
  fetch("data.json")
    .then(res => {
      if (!res.ok) {
        throw new Error(`HTTP错误 ${res.status}: ${res.statusText}`);
      }
      return res.json();
    })
    .then(data => {
      console.log('成功读取数据:', data);
      
      if (!Array.isArray(data)) {
        console.error("数据格式错误：应为数组，但收到:", typeof data);
        throw new Error("数据格式错误：应为数组");
      }
      
      if (data.length === 0) {
        console.warn("数据文件为空");
      }
      
      lapData = data;
      
      // 设置游戏版本和更新时间
      if (data.length > 0) {
        const latest = data.reduce((latest, item) => {
          const latestDate = new Date(latest.date || 0);
          const itemDate = new Date(item.date || 0);
          return itemDate > latestDate ? item : latest;
        }, data[0]);
        
        const gameVersionEl = document.getElementById("gameVersion");
        const updateTimeEl = document.getElementById("updateTime");
        
        if (gameVersionEl) gameVersionEl.textContent = latest.game_version || "0.38.3";
        if (updateTimeEl) updateTimeEl.textContent = latest.date || "2025-12-30";
      }
      
      // 初始排序：按圈速从快到慢
      lapData = sortData(lapData, 'time', true);
      
      // 填充筛选器选项
      populateFilters(lapData);
      
      // 更新排序指示器
      updateSortIndicator();
      
      // 应用初始筛选并渲染
      applyFilters();
      
      // 初始化事件监听
      initEventListeners();
      
      console.log('页面初始化完成');
    })
    .catch(err => {
      console.error("读取数据失败:", err);
      
      // 显示错误信息
      const tbody = document.querySelector("#lapTable tbody");
      if (tbody) {
        tbody.innerHTML = `<tr>
          <td colspan="11" style="text-align: center; padding: 40px; color: #ff6b6b;">
            数据加载失败: ${err.message}<br>
            <small>请检查data.json文件是否存在且格式正确</small>
          </td>
        </tr>`;
      }
      
      // 设置默认统计信息
      document.getElementById('totalRecords').textContent = '0';
      document.getElementById('fastestTime').textContent = '--:--.--';
      document.getElementById('avgPower').textContent = '0';
    });
}

// 页面加载完成后初始化
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initPage);
} else {
  // DOM已经加载完成
  initPage();
}