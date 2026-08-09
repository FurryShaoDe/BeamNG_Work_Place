// ==================== 全局状态 ====================
const state = {
  lapData: [],            // 原始数据
  trackDataMap: {},       // 按赛道分组的数据
  currentTrack: 'all',    // 当前选中的赛道
  isDataLoaded: false,
  // 排序状态
  sort: {
    column: 'time',       // 默认按圈速排序
    direction: 'asc',     // 升序（圈速越小越快）
  },
  // 筛选状态
  filters: {
    track: 'all',
    car: 'all',
    drivetrain: 'all',
    layout: 'all',
    powerType: 'all',
    mod: 'all',
    version: 'all',
    search: '',
  },
};

// ==================== DOM 元素引用 ====================
const el = {
  trackTabs: document.getElementById('trackTabs'),
  allTracksContent: document.getElementById('allTracksContent'),
  allTracksTableBody: document.getElementById('allTracksTableBody'),
  allTracksTable: document.getElementById('allTracksTable'),
  trackStatsGrid: document.getElementById('trackStatsGrid'),
  loading: document.getElementById('loading'),
  errorContainer: document.getElementById('errorContainer'),
  searchInput: document.getElementById('searchInput'),
  currentRecords: document.getElementById('currentRecords'),
  updateTime: document.getElementById('updateTime'),
  // 筛选器
  trackSelect: document.getElementById('trackSelect'),
  carSelect: document.getElementById('carSelect'),
  drivetrainSelect: document.getElementById('drivetrainSelect'),
  layoutSelect: document.getElementById('layoutSelect'),
  powerTypeSelect: document.getElementById('powerTypeSelect'),
  modSelect: document.getElementById('modSelect'),
  versionSelect: document.getElementById('versionSelect'),
  resetFilters: document.getElementById('resetFilters'),
};

// ==================== 工具函数 ====================

function showLoading() {
  el.loading && el.loading.classList.add('active');
}

function hideLoading() {
  el.loading && el.loading.classList.remove('active');
}

function showError(message) {
  if (!el.errorContainer) {
    return;
  }
  el.errorContainer.innerHTML = `
    <div class="error-message">
      <strong>错误：</strong> ${message}
    </div>
  `;
  el.errorContainer.style.display = 'block';
}

function clearError() {
  if (!el.errorContainer) {
    return;
  }
  el.errorContainer.style.display = 'none';
  el.errorContainer.innerHTML = '';
}

/**
 * 将时间字符串 "MM:SS.mmm" 转换为毫秒数
 */
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

/**
 * 将日期字符串 "YYYY-M-D" 转换为可比较的数字（如 20260102），
 * 避免字符串比较导致 "2026-1-11" 排在 "2026-1-2" 前面的错误。
 */
function dateToSortKey(dateStr) {
  if (!dateStr) {
    return 0;
  }
  const parts = String(dateStr).split('-').map(p => parseInt(p, 10) || 0);
  return (parts[0] || 0) * 10000 + (parts[1] || 0) * 100 + (parts[2] || 0);
}

function getDrivetrainClass(drivetrain) {
  if (!drivetrain) {
    return '';
  }
  if (drivetrain.includes('前驱')) {
    return 'drivetrain-fwd';
  }
  if (drivetrain.includes('后驱')) {
    return 'drivetrain-rwd';
  }
  if (drivetrain.includes('四驱')) {
    return 'drivetrain-awd';
  }
  return '';
}

function getPowerTypeIcon(powerType) {
  return powerType === '电车' ? '⚡' : '⛽';
}

function escapeHtml(str) {
  if (str == null) {
    return '';
  }
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * 防抖函数
 */
function debounce(fn, delay = 200) {
  let timer = null;
  return function (...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn.apply(this, args), delay);
  };
}

// ==================== 数据加载 ====================

function loadData() {
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
      if (!Array.isArray(data)) {
        throw new Error('数据格式错误：应为数组');
      }

      state.lapData = data;
      state.isDataLoaded = true;

      processTrackData();

      // 设置更新时间为最新日期
      if (data.length > 0 && el.updateTime) {
        const latestDate = data.reduce((latest, item) => {
          return dateToSortKey(item.date) > dateToSortKey(latest) ? item.date : latest;
        }, data[0].date);
        el.updateTime.textContent = latestDate;
      }

      hideLoading();
    })
    .catch(error => {
      console.error('数据加载失败:', error);
      showError(`数据加载失败: ${error.message}`);
      hideLoading();
    });
}

// ==================== 数据处理 ====================

