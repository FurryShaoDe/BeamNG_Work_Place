// ==================== 主题实时调色盘 ====================
// 通过改写 :root CSS 变量实时调整任意颜色：
// - 拖动取色器即时生效（rgb 伴生变量同步更新，半透明派生色自动跟随）
// - localStorage 持久化，刷新不丢失
// - 一键恢复默认、一键复制当前主题为 :root CSS 代码
// - 预设：网页内记录（localStorage 多预设）+ 导出/导入本地 JSON 文件（备份与跨设备迁移）
(function () {
  'use strict';

  const STORAGE_KEY = 'beamng-theme-v1';
  const PRESETS_KEY = 'beamng-presets-v1';

  // 可调色条目：group 分组 / label 中文名 / hexVar 颜色变量 / rgbVar 半透明伴生变量
  const ITEMS = [
    { group: '背景', label: '页面主背景', hexVar: '--bg-primary', rgbVar: '--bg-primary-rgb' },
    { group: '背景', label: '页面渐变副背景', hexVar: '--bg-secondary', rgbVar: '--bg-secondary-rgb' },
    { group: '背景', label: '卡片背景', hexVar: '--bg-card-color', rgbVar: '--bg-card-rgb' },
    { group: '背景', label: '卡片悬停背景', hexVar: '--bg-card-hover-color', rgbVar: '--bg-card-hover-rgb' },
    { group: '文字', label: '主文字', hexVar: '--text-primary', rgbVar: '--text-primary-rgb' },
    { group: '文字', label: '次要文字', hexVar: '--text-secondary', rgbVar: '--text-secondary-rgb' },
    { group: '文字', label: '弱化文字', hexVar: '--text-muted', rgbVar: '--text-muted-rgb' },
    { group: '文字', label: '暖白（标题渐变亮端）', hexVar: '--text-warm', rgbVar: null },
    { group: '强调色', label: '主强调（按钮/品牌）', hexVar: '--accent-pink', rgbVar: '--accent-pink-rgb' },
    { group: '强调色', label: '次强调（时间/箭头）', hexVar: '--accent-orange', rgbVar: '--accent-orange-rgb' },
    { group: '强调色', label: '信息色（链接/车名）', hexVar: '--accent-cyan', rgbVar: '--accent-cyan-rgb' },
    { group: '强调色', label: '金牌', hexVar: '--accent-gold', rgbVar: '--accent-gold-rgb' },
    { group: '强调色', label: '银牌', hexVar: '--accent-silver', rgbVar: '--accent-silver-rgb' },
    { group: '强调色', label: '铜牌/橄榄棕', hexVar: '--accent-bronze', rgbVar: '--accent-bronze-rgb' },
    { group: '强调色', label: '绿色系（模组/前驱）', hexVar: '--accent-green', rgbVar: '--accent-green-rgb' },
    { group: '强调色', label: '蓝色系（后驱）', hexVar: '--accent-blue', rgbVar: '--accent-blue-rgb' },
    { group: '强调色', label: '红色系（错误提示）', hexVar: '--accent-red', rgbVar: '--accent-red-rgb' },
    { group: '名次徽章', label: '金牌徽章深端', hexVar: '--badge-gold-end', rgbVar: null },
    { group: '名次徽章', label: '银牌徽章深端', hexVar: '--badge-silver-end', rgbVar: null },
    { group: '名次徽章', label: '铜牌徽章深端', hexVar: '--badge-bronze-end', rgbVar: null },
  ];

  const root = document.documentElement;
  const panel = document.getElementById('themePanel');
  const itemsBox = document.getElementById('themeItems');
  const toggleBtn = document.getElementById('themeToggle');
  const closeBtn = document.getElementById('themeClose');
  const resetBtn = document.getElementById('themeReset');
  const copyBtn = document.getElementById('themeCopy');
  const toast = document.getElementById('themeToast');
  const presetName = document.getElementById('presetName');
  const presetSave = document.getElementById('presetSave');
  const presetList = document.getElementById('presetList');
  const presetExport = document.getElementById('presetExport');
  const presetImport = document.getElementById('presetImport');
  const presetFileInput = document.getElementById('presetFileInput');

  // ---------- 基础：变量读写 ----------

  function hexToRgb(hex) {
    const value = parseInt(hex.slice(1), 16);
    return [(value >> 16) & 255, (value >> 8) & 255, value & 255].join(', ');
  }

  function currentHex(varName) {
    const value = getComputedStyle(root).getPropertyValue(varName).trim();
    return value.startsWith('#') ? value : null;
  }

  function applyItem(item, hex) {
    root.style.setProperty(item.hexVar, hex);
    if (item.rgbVar) {
      root.style.setProperty(item.rgbVar, hexToRgb(hex));
    }
  }

  /** 收集当前全部可调色的生效值（内联优先，否则取 CSS 默认值） */
  function getThemeValues() {
    const theme = {};
    ITEMS.forEach(item => {
      const value = root.style.getPropertyValue(item.hexVar).trim() || currentHex(item.hexVar);
      if (value) {
        theme[item.hexVar] = value;
      }
    });
    return theme;
  }

  /** 应用一组主题值（hexVar -> hex），rgb 伴生变量自动同步 */
  function applyThemeValues(theme) {
    ITEMS.forEach(item => {
      if (theme[item.hexVar]) {
        applyItem(item, theme[item.hexVar]);
      }
    });
  }

  function saveTheme() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(getThemeValues()));
  }

  function loadTheme() {
    let saved = {};
    try {
      saved = JSON.parse(localStorage.getItem(STORAGE_KEY)) || {};
    } catch (e) {
      saved = {};
    }
    applyThemeValues(saved);
  }

  function syncInputs() {
    itemsBox.querySelectorAll('input[type="color"]').forEach(input => {
      const hex = currentHex(input.dataset.var);
      if (hex) {
        input.value = hex;
      }
    });
  }

  function showToast(message) {
    if (!toast) {
      return;
    }
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toast._timer);
    toast._timer = setTimeout(() => toast.classList.remove('show'), 1800);
  }

  function resetTheme() {
    localStorage.removeItem(STORAGE_KEY);
    ITEMS.forEach(item => {
      root.style.removeProperty(item.hexVar);
      if (item.rgbVar) {
        root.style.removeProperty(item.rgbVar);
      }
    });
    syncInputs();
    showToast('已恢复默认配色');
  }

  function copyTheme() {
    const lines = ITEMS.map(item => {
      const value = root.style.getPropertyValue(item.hexVar).trim() || currentHex(item.hexVar);
      return value ? `  ${item.hexVar}: ${value};` : null;
    }).filter(Boolean);
    const css = `:root {\n${lines.join('\n')}\n}`;
    const done = () => showToast('主题 CSS 已复制到剪贴板');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(css).then(done).catch(() => fallbackCopy(css, done));
    } else {
      fallbackCopy(css, done);
    }
  }

  function fallbackCopy(text, done) {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.style.position = 'fixed';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    try {
      document.execCommand('copy');
      done();
    } catch (e) {
      showToast('复制失败，请手动复制控制台输出');
      console.log(text);
    }
    document.body.removeChild(textarea);
  }

  // ---------- 预设：网页内记录（localStorage） ----------

  function loadPresets() {
    try {
      const presets = JSON.parse(localStorage.getItem(PRESETS_KEY));
      return Array.isArray(presets) ? presets : [];
    } catch (e) {
      return [];
    }
  }

  function savePresets(presets) {
    localStorage.setItem(PRESETS_KEY, JSON.stringify(presets));
  }

  function upsertPreset(name, theme) {
    const presets = loadPresets();
    const preset = { name, theme, savedAt: Date.now() };
    const idx = presets.findIndex(p => p.name === name);
    if (idx >= 0) {
      presets[idx] = preset;
    } else {
      presets.push(preset);
    }
    savePresets(presets);
    return presets;
  }

  function renderPresets() {
    if (!presetList) {
      return;
    }
    const presets = loadPresets();
    presetList.innerHTML = '';
    if (presets.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'theme-preset-empty';
      empty.textContent = '暂无预设';
      presetList.appendChild(empty);
      return;
    }
    presets.forEach(preset => {
      const row = document.createElement('div');
      row.className = 'theme-preset-item';

      const applyBtn = document.createElement('button');
      applyBtn.type = 'button';
      applyBtn.className = 'theme-preset-apply';
      applyBtn.textContent = preset.name;
      applyBtn.title = '应用此预设';
      applyBtn.addEventListener('click', () => {
        applyThemeValues(preset.theme);
        saveTheme();
        syncInputs();
        showToast(`已应用预设「${preset.name}」`);
      });
      row.appendChild(applyBtn);

      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'theme-preset-delete';
      delBtn.textContent = '✕';
      delBtn.title = '删除此预设';
      delBtn.addEventListener('click', () => {
        savePresets(loadPresets().filter(p => p !== preset));
        renderPresets();
        showToast(`已删除预设「${preset.name}」`);
      });
      row.appendChild(delBtn);

      presetList.appendChild(row);
    });
  }

  function saveCurrentPreset() {
    const name = (presetName.value || '').trim();
    if (!name) {
      showToast('请先输入预设名称');
      presetName.focus();
      return;
    }
    upsertPreset(name, getThemeValues());
    presetName.value = '';
    renderPresets();
    showToast(`已保存预设「${name}」`);
  }

  // ---------- 预设：本地文件导出 / 导入 ----------

  function exportThemeFile() {
    const name = (presetName.value || '').trim() || '我的主题';
    const payload = {
      name,
      version: 1,
      savedAt: Date.now(),
      theme: getThemeValues(),
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    const safeName = name.replace(/[\\/:*?"<>|\s]+/g, '-').replace(/^-+|-+$/g, '') || 'theme';
    a.download = `beamng-theme-${safeName}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    showToast(`已导出主题文件「${name}」`);
  }

  function importThemeFile(file) {
    if (!file) {
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const payload = JSON.parse(reader.result);
        const theme = payload && payload.theme;
        if (!theme || typeof theme !== 'object') {
          throw new Error('缺少 theme 字段');
        }
        const name = payload.name || file.name.replace(/\.json$/i, '') || '导入的主题';
        applyThemeValues(theme);
        saveTheme();
        syncInputs();
        upsertPreset(name, theme);
        renderPresets();
        showToast(`已导入并应用「${name}」`);
      } catch (e) {
        showToast('导入失败：文件格式不正确');
      }
    };
    reader.onerror = () => showToast('导入失败：无法读取文件');
    reader.readAsText(file);
    presetFileInput.value = '';
  }

  // ---------- 渲染与初始化 ----------

  function render() {
    if (!itemsBox) {
      return;
    }
    let lastGroup = null;
    ITEMS.forEach(item => {
      if (item.group !== lastGroup) {
        lastGroup = item.group;
        const title = document.createElement('div');
        title.className = 'theme-group-title';
        title.textContent = item.group;
        itemsBox.appendChild(title);
      }

      const row = document.createElement('div');
      row.className = 'theme-item';

      const label = document.createElement('label');
      label.textContent = item.label;
      label.htmlFor = item.hexVar;
      row.appendChild(label);

      const input = document.createElement('input');
      input.type = 'color';
      input.id = item.hexVar;
      input.dataset.var = item.hexVar;
      input.value = currentHex(item.hexVar) || '#000000';
      input.addEventListener('input', () => {
        applyItem(item, input.value);
        saveTheme();
      });
      row.appendChild(input);
      itemsBox.appendChild(row);
    });
  }

  function init() {
    loadTheme();
    render();
    renderPresets();

    if (toggleBtn && panel) {
      toggleBtn.addEventListener('click', () => {
        const willShow = panel.hasAttribute('hidden');
        panel.toggleAttribute('hidden', !willShow);
        toggleBtn.setAttribute('aria-expanded', String(willShow));
      });
    }
    if (closeBtn && panel) {
      closeBtn.addEventListener('click', () => {
        panel.setAttribute('hidden', '');
        toggleBtn.setAttribute('aria-expanded', 'false');
      });
    }
    if (resetBtn) {
      resetBtn.addEventListener('click', resetTheme);
    }
    if (copyBtn) {
      copyBtn.addEventListener('click', copyTheme);
    }

    if (presetSave) {
      presetSave.addEventListener('click', saveCurrentPreset);
    }
    if (presetName) {
      presetName.addEventListener('keydown', e => {
        if (e.key === 'Enter') {
          saveCurrentPreset();
        }
      });
    }
    if (presetExport) {
      presetExport.addEventListener('click', exportThemeFile);
    }
    if (presetImport) {
      presetImport.addEventListener('click', () => presetFileInput.click());
    }
    if (presetFileInput) {
      presetFileInput.addEventListener('change', e => importThemeFile(e.target.files[0]));
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
