/**
 * BeamNG圈速排行榜 - 优化版本
 * 实现了所有老师建议的改进
 */

// 全局状态
let lapData = [];
let currentSort = { field: 'time', ascending: true };
let isDataLoaded = false;

// DOM元素引用
const elements = {
  loading: document.getElementById('loading'),
  errorContainer: document.getElementById('errorContainer'),
  searchInput: document.getElementById('searchInput'),
  tableBody: document.querySelector('#lapTable tbody'),
  totalRecords: document.getElementById('totalRecords'),
  fastestTime: document.getElementById('fastestTime'),
  avgPower: document.getElementById('avgPower'),
  searchMatches: document.getElementById('searchMatches'),
  updateTime: document.getElementById('updateTime')
};

// 筛选器元素
const filterElements = [
  'trackSelect', 'carSelect', 'drivetrainSelect',
  'layoutSelect', 'startTypeSelect', 'powerTypeSelect', 'modSelect' // 新增modSelect
];

// ==================== 工具函数 ====================

/**
 * 显示加载状态
 */
function showLoading() {
  if (elements.loading) {
    elements.loading.classList.add('active');
  }
}

/**
 * 隐藏加载状态
 */
function hideLoading() {
  if (elements.loading) {
    elements.loading.classList.remove('active');
  }
}

/**
 * 显示错误信息
 * @param {string} message - 错误信息
 * @param {boolean} isCors - 是否为CORS错误
 */
function showError(message, isCors = false) {
  if (!elements.errorContainer) return;
  
  let errorMessage = message;
  if (isCors) {
    errorMessage += '<br><small>请使用本地服务器运行（如VSCode Live Server）</small>';
  }
  
  elements.errorContainer.innerHTML = `
    <div class="error-message">
      <strong>⚠️ 错误：</strong> ${errorMessage}
    </div>
  `;
  elements.errorContainer.style.display = 'block';
}

/**
 * 清除错误信息
 */
function clearError() {
  if (elements.errorContainer) {
    elements.errorContainer.style.display = 'none';
    elements.errorContainer.innerHTML = '';
  }
}

/**
 * 时间字符串转毫秒（优化空值处理）
 * @param {string} timeStr - 时间字符串 (格式: "1:23.456")
 * @returns {number} 毫秒数，无效值返回 Infinity（升序时排在最后）
 */
function timeToMs(timeStr) {
  if (!timeStr || timeStr === '--:--.--' || timeStr === '') {
    return Infinity; // 空值在升序时排在最后
  }
  
  try {
    // 支持多种时间格式：1:23.456, 1:23.45, 1:23
    const parts = timeStr.split(/[:.]/);
    
    if (parts.length >= 2) {
      const minutes = parseInt(parts[0]) || 0;
      const seconds = parseInt(parts[1]) || 0;
      
      // 处理毫秒部分
      let milliseconds = 0;
      if (parts.length >= 3) {
        // 确保毫秒部分为3位数
        const msStr = parts[2].padEnd(3, '0').slice(0, 3);
        milliseconds = parseInt(msStr) || 0;
      }
      
      return minutes * 60000 + seconds * 1000 + milliseconds;
    }
    
    return Infinity;
  } catch (e) {
    console.warn(`无法解析时间格式: ${timeStr}`, e);
    return Infinity;
  }
}

/**
 * 毫秒转时间字符串
 * @param {number} ms - 毫秒数
 * @returns {string} 格式化时间
 */
function msToTime(ms) {
  if (ms === Infinity || isNaN(ms) || ms === null) {
    return '--:--.--';
  }
  
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  const milliseconds = Math.floor(ms % 1000);
  
  return `${minutes}:${seconds.toString().padStart(2, '0')}.${milliseconds.toString().padStart(3, '0')}`;
}

/**
 * 智能时间比较函数（空值始终在最后）
 * @param {string} a - 时间A
 * @param {string} b - 时间B
 * @param {boolean} ascending - 是否升序
 * @returns {number} 比较结果
 */