/**
 * 计算每条记录在「所属赛道内」的排名（按圈速），写入 item.trackRank。
 * 综合排行榜据此展示赛道内排名，避免把不同赛道的绝对圈速混在一起无意义比较。
 */
function computeTrackRanks() {
  const byTrack = {};
  state.lapData.forEach(item => {
    if (!item.track) {
      return;
    }
    (byTrack[item.track] = byTrack[item.track] || []).push(item);
  });
  Object.keys(byTrack).forEach(track => {
    const sorted = [...byTrack[track]].sort((a, b) => timeToMs(a.time) - timeToMs(b.time));
    sorted.forEach((item, i) => { item.trackRank = i + 1; });
  });
}

function processTrackData() {
  // 0. 计算每条记录的赛道内排名
  computeTrackRanks();

  // 1. 按赛道分组
  state.trackDataMap = {};
  state.lapData.forEach(item => {
    if (!item.track) {
      return;
    }
    if (!state.trackDataMap[item.track]) {
      state.trackDataMap[item.track] = [];
    }
    state.trackDataMap[item.track].push(item);
  });

  // 2. 生成赛道标签页
  generateTrackTabs();

  // 3. 生成各赛道页面
  generateTrackPages();

  // 4. 生成赛道统计卡片
  generateTrackStats();

  // 5. 填充筛选器选项
  populateFilters();

  // 6. 渲染"所有赛道"表格
  renderAllTracksTable();

  // 7. 更新统计信息
  updateCurrentStats();
}

function generateTrackTabs() {
  if (!el.trackTabs) {
    return;
  }
  const allTab = document.querySelector('.track-tab[data-track="all"]');
  el.trackTabs.innerHTML = '';
  el.trackTabs.appendChild(allTab);

  Object.keys(state.trackDataMap).forEach(track => {
    const count = state.trackDataMap[track].length;
    const tab = document.createElement('div');
    tab.className = 'track-tab';
    tab.dataset.track = track;
    tab.innerHTML = `${escapeHtml(track)} <span class="track-count">${count}</span>`;
    el.trackTabs.appendChild(tab);
  });

  const allCount = document.querySelector('.track-tab[data-track="all"] .track-count');
  if (allCount) {
    allCount.textContent = state.lapData.length;
  }
}

function generateTrackPages() {
  const container = document.querySelector('.container');
  const statsElement = document.querySelector('.stats');
  if (!container || !statsElement) {
    return;
  }

  Object.keys(state.trackDataMap).forEach(track => {
    const trackId = getTrackId(track);
    const data = state.trackDataMap[track];

    if (document.getElementById(`${trackId}Content`)) {
      return;
    }

    const layouts = [...new Set(data.map(item => item.layout))].filter(l => l);

    const content = document.createElement('div');
    content.id = `${trackId}Content`;
    content.className = 'track-content';

    content.innerHTML = `
      <div class="track-header">
        <div class="track-name">${escapeHtml(track)}</div>
        <div class="track-layouts">可用布局：${escapeHtml(layouts.join(' • ')) || '--'}</div>
        <div class="track-meta">
          <strong>${data.length}</strong> 条记录 · 最快圈速：<strong>${escapeHtml(getFastestTime(data))}</strong>
        </div>
      </div>
      <div class="table-container">
        <table class="track-table">
          <thead>
            <tr>
              <th>排名</th>
              <th>车辆</th>
              <th>布局</th>
              <th>圈速</th>
              <th>马力</th>
              <th>驱动</th>
              <th>动力</th>
              <th>控制</th>
              <th>模组</th>
              <th>日期</th>
            </tr>
          </thead>
          <tbody id="${trackId}TableBody"></tbody>
        </table>
      </div>
    `;

    container.insertBefore(content, statsElement);
    renderTrackTable(track, data);
  });
}

function generateTrackStats() {
  if (!el.trackStatsGrid) {
    return;
  }
  el.trackStatsGrid.innerHTML = '';

  Object.keys(state.trackDataMap).forEach(track => {
    const data = state.trackDataMap[track];
    const fastest = getFastestRecord(data);
    const fastestCarTitle = escapeHtml(fastest?.car || '');
    const fastestCarText = escapeHtml(fastest?.car || '--');
    const carCount = new Set(data.map(item => item.car)).size;
    const layouts = new Set(data.map(item => item.layout)).size;

    const card = document.createElement('div');
    card.className = 'track-stat-card';
    card.innerHTML = `
      <div class="card-title">${escapeHtml(track)}</div>
      <div class="card-row">
        <span class="label">记录数</span>
        <span class="value">${data.length}</span>
      </div>
      <div class="card-row">
        <span class="label">车辆数</span>
        <span class="value">${carCount}</span>
      </div>
      <div class="card-row">
        <span class="label">布局数</span>
        <span class="value">${layouts}</span>
      </div>
      <div class="card-row">
        <span class="label">最快圈速</span>
        <span class="value highlight">${escapeHtml(getFastestTime(data))}</span>
      </div>
      <div class="card-row">
        <span class="label">最快车辆</span>
        <span class="value car-name" title="${fastestCarTitle}">${fastestCarText}</span>
      </div>
    `;

    card.addEventListener('click', () => switchTrack(track));
    el.trackStatsGrid.appendChild(card);
  });
}

