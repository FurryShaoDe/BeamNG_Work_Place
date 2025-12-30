let lapData = [];
let currentSort = { field: 'time', ascending: true };

function timeToMs(timeStr) {
  if (!timeStr || timeStr === '--:--.--') return Infinity;
  const parts = timeStr.split(/[:.]/);
  if (parts.length === 3) {
    const min = parseInt(parts[0]) || 0;
    const sec = parseInt(parts[1]) || 0;
    const ms = parseInt(parts[2].padEnd(3, '0').substring(0, 3)) || 0;
    return min * 60000 + sec * 1000 + ms;
  }
  return Infinity;
}

function msToTime(ms) {
  if (ms === Infinity) return '--:--.--';
  const min = Math.floor(ms / 60000);
  const sec = Math.floor((ms % 60000) / 1000);
  const msPart = ms % 1000;
  return `${min}:${sec.toString().padStart(2, '0')}.${msPart.toString().padStart(3, '0').slice(0, 3)}`;
}

function renderTable(data) {
  const tbody = document.querySelector("#lapTable tbody");
  tbody.innerHTML = "";

  if (data.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" style="text-align:center;padding:40px;">没有数据</td></tr>`;
    return;
  }

  const sortedData = sortData(data, currentSort.field, currentSort.ascending);
  
  sortedData.forEach((item, index) => {
    const tr = document.createElement("tr");
    if (index < 3) tr.className = `rank-${index + 1}`;
    
    tr.innerHTML = `
      <td><strong>${index + 1}</strong></td>
      <td>${item.car || '未知'}</td>
      <td>${item.track || '未知'}</td>
      <td>${item.layout || '--'}</td>
      <td class="time-cell">${item.time || '--:--.--'}</td>
      <td>${item.power || '--'}</td>
      <td>${item.drivetrain || '--'}</td>
      <td>${item.control_type || '--'}</td>
      <td>${item.date || '--'}</td>
    `;
    tbody.appendChild(tr);
  });

  updateStats(sortedData);
}

function updateStats(data) {
  document.getElementById('totalRecords').textContent = data.length;
  
  const times = data.map(item => timeToMs(item.time)).filter(t => t !== Infinity);
  if (times.length > 0) {
    document.getElementById('fastestTime').textContent = msToTime(Math.min(...times));
  }
  
  const powers = data.map(item => parseInt(item.power)).filter(p => !isNaN(p));
  if (powers.length > 0) {
    const avg = Math.round(powers.reduce((a, b) => a + b) / powers.length);
    document.getElementById('avgPower').textContent = avg;
  }
}

function sortData(data, field, ascending) {
  return [...data].sort((a, b) => {
    let aVal = a[field], bVal = b[field];
    
    if (field === 'time') {
      aVal = timeToMs(aVal);
      bVal = timeToMs(bVal);
    } else if (field === 'power') {
      aVal = Number(aVal) || 0;
      bVal = Number(bVal) || 0;
    }
    
    if (ascending) return aVal < bVal ? -1 : aVal > bVal ? 1 : 0;
    else return bVal < aVal ? -1 : bVal > aVal ? 1 : 0;
  });
}

function applyFilters() {
  const track = document.getElementById("trackSelect").value;
  const car = document.getElementById("carSelect").value;
  const drivetrain = document.getElementById("drivetrainSelect").value;
  const layout = document.getElementById("layoutSelect").value;
  
  let filtered = lapData;
  if (track !== "all") filtered = filtered.filter(item => item.track === track);
  if (car !== "all") filtered = filtered.filter(item => item.car === car);
  if (drivetrain !== "all") filtered = filtered.filter(item => item.drivetrain === drivetrain);
  if (layout !== "all") filtered = filtered.filter(item => item.layout === layout);
  
  renderTable(filtered);
}

function populateFilters() {
  const tracks = [...new Set(lapData.map(item => item.track).filter(Boolean))];
  const cars = [...new Set(lapData.map(item => item.car).filter(Boolean))];
  const layouts = [...new Set(lapData.map(item => item.layout).filter(Boolean))];
  
  const trackSelect = document.getElementById("trackSelect");
  const carSelect = document.getElementById("carSelect");
  const layoutSelect = document.getElementById("layoutSelect");
  
  tracks.forEach(track => {
    const option = document.createElement("option");
    option.value = track;
    option.textContent = track;
    trackSelect.appendChild(option);
  });
  
  cars.forEach(car => {
    const option = document.createElement("option");
    option.value = car;
    option.textContent = car;
    carSelect.appendChild(option);
  });
  
  layouts.forEach(layout => {
    const option = document.createElement("option");
    option.value = layout;
    option.textContent = layout;
    layoutSelect.appendChild(option);
  });
}

// 初始化
document.addEventListener("DOMContentLoaded", () => {
  // 直接加载数据，避免fetch跨域问题
  const data = [
    {
      "car": "Covet Type-L(A)",
      "track": "Hirochi赛车场",
      "layout": "短途竞速环道",
      "time": "1:23.495",
      "game_version": "0.38.3",
      "control_type": "手柄",
      "drivetrain": "前驱",
      "power": 180,
      "date": "2025-12-30"
    }
  ];
  
  lapData = data;
  populateFilters();
  applyFilters();
  
  // 添加事件监听
  document.querySelectorAll('.sortable').forEach(th => {
    th.addEventListener('click', () => {
      const field = th.dataset.sort;
      if (currentSort.field === field) {
        currentSort.ascending = !currentSort.ascending;
      } else {
        currentSort = { field, ascending: true };
      }
      applyFilters();
    });
  });
  
  document.getElementById("resetFilters").addEventListener("click", () => {
    document.getElementById("trackSelect").value = "all";
    document.getElementById("layoutSelect").value = "all";
    document.getElementById("carSelect").value = "all";
    document.getElementById("drivetrainSelect").value = "all";
    applyFilters();
  });
});