function compareTimes(a, b, ascending) {
  const aMs = timeToMs(a);
  const bMs = timeToMs(b);
  
  // 处理空值：始终放在最后
  const aIsEmpty = aMs === Infinity;
  const bIsEmpty = bMs === Infinity;
  
  if (aIsEmpty && bIsEmpty) return 0;
  if (aIsEmpty) return 1;  // a空，排后面
  if (bIsEmpty) return -1; // b空，排后面
  
  // 正常比较
  return ascending ? aMs - bMs : bMs - aMs;
}

/**
 * 获取驱动方式对应的CSS类
 */
function getDrivetrainClass(drivetrain) {
  if (!drivetrain) return '';
  if (drivetrain.includes('前驱')) return 'drivetrain-fwd';
  if (drivetrain.includes('后驱')) return 'drivetrain-rwd';
  if (drivetrain.includes('四驱')) return 'drivetrain-awd';
  return '';
}

/**
 * 获取动力类型图标
 */
function getPowerTypeIcon(powerType) {
  return powerType === '电车' ? '⚡' : '⛽';
}

/**
 * 获取起步方式图标
 */
function getStartTypeIcon(startType) {
  return startType === '静态起步' ? '🛑' : '🚦';
}

// ==================== 数据处理函数 ====================

/**
 * 填充筛选器选项
 */
function populateFilters(data) {
  const uniqueValues = {
    tracks: new Set(),
    cars: new Set(),
    layouts: new Set()
  };
  
  // 收集唯一值
  data.forEach(item => {
    if (item.track) uniqueValues.tracks.add(item.track);
    if (item.car) uniqueValues.cars.add(item.car);
    if (item.layout) uniqueValues.layouts.add(item.layout);
  });
  
  // 填充赛道选项
  const trackSelect = document.getElementById('trackSelect');
  if (trackSelect) {
    [...uniqueValues.tracks].sort().forEach(track => {
      const option = document.createElement('option');
      option.value = track;
      option.textContent = track;
      trackSelect.appendChild(option);
    });
  }
  
  // 填充车辆选项
  const carSelect = document.getElementById('carSelect');
  if (carSelect) {
    [...uniqueValues.cars].sort().forEach(car => {
      const option = document.createElement('option');
      option.value = car;
      option.textContent = car;
      carSelect.appendChild(option);
    });
  }
  
  // 填充布局选项
  const layoutSelect = document.getElementById('layoutSelect');
  if (layoutSelect) {
    [...uniqueValues.layouts].sort().forEach(layout => {
      const option = document.createElement('option');
      option.value = layout;
      option.textContent = layout;
      layoutSelect.appendChild(option);
    });
  }
}

/**
 * 排序数据
 */
function sortData(data, field, ascending) {
  if (!Array.isArray(data) || data.length === 0) {
    return data;
  }
  
  return [...data].sort((a, b) => {
    // 特殊处理时间字段
    if (field === 'time') {
      return compareTimes(a.time, b.time, ascending);
    }
    
    let aVal = a[field];
    let bVal = b[field];
    
    // 处理数值字段
    if (field === 'power' || field === 'rank') {
      aVal = Number(aVal) || 0;
      bVal = Number(bVal) || 0;
      return ascending ? aVal - bVal : bVal - aVal;
    }
    
    // 处理空值
    if (aVal == null) aVal = '';
    if (bVal == null) bVal = '';
    
    // 字符串比较
    if (ascending) {
      return String(aVal).localeCompare(String(bVal));
    } else {
      return String(bVal).localeCompare(String(aVal));
    }
  });
}

/**
 * 应用筛选和搜索
 */