// ==================== 渲染逻辑 ====================

/**
 * 生成单行 HTML
 */
function renderRow(item, index, showTrack = false) {
  // 综合榜（跨赛道）展示「赛道内排名」；单赛道榜展示当前顺序名次。
  // 这样综合榜不再把不同赛道的绝对圈速混在一起无意义比较。
  const displayRank = showTrack ? (item.trackRank || index + 1) : (index + 1);
  const rankClass = displayRank <= 3 ? `rank-${displayRank}` : '';
  const modClass = item.mod === '是' ? 'mod-cell-yes' : 'mod-cell-no';
  const drivetrainClass = getDrivetrainClass(item.drivetrain);
  const powerTypeClass = item.power_type === '电车' ? 'electric' : 'gas';
  const powerTypeIcon = getPowerTypeIcon(item.power_type || '');
  const powerTypeText = escapeHtml(item.power_type || '--');
  const modText = item.mod === '是' ? '是' : '否';

  const trackCell = showTrack
    ? `<td>${escapeHtml(item.track || '未知赛道')}</td>`
    : '';

  return `
    <tr class="${rankClass}">
      <td><span class="rank-badge">${displayRank}</span></td>
      <td class="car-cell" title="${escapeHtml(item.car || '')}">${escapeHtml(item.car || '未知车辆')}</td>
      ${trackCell}
      <td>${escapeHtml(item.layout || '--')}</td>
      <td class="time-cell">${escapeHtml(item.time || '--:--.--')}</td>
      <td class="power-cell">${item.power ? item.power + ' hp' : '--'}</td>
      <td class="${drivetrainClass}">${escapeHtml(item.drivetrain || '--')}</td>
      <td><span class="power-type-cell ${powerTypeClass}">${powerTypeIcon} ${powerTypeText}</span></td>
      <td><span class="control-type">${escapeHtml(item.control_type || '--')}</span></td>
      <td class="${modClass}">${modText}</td>
      <td>${escapeHtml(item.date || '--')}</td>
    </tr>
  `;
}

/**
 * 渲染空状态
 */
function renderEmptyState(tbody, colspan, message = '没有找到匹配的记录', desc = '尝试调整筛选条件或重置筛选') {
  tbody.innerHTML = `
    <tr>
      <td colspan="${colspan}">
        <div class="empty-state">
          <div class="empty-icon">🔍</div>
          <div class="empty-title">${escapeHtml(message)}</div>
          <div class="empty-desc">${escapeHtml(desc)}</div>
        </div>
      </td>
    </tr>
  `;
}

/**
 * 应用筛选条件到数据
 */
function applyFilters(data) {
  const f = state.filters;
  return data.filter(item => {
    if (f.track !== 'all' && item.track !== f.track) {
      return false;
    }
    if (f.car !== 'all' && item.car !== f.car) {
      return false;
    }
    if (f.drivetrain !== 'all' && item.drivetrain !== f.drivetrain) {
      return false;
    }
    if (f.layout !== 'all' && item.layout !== f.layout) {
      return false;
    }
    if (f.powerType !== 'all' && item.power_type !== f.powerType) {
      return false;
    }
    if (f.mod !== 'all' && item.mod !== f.mod) {
      return false;
    }
    if (f.version !== 'all' && item.game_version !== f.version) {
      return false;
    }
    if (f.search) {
      const q = f.search.toLowerCase();
      const haystack = `${item.car || ''} ${item.track || ''} ${item.layout || ''}`.toLowerCase();
      if (!haystack.includes(q)) {
        return false;
      }
    }
    return true;
  });
}

/**
 * 应用排序到数据
 */
