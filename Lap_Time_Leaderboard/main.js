// ==================== 全局状态 ====================

const state = {
  lapData: [],            // 原始数据
  trackDataMap: {},       // 按赛道分组的数据
  currentTrack: 'all',    // 当前选中的赛道
  sortState: {},          // 各赛道表格排序状态 { trackId: { key, dir } }
};

// ==================== DOM 元素引用 ====================
const el = {
  trackTabs: document.getElementById('trackTabs'),
  allTracksContent: document.getElementById('allTracksContent'),
  dashboardStats: document.getElementById('dashboardStats'),
  dashboardGrid: document.getElementById('dashboardGrid'),
  loading: document.getElementById('loading'),
  errorContainer: document.getElementById('errorContainer'),
  currentRecords: document.getElementById('currentRecords'),
  updateTime: document.getElementById('updateTime'),
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
      <strong>错误：</strong> ${escapeHtml(message)}
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

// ==================== 数据加载 ====================

function loadData() {
  showLoading();
  clearError();

  fetch('data.json', { cache: 'no-store' })
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

      processTrackData();

      // 通知录入表单：数据已就绪，可填充联想选项
      window.dispatchEvent(new CustomEvent('lapDataLoaded'));

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

function processTrackData() {
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

  // 4. 渲染赛道总览仪表盘
  renderDashboard();

  // 5. 更新统计信息
  updateCurrentStats();
}

function generateTrackTabs() {
  if (!el.trackTabs) {
    return;
  }
  const allTab = el.trackTabs.querySelector('.track-tab[data-track="all"]');
  el.trackTabs.innerHTML = '';
  if (allTab) {
    el.trackTabs.appendChild(allTab);
  }

  Object.keys(state.trackDataMap).forEach(track => {
    const count = state.trackDataMap[track].length;
    const tab = document.createElement('div');
    tab.className = 'track-tab';
    tab.dataset.track = track;
    // 键盘可访问：可用 Tab 聚焦，Enter/空格触发（事件委托见 bindEvents）
    tab.setAttribute('role', 'button');
    tab.tabIndex = 0;
    tab.innerHTML = `${escapeHtml(track)} <span class="track-count">${count}</span>`;
    el.trackTabs.appendChild(tab);
  });

  const allCount = el.trackTabs.querySelector('.track-tab[data-track="all"] .track-count');
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
              <th scope="col" class="sortable" data-sort-key="rank">排名</th>
              <th scope="col" class="sortable" data-sort-key="car">车辆</th>
              <th scope="col" class="sortable" data-sort-key="layout">布局</th>
              <th scope="col" class="sortable" data-sort-key="time">圈速</th>
              <th scope="col" class="sortable" data-sort-key="power">马力</th>
              <th scope="col" class="sortable" data-sort-key="drivetrain">驱动</th>
              <th scope="col" class="sortable" data-sort-key="power_type">动力</th>
              <th scope="col" class="sortable" data-sort-key="control_type">控制</th>
              <th scope="col" class="sortable" data-sort-key="mod">模组</th>
              <th scope="col" class="sortable" data-sort-key="game_version">游戏版本</th>
              <th scope="col" class="sortable" data-sort-key="date">日期</th>
            </tr>
          </thead>
          <tbody id="${trackId}TableBody"></tbody>
        </table>
      </div>
    `;

    container.insertBefore(content, statsElement);
    renderTrackTable(track, data);

    // 表头点击排序
    content.querySelector('thead').addEventListener('click', (e) => {
      const th = e.target.closest('th');
      if (!th) {
        return;
      }
      const key = th.dataset.sortKey;
      if (!key) {
        return;
      }
      const sortState = state.sortState[trackId] || (state.sortState[trackId] = { key: 'rank', dir: 'asc' });
      if (sortState.key === key) {
        sortState.dir = sortState.dir === 'asc' ? 'desc' : 'asc';
      } else {
        sortState.key = key;
        sortState.dir = 'asc';
      }
      renderTrackTable(track, data);
      updateSortArrows(content, sortState);
    });
  });
}

// ==================== 赛道总览仪表盘 ====================

/** 驱动分布环形图配色 */
const DRIVETRAIN_COLORS = {
  '前驱': '#4ecdc4',
  '后驱': '#ff6b6b',
  '四驱': '#ffd93d',
};

/** 生成驱动分布环形图 SVG */
function renderDonut(data) {
  const total = data.reduce((sum, d) => sum + d.value, 0);
  if (total === 0) {
    return '';
  }
  const R = 32;
  const C = 2 * Math.PI * R;
  let offset = 0;
  let segments = '';
  data.forEach(d => {
    if (d.value === 0) {
      return;
    }
    const len = (d.value / total) * C;
    segments += `<circle r="${R}" cx="40" cy="40" fill="none" stroke="${d.color}" stroke-width="11" stroke-dasharray="${len} ${C - len}" stroke-dashoffset="${-offset}" transform="rotate(-90 40 40)"/>`;
    offset += len;
  });
  return `<svg viewBox="0 0 80 80" role="img" aria-label="驱动分布环形图">${segments}</svg>`;
}

function renderDashboard() {
  renderDashboardStats();
  renderDashboardGrid();
}

function renderDashboardStats() {
  if (!el.dashboardStats) {
    return;
  }
  const total = state.lapData.length;
  const trackCount = Object.keys(state.trackDataMap).length;
  const carCount = new Set(state.lapData.map(item => item.car)).size;
  const fastest = getFastestRecord(state.lapData);
  el.dashboardStats.innerHTML = `
    <div class="dashboard-stat">
      <div class="stat-value">${total}</div>
      <div class="stat-label">总记录数</div>
    </div>
    <div class="dashboard-stat">
      <div class="stat-value">${trackCount}</div>
      <div class="stat-label">赛道数</div>
    </div>
    <div class="dashboard-stat">
      <div class="stat-value">${carCount}</div>
      <div class="stat-label">车辆数</div>
    </div>
    <div class="dashboard-stat">
      <div class="stat-value gold">${escapeHtml(fastest?.time || '--:--.--')}</div>
      <div class="stat-label">全站最快圈速</div>
    </div>
  `;
}

function renderDashboardGrid() {
  if (!el.dashboardGrid) {
    return;
  }
  el.dashboardGrid.innerHTML = '';
  Object.keys(state.trackDataMap).forEach(track => {
    el.dashboardGrid.appendChild(renderTrackCard(track, state.trackDataMap[track]));
  });
}

function renderTrackCard(track, data) {
  const fastest = getFastestRecord(data);
  const carCount = new Set(data.map(item => item.car)).size;
  const layouts = [...new Set(data.map(item => item.layout))].filter(l => l);

  const drivetrainCounts = {};
  data.forEach(item => {
    const dt = item.drivetrain || '未知';
    drivetrainCounts[dt] = (drivetrainCounts[dt] || 0) + 1;
  });
  const donutData = Object.keys(drivetrainCounts).map(dt => ({
    label: dt,
    value: drivetrainCounts[dt],
    color: DRIVETRAIN_COLORS[dt] || '#888',
  }));

  const powerCounts = {};
  data.forEach(item => {
    const pt = item.power_type || '未知';
    powerCounts[pt] = (powerCounts[pt] || 0) + 1;
  });

  const card = document.createElement('div');
  card.className = 'track-card';
  card.setAttribute('role', 'button');
  card.tabIndex = 0;
  card.innerHTML = `
    <div class="track-card-title">${escapeHtml(track)}</div>
    <div class="track-card-layout">${escapeHtml(layouts.join(' • ')) || '--'}</div>
    <div class="track-card-stats">
      <div class="row"><span class="label">记录数</span><span class="value">${data.length}</span></div>
      <div class="row"><span class="label">车辆数</span><span class="value">${carCount}</span></div>
      <div class="best-record">
        <div class="best-record-label">最佳记录</div>
        <div class="best-record-time">${escapeHtml(fastest?.time || '--:--.--')}</div>
        <div class="best-record-car" title="${escapeHtml(fastest?.car || '')}">${escapeHtml(fastest?.car || '--')}</div>
      </div>
    </div>
    <div class="donut-wrap">
      <div class="donut">${renderDonut(donutData)}</div>
      <div class="donut-legend">
        ${donutData.map(d => `
          <div class="legend-item">
            <span class="legend-dot" style="background:${d.color}"></span>
            <span>${escapeHtml(d.label)}</span>
            <span class="legend-count">${d.value}</span>
          </div>
        `).join('')}
      </div>
    </div>
    <div class="power-tags">
      ${Object.keys(powerCounts).map(pt => `
        <span class="power-tag"><span class="tag-icon">${getPowerTypeIcon(pt)}</span>${escapeHtml(pt)} × ${powerCounts[pt]}</span>
      `).join('')}
    </div>
  `;
  card.addEventListener('click', () => switchTrack(track));
  card.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      switchTrack(track);
    }
  });
  return card;
}

// ==================== 渲染逻辑 ====================

/**
 * 生成单行 HTML
 */
function renderRow(item, index) {
  const displayRank = item._rank || index + 1;
  const rankClass = displayRank <= 3 ? `rank-${displayRank}` : '';
  const modClass = item.mod === '是' ? 'mod-cell-yes' : 'mod-cell-no';
  const drivetrainClass = getDrivetrainClass(item.drivetrain);
  const powerTypeClass = item.power_type === '电车' ? 'electric' : 'gas';
  const powerTypeIcon = getPowerTypeIcon(item.power_type || '');
  const powerTypeText = escapeHtml(item.power_type || '--');
  const modText = escapeHtml(item.mod || '--');

  return `
    <tr class="${rankClass}">
      <td><span class="rank-badge">${displayRank}</span></td>
      <td class="car-cell" title="${escapeHtml(item.car || '')}">${escapeHtml(item.car || '未知车辆')}</td>
      <td>${escapeHtml(item.layout || '--')}</td>
      <td class="time-cell">${escapeHtml(item.time || '--:--.--')}</td>
      <td class="power-cell">${item.power ? escapeHtml(item.power) + ' hp' : '--'}</td>
      <td class="${drivetrainClass}">${escapeHtml(item.drivetrain || '--')}</td>
      <td><span class="power-type-cell ${powerTypeClass}">${powerTypeIcon} ${powerTypeText}</span></td>
      <td><span class="control-type">${escapeHtml(item.control_type || '--')}</span></td>
      <td class="${modClass}">${modText}</td>
      <td>${escapeHtml(item.game_version || '--')}</td>
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
 * 渲染单个赛道表格（按圈速排序）
 */
function renderTrackTable(track, data) {
  const trackId = getTrackId(track);
  const tbody = document.getElementById(`${trackId}TableBody`);
  if (!tbody) {
    return;
  }

  const sortState = state.sortState[trackId] || { key: 'rank', dir: 'asc' };
  // 先按圈速计算原始排名（最快 = 1），作为"排名"列排序基准
  const withRank = [...data]
    .sort((a, b) => timeToMs(a.time) - timeToMs(b.time))
    .map((item, index) => ({ ...item, _rank: index + 1 }));

  const sortedData = [...withRank].sort((a, b) => {
    const result = compareValues(a, b, sortState.key);
    return sortState.dir === 'asc' ? result : -result;
  });

  if (sortedData.length === 0) {
    renderEmptyState(tbody, 11);
    return;
  }

  tbody.innerHTML = sortedData
    .map((item, index) => renderRow(item, index))
    .join('');
}

/**
 * 表头排序比较：排名/圈速/马力/日期按数值，其余按字符串
 */
function compareValues(a, b, key) {
  if (key === 'rank') {
    return a._rank - b._rank;
  }
  if (key === 'time') {
    return timeToMs(a.time) - timeToMs(b.time);
  }
  if (key === 'power') {
    return (a.power || 0) - (b.power || 0);
  }
  if (key === 'date') {
    return dateToSortKey(a.date) - dateToSortKey(b.date);
  }
  const av = String(a[key] || '').toLowerCase();
  const bv = String(b[key] || '').toLowerCase();
  return av.localeCompare(bv, 'zh-Hans-CN');
}

/**
 * 更新表头排序方向箭头（仅当前排序列显示）
 */
function updateSortArrows(content, sortState) {
  content.querySelectorAll('th').forEach(th => {
    th.classList.remove('sort-asc', 'sort-desc');
    if (th.dataset.sortKey === sortState.key) {
      th.classList.add(sortState.dir === 'asc' ? 'sort-asc' : 'sort-desc');
    }
  });
}

// ==================== 工具：获取最快圈速 ====================

function getFastestTime(data) {
  // 复用 getFastestRecord，避免重复的 reduce 逻辑
  return getFastestRecord(data)?.time || '--:--.--';
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
  // 加前缀避免与静态 id（allTracksContent 等）冲突；编码避免空格等字符折叠出相同 id
  return 'track-' + encodeURIComponent(track);
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
  // 赛道标签页切换（点击 + 键盘）
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

    el.trackTabs.addEventListener('keydown', e => {
      if (e.key !== 'Enter' && e.key !== ' ') {
        return;
      }
      const tab = e.target.closest('.track-tab');
      if (!tab || !tab.dataset.track) {
        return;
      }
      e.preventDefault();
      switchTrack(tab.dataset.track);
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