function applyFilters() {
  if (!isDataLoaded || lapData.length === 0) {
    return;
  }
  
  // 获取筛选器值
  const filters = {
    track: document.getElementById('trackSelect')?.value || 'all',
    car: document.getElementById('carSelect')?.value || 'all',
    drivetrain: document.getElementById('drivetrainSelect')?.value || 'all',
    layout: document.getElementById('layoutSelect')?.value || 'all',
    startType: document.getElementById('startTypeSelect')?.value || 'all',
    powerType: document.getElementById('powerTypeSelect')?.value || 'all',
    mod: document.getElementById('modSelect')?.value || 'all', // 新增模组筛选
    search: (elements.searchInput?.value || '').toLowerCase().trim()
  };
  
  // 应用筛选
  let filtered = lapData.filter(item => {
    // 赛道筛选
    if (filters.track !== 'all' && item.track !== filters.track) {
      return false;
    }
    
    // 车辆筛选
    if (filters.car !== 'all' && item.car !== filters.car) {
      return false;
    }
    
    // 驱动方式筛选
    if (filters.drivetrain !== 'all' && item.drivetrain !== filters.drivetrain) {
      return false;
    }
    
    // 布局筛选
    if (filters.layout !== 'all' && item.layout !== filters.layout) {
      return false;
    }
    
    // 起步方式筛选
    if (filters.startType !== 'all' && item.start_type !== filters.startType) {
      return false;
    }
    
    // 动力类型筛选
    if (filters.powerType !== 'all' && item.power_type !== filters.powerType) {
      return false;
    }
    
    // 模组筛选 - 新增
    if (filters.mod !== 'all' && item.mod !== filters.mod) {
      return false;
    }
    
    // 搜索筛选（模糊搜索车辆和赛道）
    if (filters.search) {
      const carMatch = item.car && item.car.toLowerCase().includes(filters.search);
      const trackMatch = item.track && item.track.toLowerCase().includes(filters.search);
      return carMatch || trackMatch;
    }
    
    return true;
  });
  
  // 应用排序
  filtered = sortData(filtered, currentSort.field, currentSort.ascending);
  
  // 渲染表格
  renderTable(filtered);
  
  // 更新统计信息
  updateStats(filtered);
}

/**
 * 渲染表格
 */