function applySort(data) {
  const { column, direction } = state.sort;
  // "排名"列本质是按圈速排序（排名即快慢次序）
  const sortColumn = column === 'rank' ? 'time' : column;
  const sorted = [...data];
  const dir = direction === 'asc' ? 1 : -1;

  sorted.sort((a, b) => {
    let va = a[sortColumn];
    let vb = b[sortColumn];

    // 圈速特殊处理：按毫秒数排序
    if (sortColumn === 'time') {
      return (timeToMs(va) - timeToMs(vb)) * dir;
    }
    // 马力按数值排序
    if (sortColumn === 'power') {
      return ((va || 0) - (vb || 0)) * dir;
    }
    // 日期按数值排序（YYYY-M-D 需转为可比较数字，避免字符串比较出错）
    if (sortColumn === 'date') {
      return (dateToSortKey(va) - dateToSortKey(vb)) * dir;
    }
    // 默认字符串比较
    va = (va || '').toString();
    vb = (vb || '').toString();
    return va < vb ? -1 * dir : va > vb ? 1 * dir : 0;
  });

  return sorted;
}

/**
 * 渲染"所有赛道"表格（应用筛选 + 排序）
 */
function renderAllTracksTable() {
  const tbody = el.allTracksTableBody;
  if (!tbody) {
    return;
  }

  // 应用筛选
  let data = applyFilters(state.lapData);

  // 应用排序
  data = applySort(data);

  if (data.length === 0) {
    renderEmptyState(tbody, 11);
    updateCurrentStats(data.length);
    return;
  }

  tbody.innerHTML = data
    .map((item, index) => renderRow(item, index, true))
    .join('');

  updateCurrentStats(data.length);
}

/**
 * 渲染单个赛道表格（按圈速排序）
 */
function renderTrackTable(track, data) {
  const trackId = getTrackId(track);
  const tbody = document.getElementById(`${trackId}TableBody`);
  if (!tbody) {
    return;
  }

  const sortedData = [...data].sort((a, b) => timeToMs(a.time) - timeToMs(b.time));

  if (sortedData.length === 0) {
    renderEmptyState(tbody, 10);
    return;
  }

  tbody.innerHTML = sortedData
    .map((item, index) => renderRow(item, index, false))
    .join('');
}

/**
 * 更新排序指示器
 */
function updateSortIndicators() {
  if (!el.allTracksTable) {
    return;
  }
  const ths = el.allTracksTable.querySelectorAll('th[data-sort]');
  ths.forEach(th => {
    th.classList.remove('sort-asc', 'sort-desc');
    if (th.dataset.sort === state.sort.column) {
      th.classList.add(state.sort.direction === 'asc' ? 'sort-asc' : 'sort-desc');
    }
  });
}

// ==================== 筛选器填充 ====================

function populateFilters() {
  const unique = { tracks: new Set(), cars: new Set(), layouts: new Set(), versions: new Set() };

  state.lapData.forEach(item => {
    if (item.track) {
      unique.tracks.add(item.track);
    }
    if (item.car) {
      unique.cars.add(item.car);
    }
    if (item.layout) {
      unique.layouts.add(item.layout);
    }
    if (item.game_version) {
      unique.versions.add(item.game_version);
    }
  });

  fillSelect(el.trackSelect, [...unique.tracks].sort());
  fillSelect(el.carSelect, [...unique.cars].sort());
  fillSelect(el.layoutSelect, [...unique.layouts].sort());
  fillSelect(el.versionSelect, [...unique.versions].sort());
}

function fillSelect(select, values) {
  if (!select) {
    return;
  }
  // 保留第一个 option（"全部"）
  const firstOption = select.querySelector('option');
  select.innerHTML = '';
  if (firstOption) {
    select.appendChild(firstOption);
  }

  values.forEach(value => {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = value;
    select.appendChild(option);
  });
}

// ==================== 工具：获取最快圈速 ====================

function getFastestTime(data) {
  if (!data || data.length === 0) {
    return '--:--.--';
  }
  const fastest = data.reduce((min, item) => {
    const timeMs = timeToMs(item.time);
    return timeMs < min.timeMs ? { time: item.time, timeMs } : min;
  }, { time: null, timeMs: Infinity });
  return fastest.time || '--:--.--';
}

function getFastestRecord(data) {
  if (!data || data.length === 0) {
    return null;
  }
  return data.reduce((min, item) => {
    const timeMs = timeToMs(item.time);
    return timeMs < min.timeMs ? { ...item, timeMs } : min;
  }, { timeMs: Infinity });
}

function getTrackId(track) {
  return track.replace(/\s+/g, '-');
}

// ==================== 页面切换 ====================

