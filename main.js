// ==================== 全局状态 ====================
let lapData = [];
let isDataLoaded = false;
let currentTrack = 'all';
let trackDataMap = {};

// ==================== DOM元素引用 ====================
const elements = {
  trackTabs: document.getElementById('trackTabs'),
  allTracksContent: document.getElementById('allTracksContent'),
  allTracksTableBody: document.getElementById('allTracksTableBody'),
  trackStatsGrid: document.getElementById('trackStatsGrid'),
  loading: document.getElementById('loading'),
  errorContainer: document.getElementById('errorContainer'),
  searchInput: document.getElementById('searchInput'),
  currentRecords: document.getElementById('currentRecords'),
  fastestTime: document.getElementById('fastestTime'),
  currentTrack: document.getElementById('currentTrack'),
  driverNameStat: document.getElementById('driverNameStat'),
  updateTime: document.getElementById('updateTime'),
  driverName: document.getElementById('driverName')
};

// ==================== 工具函数 ====================

function showLoading() {
  if (elements.loading) {
    elements.loading.classList.add('active');
  }
}

function hideLoading() {
  if (elements.loading) {
    elements.loading.classList.remove('active');
  }
}

function showError(message) {
  if (!elements.errorContainer) return;
  elements.errorContainer.innerHTML = `
    <div class="error-message">
      <strong>⚠️ 错误：</strong> ${message}
    </div>
  `;
  elements.errorContainer.style.display = 'block';
}

function clearError() {
  if (elements.errorContainer) {
    elements.errorContainer.style.display = 'none';
    elements.errorContainer.innerHTML = '';
  }
}

function timeToMs(timeStr) {
  if (!timeStr || timeStr === '--:--.--' || timeStr === '') {
    return Infinity;
  }
  
  try {
    const parts = timeStr.split(/[:.]/);
    if (parts.length >= 2) {
      const minutes = parseInt(parts[0]) || 0;
      const seconds = parseInt(parts[1]) || 0;
      let milliseconds = 0;
      
      if (parts.length >= 3) {
        const msStr = parts[2].padEnd(3, '0').slice(0, 3);
        milliseconds = parseInt(msStr) || 0;
      }
      
      return minutes * 60000 + seconds * 1000 + milliseconds;
    }
    return Infinity;
  } catch (e) {
    return Infinity;
  }
}

function msToTime(ms) {
  if (ms === Infinity || isNaN(ms) || ms === null) {
    return '--:--.--';
  }
  
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  const milliseconds = Math.floor(ms % 1000);
  
  return `${minutes}:${seconds.toString().padStart(2, '0')}.${milliseconds.toString().padStart(3, '0')}`;
}

function getDrivetrainClass(drivetrain) {
  if (!drivetrain) return '';
  if (drivetrain.includes('前驱')) return 'drivetrain-fwd';
  if (drivetrain.includes('后驱')) return 'drivetrain-rwd';
  if (drivetrain.includes('四驱')) return 'drivetrain-awd';
  return '';
}

function getPowerTypeIcon(powerType) {
  return powerType === '电车' ? '⚡' : '⛽';
}

function getStartTypeIcon(startType) {
  return startType === '静态起步' ? '🛑' : '🚦';
}

// ==================== 数据处理 ====================

