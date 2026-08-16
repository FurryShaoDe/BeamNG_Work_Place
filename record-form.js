// ==================== 成绩录入（仅本地环境） ====================
// 线上（GitHub Pages / 自定义域名）只读展示，录入区自动隐藏；
// 本地用 `python server.py` 启动时显示录入表单，提交后由服务器
// 校验并写入 data.json，推送 GitHub 后线上同步展示。
(function () {
  'use strict';

  // 线上只读域名（自定义域名；github.io 域名按后缀统一判定）
  const READ_ONLY_HOSTS = ['beamng.shaode.dpdns.org'];

  const isReadOnly =
    location.hostname.endsWith('.github.io') ||
    READ_ONLY_HOSTS.includes(location.hostname);
  const isFileProtocol = location.protocol === 'file:';

  const section = document.getElementById('recordSection');
  const toggleBtn = document.getElementById('recordToggle');
  const form = document.getElementById('recordForm');
  const submitBtn = document.getElementById('recordSubmit');
  const resetBtn = document.getElementById('recordReset');
  const statusBox = document.getElementById('recordStatus');
  const pendingPanel = document.getElementById('pendingPanel');
  const pendingList = document.getElementById('pendingList');

  const fields = {
    track: document.getElementById('rec-track'),
    layout: document.getElementById('rec-layout'),
    car: document.getElementById('rec-car'),
    time: document.getElementById('rec-time'),
    drivetrain: document.getElementById('rec-drivetrain'),
    powerType: document.getElementById('rec-power-type'),
    power: document.getElementById('rec-power'),
    controlType: document.getElementById('rec-control-type'),
    mod: document.getElementById('rec-mod'),
    gameVersion: document.getElementById('rec-game-version'),
    date: document.getElementById('rec-date'),
  };

  function showStatus(message, isError) {
    if (!statusBox) {
      return;
    }
    statusBox.textContent = message;
    statusBox.className = 'record-status' + (isError ? ' error' : '');
  }

  function fillDatalist(datalist, values) {
    if (!datalist) {
      return;
    }
    datalist.innerHTML = '';
    [...values].sort().forEach(value => {
      const option = document.createElement('option');
      option.value = value;
      datalist.appendChild(option);
    });
  }

  // 用已有数据填充赛道/布局/车辆联想（main.js 的 state 是全局词法环境变量，可直接访问）
  function fillDatalists() {
    const tracks = new Set();
    const layouts = new Set();
    const cars = new Set();
    (typeof state !== 'undefined' && state.lapData ? state.lapData : []).forEach(item => {
      if (item.track) {
        tracks.add(item.track);
      }
      if (item.layout) {
        layouts.add(item.layout);
      }
      if (item.car) {
        cars.add(item.car);
      }
    });
    fillDatalist(document.getElementById('rec-track-list'), tracks);
    fillDatalist(document.getElementById('rec-layout-list'), layouts);
    fillDatalist(document.getElementById('rec-car-list'), cars);
  }

  function setDefaultDate() {
    if (!fields.date) {
      return;
    }
    const now = new Date();
    fields.date.value = `${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()}`;
  }

  function collectRecord() {
    return {
      car: fields.car.value.trim(),
      track: fields.track.value.trim(),
      layout: fields.layout.value.trim(),
      time: fields.time.value.trim(),
      power_type: fields.powerType.value,
      game_version: fields.gameVersion.value.trim(),
      control_type: fields.controlType.value,
      drivetrain: fields.drivetrain.value,
      power: parseInt(fields.power.value, 10) || 0,
      date: fields.date.value.trim(),
      mod: fields.mod.value,
    };
  }

  function validate(record) {
    if (!record.car || !record.track || !record.layout || !record.time) {
      return '车辆、赛道、布局、圈速为必填项';
    }
    if (!/^\d{1,2}:\d{2}\.\d{3}$/.test(record.time)) {
      return '圈速格式应为 MM:SS.mmm（如 01:15.856）';
    }
    if (record.power <= 0) {
      return '马力应为正整数';
    }
    if (!record.date) {
      return '请填写日期';
    }
    return null;
  }

  async function submit() {
    const record = collectRecord();
    const error = validate(record);
    if (error) {
      showStatus(error, true);
      return;
    }
    if (isFileProtocol) {
      showStatus('请用 python server.py 启动本地服务器后再录入', true);
      return;
    }
    submitBtn.disabled = true;
    showStatus('提交中…');
    try {
      const response = await fetch('/api/records', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(record),
      });
      const result = await response.json();
      if (!response.ok || !result.ok) {
        showStatus(result.error || '提交失败', true);
        submitBtn.disabled = false;
        return;
      }
      showStatus(`已录入，共 ${result.count} 条记录，页面刷新中…`);
      setTimeout(() => location.reload(), 600);
    } catch (e) {
      showStatus('提交失败：无法连接本地服务器（请运行 python server.py）', true);
      submitBtn.disabled = false;
    }
  }

  function clearForm() {
    Object.values(fields).forEach(input => {
      if (input) {
        input.value = '';
      }
    });
    setDefaultDate();
    fields.mod.value = '否';
    fields.drivetrain.value = '前驱';
    fields.powerType.value = '油车';
    fields.controlType.value = '手柄';
    showStatus('');
  }

  // ---------- 待确认赛道（游戏自动录入的映射学习） ----------

  async function loadPending() {
    if (!pendingPanel || !pendingList) {
      return;
    }
    try {
      const response = await fetch('/api/pending_tracks');
      const result = await response.json();
      renderPending(result.ok ? result.pending : {});
    } catch (e) {
      // 服务器不可达（如 file:// 或静态服务器）时静默隐藏
      pendingPanel.hidden = true;
    }
  }

  function renderPending(pending) {
    const entries = Object.entries(pending || {});
    pendingList.innerHTML = '';
    pendingPanel.hidden = entries.length === 0;
    if (entries.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'pending-empty';
      empty.textContent = '暂无待确认赛道';
      pendingList.appendChild(empty);
      return;
    }
    entries.forEach(([levelId, info]) => {
      const row = document.createElement('div');
      row.className = 'pending-item';

      const display = document.createElement('span');
      display.className = 'pending-display';
      display.textContent = `${info.display || levelId}（${info.count || 1} 条记录）`;
      display.title = `游戏内 ID: ${levelId}`;
      row.appendChild(display);

      const input = document.createElement('input');
      input.type = 'text';
      input.value = info.display || levelId;
      input.placeholder = '榜单显示名';
      input.setAttribute('aria-label', `赛道 ${levelId} 的显示名`);
      row.appendChild(input);

      const confirmBtn = document.createElement('button');
      confirmBtn.textContent = '确认';
      confirmBtn.addEventListener('click', async () => {
        const name = input.value.trim();
        if (!name) {
          return;
        }
        confirmBtn.disabled = true;
        try {
          const response = await fetch('/api/pending_tracks', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ levelId, name }),
          });
          const result = await response.json();
          if (result.ok) {
            showStatus(`已确认赛道「${name}」`);
          } else {
            showStatus(result.error || '确认失败', true);
          }
        } catch (e) {
          showStatus('确认失败：无法连接本地服务器', true);
        }
        loadPending();
      });
      row.appendChild(confirmBtn);

      pendingList.appendChild(row);
    });
  }

  function init() {
    // 线上只读环境：整个录入区不显示
    if (isReadOnly || !section) {
      return;
    }
    section.hidden = false;
    setDefaultDate();
    fillDatalists();
    loadPending();

    if (toggleBtn && form) {
      toggleBtn.addEventListener('click', () => {
        const willShow = form.hasAttribute('hidden');
        form.toggleAttribute('hidden', !willShow);
        toggleBtn.textContent = willShow ? '－ 收起表单' : '＋ 录入成绩';
        if (willShow) {
          fillDatalists();
        }
      });
    }
    if (submitBtn) {
      submitBtn.addEventListener('click', submit);
    }
    if (resetBtn) {
      resetBtn.addEventListener('click', clearForm);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