function switchTrack(track) {
  document.querySelectorAll('.track-tab').forEach(tab => {
    tab.classList.remove('active');
  });
  const activeTab = document.querySelector(`.track-tab[data-track="${CSS.escape(track)}"]`);
  if (activeTab) {
    activeTab.classList.add('active');
  }

  document.querySelectorAll('.track-content').forEach(content => {
    content.classList.remove('active');
  });

  const contentId = track === 'all' ? 'allTracksContent' : `${getTrackId(track)}Content`;
  const contentEl = document.getElementById(contentId);
  if (contentEl) {
    contentEl.classList.add('active');
  }

  state.currentTrack = track;
  updateCurrentStats();
}

function updateCurrentStats(count) {
  if (!el.currentRecords) {
    return;
  }
  // 如果传入了筛选后的数量，直接使用；否则根据当前赛道计算
  if (typeof count === 'number') {
    el.currentRecords.textContent = count;
    return;
  }

  let currentData;
  if (state.currentTrack === 'all') {
    currentData = state.lapData;
  } else {
    currentData = state.trackDataMap[state.currentTrack] || [];
  }
  el.currentRecords.textContent = currentData.length;
}

// ==================== 事件绑定 ====================

function bindEvents() {
  // 赛道标签页切换
  if (el.trackTabs) {
    el.trackTabs.addEventListener('click', e => {
      const tab = e.target.closest('.track-tab');
      if (!tab) {
        return;
      }
      const track = tab.dataset.track;
      if (!track) {
        return;
      }
      switchTrack(track);
    });
  }

  // 筛选器变化
  if (el.trackSelect) {
    el.trackSelect.addEventListener('change', () => {
      state.filters.track = el.trackSelect.value;
      renderAllTracksTable();
    });
  }
  if (el.carSelect) {
    el.carSelect.addEventListener('change', () => {
      state.filters.car = el.carSelect.value;
      renderAllTracksTable();
    });
  }
  if (el.drivetrainSelect) {
    el.drivetrainSelect.addEventListener('change', () => {
      state.filters.drivetrain = el.drivetrainSelect.value;
      renderAllTracksTable();
    });
  }
  if (el.layoutSelect) {
    el.layoutSelect.addEventListener('change', () => {
      state.filters.layout = el.layoutSelect.value;
      renderAllTracksTable();
    });
  }
  if (el.powerTypeSelect) {
    el.powerTypeSelect.addEventListener('change', () => {
      state.filters.powerType = el.powerTypeSelect.value;
      renderAllTracksTable();
    });
  }
  if (el.modSelect) {
    el.modSelect.addEventListener('change', () => {
      state.filters.mod = el.modSelect.value;
      renderAllTracksTable();
    });
  }
  if (el.versionSelect) {
    el.versionSelect.addEventListener('change', () => {
      state.filters.version = el.versionSelect.value;
      renderAllTracksTable();
    });
  }

  // 搜索（防抖）
  if (el.searchInput) {
    const debouncedSearch = debounce(value => {
      state.filters.search = value;
      renderAllTracksTable();
    }, 200);
    el.searchInput.addEventListener('input', () => {
      debouncedSearch(el.searchInput.value.trim());
    });
  }

  // 重置筛选
  if (el.resetFilters) {
    el.resetFilters.addEventListener('click', () => {
      state.filters = {
        track: 'all',
        car: 'all',
        drivetrain: 'all',
        layout: 'all',
        powerType: 'all',
        mod: 'all',
        version: 'all',
        search: '',
      };
      // 重置 UI
      el.trackSelect.value = 'all';
      el.carSelect.value = 'all';
      el.drivetrainSelect.value = 'all';
      el.layoutSelect.value = 'all';
      el.powerTypeSelect.value = 'all';
      el.modSelect.value = 'all';
      el.versionSelect.value = 'all';
      el.searchInput.value = '';
      renderAllTracksTable();
    });
  }

  // 表头排序
  if (el.allTracksTable) {
    el.allTracksTable.addEventListener('click', e => {
      const th = e.target.closest('th[data-sort]');
      if (!th) {
        return;
      }
      const column = th.dataset.sort;
      if (!column) {
        return;
      }

      // 切换排序方向
      if (state.sort.column === column) {
        state.sort.direction = state.sort.direction === 'asc' ? 'desc' : 'asc';
      } else {
        state.sort.column = column;
        // 圈速、排名默认升序（小在前），其他默认降序
        state.sort.direction = (column === 'time' || column === 'rank') ? 'asc' : 'desc';
      }

      updateSortIndicators();
      renderAllTracksTable();
    });
  }
}

// ==================== 初始化 ====================

function initApp() {
  bindEvents();
  loadData();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initApp);
} else {
  initApp();
}