function renderTable(data) {
  if (!elements.tableBody) return;
  
  elements.tableBody.innerHTML = '';
  
  if (data.length === 0) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td colspan="12" style="text-align: center; padding: 40px;">
        没有找到匹配的记录
      </td>
    `;
    elements.tableBody.appendChild(tr);
    return;
  }
  
  data.forEach((item, index) => {
    const tr = document.createElement('tr');
    
    // 为前三名添加特殊样式
    if (index < 3) {
      tr.className = `rank-${index + 1}`;
    }
    
    // 根据模组状态添加CSS类
    const modClass = item.mod === '是' ? 'mod-cell-yes' : 'mod-cell-no';
    
    tr.innerHTML = `
      <td><strong>${index + 1}</strong></td>
      <td class="car-cell">${item.car || '未知车辆'}</td>
      <td>${item.track || '未知赛道'}</td>
      <td>${item.layout || '--'}</td>
      <td class="time-cell">${item.time || '--:--.--'}</td>
      <td class="power-cell">${item.power ? item.power + ' hp' : '--'}</td>
      <td class="${getDrivetrainClass(item.drivetrain)}">${item.drivetrain || '--'}</td>
      <td>${getPowerTypeIcon(item.power_type || '')} ${item.power_type || '--'}</td>
      <td>${getStartTypeIcon(item.start_type || '')} ${item.start_type || '--'}</td>
      <td><span class="control-type">${item.control_type || '--'}</span></td>
      <td class="${modClass}">${item.mod === '是' ? '✅ 是' : '❌ 否'}</td> <!-- 新增模组列 -->
      <td>${item.date || '--'}</td>
    `;
    
    // 添加行高亮交互
    tr.addEventListener('mouseenter', () => {
      tr.classList.add('highlight');
    });
    
    tr.addEventListener('mouseleave', () => {
      tr.classList.remove('highlight');
    });
    
    elements.tableBody.appendChild(tr);
  });
}

/**
 * 更新统计信息
 */
function updateStats(data) {
  if (!elements.totalRecords || !elements.fastestTime || 
      !elements.avgPower || !elements.searchMatches) return;
  
  elements.totalRecords.textContent = data.length;
  elements.searchMatches.textContent = data.length;
  
  if (data.length > 0) {
    // 计算最快圈速
    const fastest = data.reduce((min, item) => {
      const ms = timeToMs(item.time);
      return ms < min ? ms : min;
    }, Infinity);
    
    elements.fastestTime.textContent = msToTime(fastest);
    
    // 计算平均马力
    const validPower = data
      .filter(item => item.power && !isNaN(item.power))
      .map(item => Number(item.power));
    
    if (validPower.length > 0) {
      const avg = Math.round(validPower.reduce((a, b) => a + b, 0) / validPower.length);
      elements.avgPower.textContent = avg;
    } else {
      elements.avgPower.textContent = '0';
    }
  } else {
    elements.fastestTime.textContent = '--:--.--';
    elements.avgPower.textContent = '0';
  }
}

/**
 * 更新排序指示器
 */
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

// ==================== 事件处理 ====================

/**
 * 初始化事件监听（提前初始化）
 */
function initEventListeners() {
  console.log('初始化事件监听器...');
  
  // 表头点击排序
  document.querySelectorAll('.sortable').forEach(header => {
    header.addEventListener('click', () => {
      if (!isDataLoaded) {
        console.log('数据尚未加载，请稍候...');
        return;
      }
      
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
  
  // 筛选器变化事件
  filterElements.forEach(id => {
    const element = document.getElementById(id);
    if (element) {
      element.addEventListener('change', applyFilters);
    }
  });
  
  // 搜索框输入事件（防抖处理）
  if (elements.searchInput) {
    let searchTimeout;
    elements.searchInput.addEventListener('input', () => {
      clearTimeout(searchTimeout);
      searchTimeout = setTimeout(applyFilters, 300); // 300ms防抖
    });
  }
  
  // 重置按钮
  const resetBtn = document.getElementById('resetFilters');
  if (resetBtn) {
    resetBtn.addEventListener('click', () => {
      // 重置所有筛选器
      filterElements.forEach(id => {
        const element = document.getElementById(id);
        if (element) element.value = 'all';
      });
      
      // 清空搜索框
      if (elements.searchInput) {
        elements.searchInput.value = '';
      }
      
      // 重新应用筛选
      applyFilters();
    });
  }
  
  console.log('事件监听器初始化完成');
}

/**
 * 加载数据
 */
function loadData() {
  console.log('开始加载数据...');
  showLoading();
  clearError();
  
  fetch('data.json')
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP错误 ${response.status}: ${response.statusText}`);
      }
      return response.json();
    })
    .then(data => {
      console.log('数据加载成功，记录数:', data.length);
      
      if (!Array.isArray(data)) {
        throw new Error('数据格式错误：应为数组');
      }
      
      lapData = data;
      isDataLoaded = true;
      
      // 设置更新时间
      if (data.length > 0 && elements.updateTime) {
        const latestDate = data.reduce((latest, item) => {
          const itemDate = new Date(item.date || 0);
          const latestDate = new Date(latest.date || 0);
          return itemDate > latestDate ? item : latest;
        }, data[0]).date;
        
        elements.updateTime.textContent = latestDate || '--';
      }
      
      // 初始排序：按圈速从快到慢
      lapData = sortData(lapData, 'time', true);
      
      // 填充筛选器选项
      populateFilters(lapData);
      
      // 更新排序指示器
      updateSortIndicator();
      
      // 应用初始筛选并渲染
      applyFilters();
      
      hideLoading();
      console.log('数据初始化完成');
    })
    .catch(error => {
      console.error('数据加载失败:', error);
      
      // 检查是否为CORS错误
      const isCorsError = error.message.includes('Failed to fetch') || 
                         error.message.includes('NetworkError') ||
                         window.location.protocol === 'file:';
      
      showError(
        `数据加载失败: ${error.message}`,
        isCorsError
      );
      
      // 如果数据未加载，显示空表格
      renderTable([]);
      hideLoading();
    });
}

// ==================== 初始化 ====================

/**
 * 初始化应用
 */
function initApp() {
  console.log('初始化应用...');
  
  // 立即初始化事件监听（提前初始化）
  initEventListeners();
  
  // 加载数据
  loadData();
}

// 页面加载完成后初始化
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initApp);
} else {
  // DOM已经加载完成
  initApp();
}