function loadData() {
  console.log('开始加载数据...');
  showLoading();
  clearError();
  
  fetch('data.json')
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP错误 ${response.status}`);
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
      
      // 处理赛道数据
      processTrackData();
      
      // 设置更新时间
      if (data.length > 0 && elements.updateTime) {
        const latestDate = data.reduce((latest, item) => {
          return item.date > latest ? item.date : latest;
        }, data[0].date);
        elements.updateTime.textContent = latestDate;
      }
      
      hideLoading();
      console.log('数据初始化完成');
    })
    .catch(error => {
      console.error('数据加载失败:', error);
      showError(`数据加载失败: ${error.message}`);
      hideLoading();
    });
}

function processTrackData() {
  // 1. 按赛道分组数据
  trackDataMap = {};
  
  lapData.forEach(item => {
    if (!item.track) return;
    
    if (!trackDataMap[item.track]) {
      trackDataMap[item.track] = [];
    }
    trackDataMap[item.track].push(item);
  });
  
  // 2. 生成赛道标签页
  generateTrackTabs();
  
  // 3. 生成各赛道页面
  generateTrackPages();
  
  // 4. 生成赛道统计卡片
  generateTrackStats();
  
  // 5. 初始化"所有赛道"表格
  renderAllTracksTable();
  
  // 6. 填充筛选器选项
  populateFilters();
  
  // 7. 更新统计信息
  updateCurrentStats();
}

function generateTrackTabs() {
  // 取出“所有赛道”tab（HTML里原本就有）
  const allTab = document.querySelector('.track-tab[data-track="all"]');

  // 清空 tabs 容器
  elements.trackTabs.innerHTML = '';

  // 放回“所有赛道”
  elements.trackTabs.appendChild(allTab);

  // 为每个赛道创建 tab
  Object.keys(trackDataMap).forEach(track => {
    const count = trackDataMap[track].length;

    const tab = document.createElement('div');
    tab.className = 'track-tab';
    tab.dataset.track = track;
    tab.innerHTML = `${track} <span class="track-count">${count}</span>`;

    elements.trackTabs.appendChild(tab);
  });

  // 更新“所有赛道”数量
  const allCount = document.querySelector(
    '.track-tab[data-track="all"] .track-count'
  );
  if (allCount) {
    allCount.textContent = lapData.length;
  }
}

function generateTrackPages() {
  const container = document.querySelector('.container');
  
  Object.keys(trackDataMap).forEach(track => {
    const trackId = track.replace(/\s+/g, '-');
    const data = trackDataMap[track];
    
    // 检查是否已存在
    if (document.getElementById(`${trackId}Content`)) return;
    
    // 收集该赛道的布局
    const layouts = [...new Set(data.map(item => item.layout))].filter(l => l);
    
    // 创建赛道页面
    const content = document.createElement('div');
    content.id = `${trackId}Content`;
    content.className = 'track-content';
    
    content.innerHTML = `
      <div class="track-header">
        <div class="track-name">${track}</div>
        <div class="track-layouts">
          可用布局：${layouts.join(' • ')}
        </div>
        <div style="margin-top: 10px; color: #aaa; font-size: 0.9rem;">
          ${data.length} 条记录 | 最快圈速：${getFastestTime(data)}
        </div>
      </div>
      
      <div class="table-container">
        <table class="track-table">
          <thead>
            <tr>
              <th>排名</th>
              <th>车辆</th>
              <th>布局</th>
              <th>圈速 ⏱</th>
              <th>马力</th>
              <th>驱动</th>
              <th>动力</th>
              <th>起步</th>
              <th>控制</th>
              <th>模组</th>
              <th>日期</th>
            </tr>
          </thead>
          <tbody id="${trackId}TableBody">
            </tbody>
        </table>
      </div>
    `;
    
    // 插入到统计信息之前
    const statsElement = document.querySelector('.stats');
    container.insertBefore(content, statsElement);
    
    // 渲染该赛道的表格
    renderTrackTable(track, data);
  });
}

function generateTrackStats() {
  elements.trackStatsGrid.innerHTML = '';
  
  Object.keys(trackDataMap).forEach(track => {
    const data = trackDataMap[track];
    const fastest = getFastestRecord(data);
    const carCount = new Set(data.map(item => item.car)).size;
    const layouts = new Set(data.map(item => item.layout)).size;
    
    const card = document.createElement('div');
    card.className = 'track-stat-card';
    
    card.innerHTML = `
      <div style="font-weight: bold; color: #40e0d0; margin-bottom: 10px;">${track}</div>
      <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
        <span style="color: #aaa;">记录数：</span>
        <span style="color: white;">${data.length}</span>
      </div>
      <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
        <span style="color: #aaa;">车辆数：</span>
        <span style="color: white;">${carCount}</span>
      </div>
      <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
        <span style="color: #aaa;">布局数：</span>
        <span style="color: white;">${layouts}</span>
      </div>
      <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
        <span style="color: #aaa;">最快圈速：</span>
        <span style="color: #ff8c00; font-weight: bold;">${getFastestTime(data)}</span>
      </div>
      <div style="display: flex; justify-content: space-between;">
        <span style="color: #aaa;">最快车辆：</span>
        <span style="color: #ff8c00; font-size: 0.9rem;">${fastest?.car || '--'}</span>
      </div>
    `;
    
    card.addEventListener('click', () => {
      switchTrack(track);
    });
    
    elements.trackStatsGrid.appendChild(card);
  });
}

function renderAllTracksTable() {
  const tbody = elements.allTracksTableBody;
  if (!tbody) return;
  
  tbody.innerHTML = '';
  
  if (lapData.length === 0) {
    tbody.innerHTML = `
      <tr>
        <td colspan="12" style="text-align: center; padding: 40px;">
          没有找到记录
        </td>
      </tr>
    `;
    return;
  }
  
  // 按时间排序
  const sortedData = [...lapData].sort((a, b) => {
    return timeToMs(a.time) - timeToMs(b.time);
  });
  
  sortedData.forEach((item, index) => {
    const tr = document.createElement('tr');
    
    if (index < 3) {
      tr.className = `rank-${index + 1}`;
    }
    
    const modClass = item.mod === '是' ? 'mod-cell-yes' : 'mod-cell-no';
    const drivetrainClass = getDrivetrainClass(item.drivetrain);
    
    tr.innerHTML = `
      <td><strong>${index + 1}</strong></td>
      <td class="car-cell">${item.car || '未知车辆'}</td>
      <td>${item.track || '未知赛道'}</td>
      <td>${item.layout || '--'}</td>
      <td class="time-cell">${item.time || '--:--.--'}</td>
      <td class="power-cell">${item.power ? item.power + ' hp' : '--'}</td>
      <td class="${drivetrainClass}">${item.drivetrain || '--'}</td>
      <td>${getPowerTypeIcon(item.power_type || '')} ${item.power_type || '--'}</td>
      <td>${getStartTypeIcon(item.start_type || '')} ${item.start_type || '--'}</td>
      <td><span class="control-type">${item.control_type || '--'}</span></td>
      <td class="${modClass}">${item.mod === '是' ? '✅ 是' : '❌ 否'}</td>
      <td>${item.date || '--'}</td>
    `;
    
    tbody.appendChild(tr);
  });
}

function renderTrackTable(track, data) {
  const trackId = track.replace(/\s+/g, '-');
  const tbody = document.getElementById(`${trackId}TableBody`);
  
  if (!tbody) return;
  
  tbody.innerHTML = '';
  
  // 按时间排序
  const sortedData = [...data].sort((a, b) => {
    return timeToMs(a.time) - timeToMs(b.time);
  });
  
  sortedData.forEach((item, index) => {
    const tr = document.createElement('tr');
    
    if (index < 3) {
      tr.className = `rank-${index + 1}`;
    }
    
    const modClass = item.mod === '是' ? 'mod-cell-yes' : 'mod-cell-no';
    const drivetrainClass = getDrivetrainClass(item.drivetrain);
    
    tr.innerHTML = `
      <td><strong>${index + 1}</strong></td>
      <td class="car-cell">${item.car || '未知车辆'}</td>
      <td>${item.layout || '--'}</td>
      <td class="time-cell">${item.time || '--:--.--'}</td>
      <td class="power-cell">${item.power ? item.power + ' hp' : '--'}</td>
      <td class="${drivetrainClass}">${item.drivetrain || '--'}</td>
      <td>${getPowerTypeIcon(item.power_type || '')} ${item.power_type || '--'}</td>
      <td>${getStartTypeIcon(item.start_type || '')} ${item.start_type || '--'}</td>
      <td><span class="control-type">${item.control_type || '--'}</span></td>
      <td class="${modClass}">${item.mod === '是' ? '✅ 是' : '❌ 否'}</td>
      <td>${item.date || '--'}</td>
    `;
    
    tbody.appendChild(tr);
  });
}

function populateFilters() {
  const uniqueValues = {
    tracks: new Set(),
    cars: new Set(),
    layouts: new Set()
  };
  
  lapData.forEach(item => {
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

function getFastestTime(data) {
  if (!data || data.length === 0) return '--:--.--';
  
  const fastest = data.reduce((min, item) => {
    const timeMs = timeToMs(item.time);
    return timeMs < min.timeMs ? { time: item.time, timeMs } : min;
  }, { time: null, timeMs: Infinity });
  
  return fastest.time || '--:--.--';
}

function getFastestRecord(data) {
  if (!data || data.length === 0) return null;
  
  return data.reduce((min, item) => {
    const timeMs = timeToMs(item.time);
    return timeMs < min.timeMs ? { ...item, timeMs } : min;
  }, { timeMs: Infinity });
}

// ==================== 页面切换 ====================

function switchTrack(track) {
  // 更新活动标签
  document.querySelectorAll('.track-tab').forEach(tab => {
    tab.classList.remove('active');
  });
  const activeTab = document.querySelector(`.track-tab[data-track="${track}"]`);
  if (activeTab) {
      activeTab.classList.add('active');
  }
  
  // 更新活动内容
  document.querySelectorAll('.track-content').forEach(content => {
    content.classList.remove('active');
  });
  
  const contentId = track === 'all' ? 'allTracksContent' : `${track.replace(/\s+/g, '-')}Content`;
  const contentEl = document.getElementById(contentId);
  if (contentEl) {
      contentEl.classList.add('active');
  }
  
  // 更新当前赛道状态
  currentTrack = track;
  if (elements.currentTrack) {
      elements.currentTrack.textContent = track === 'all' ? '所有赛道' : track;
  }
  
  // 更新统计信息
  updateCurrentStats();
}

function updateCurrentStats() {
  let currentData;
  
  if (currentTrack === 'all') {
    currentData = lapData;
  } else {
    currentData = trackDataMap[currentTrack] || [];
  }
  
  elements.currentRecords.textContent = currentData.length;
  
  // 计算最快圈速
  if (currentData.length > 0) {
    const fastest = currentData.reduce((min, item) => {
      const ms = timeToMs(item.time);
      return ms < min ? ms : min;
    }, Infinity);
    
    elements.fastestTime.textContent = msToTime(fastest);
  } else {
    elements.fastestTime.textContent = '--:--.--';
  }
}

// ==================== 初始化 ====================

function initApp() {
  console.log('初始化多赛道应用...');
  loadData();
}

// 页面加载完成后初始化
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initApp);
} else {
  initApp();
}

if (elements.trackTabs) {
  elements.trackTabs.addEventListener('click', e => {
    // 找到最近的 track-tab（防止点到 span）
    const tab = e.target.closest('.track-tab');
    if (!tab) return;
  
    const track = tab.dataset.track;
    if (!track) return;
  
    switchTrack(track);
  });
}