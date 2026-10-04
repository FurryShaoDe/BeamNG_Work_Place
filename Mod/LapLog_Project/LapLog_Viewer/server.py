#!/usr/bin/env python3
"""LapLog 本地查看器服务器。

读取 BeamNG 用户目录下 LapLog 模组写出的圈速存档（lapLogs/），提供浏览器可视化所需的
JSON 接口。**平时只读**：浏览与分析不写任何文件；只有主动调用 /api/delete 删除圈速记录
时才会写入 lapLogs（样本文件先移入 lapLogs/_trash/ 回收站，再改清单），不需要游戏在运行。

    python server.py [--port 8010] [--root "<BeamNG 用户目录 或 lapLogs 目录>"]

接口：
    GET  /api/catalog                     地图 → 起点 树（含各起点统计；旧版按车辆存放的库
                                          单列在 group=vehicles/<车辆>，没有起点信息）
    GET  /api/laps?start=<level>/<id>     某个起点的圈清单（清单内 + 清单外孤儿样本）
    GET  /api/lap?start=..&id=<gid>       单圈样本，按通道展开（含派生通道）
    GET  /api/export.csv?start=..&id=..   单圈宽表 CSV（MoTeC 式，供外部工具导入）
    POST /api/rescan                      丢弃解析缓存（跑完新圈后点一下即可）
    POST /api/delete?start=..&id=<gid>    删除一条圈速记录（样本移入 _trash，清单同步更新）

删除语义（与游戏内 deleteGhost + reconcilePrimaryGhost 对齐）：
    - 清单内记录：从 laplog.save.library.json 移除该条目，样本 JSON 与清单本身都移入
      lapLogs/_trash/（含一份 *_entry.json 说明，便于手工恢复）；
    - 清单外样本：只把样本文件移入 _trash；
    - 主档案 laplog.save.json 与 .time 侧车：按剩余最快圈重写/移除，避免游戏里显示已删成绩。
"""
import argparse
import json
import math
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ROOT_DIR = Path(__file__).resolve().parent
WEB_DIR = ROOT_DIR / 'web'

# ---------------------------------------------------------------------------
# 通道表：样本列号（1 基）→ 通道定义。
# 这是「以后 LapLog 加采样字段时唯一要动的地方」：加一行，前端曲线就多一条，
# 查看器其余代码不需要改。单位换算也写在这里（scale = 展示值 / 存储值）。
# ---------------------------------------------------------------------------
# 前端（web/app.js 的 SERVER_CODE）依赖这份「服务端代码版本」：页面发现两侧不一致时会提示
# 重启查看器。凡改动 CHANNEL_TABLE / SERVE_CHANNELS / DERIVED_CHANNELS 或返回结构，都要 +1。
# 起因：服务端进程一直跑着旧代码，而静态文件是每次请求现读的，于是浏览器拿到新前端 + 旧 API，
# 新通道永远缺席、面板静默留空（用户 2026-10-04 实际踩到）。
VIEWER_CODE_VERSION = 5

DEGREES_PER_RADIAN = 180.0 / math.pi

CHANNEL_TABLE = [
    (1,  't',         '时间',     's',    1.0),
    (2,  'pos_x',     'X',        'm',    1.0),
    (3,  'pos_y',     'Y',        'm',    1.0),
    (4,  'pos_z',     '海拔',     'm',    1.0),
    (5,  'front_x',   '前向 X',   '',     1.0),
    (6,  'front_y',   '前向 Y',   '',     1.0),
    (7,  'front_z',   '前向 Z',   '',     1.0),
    (8,  'up_x',      '上向 X',   '',     1.0),
    (9,  'up_y',      '上向 Y',   '',     1.0),
    (10, 'up_z',      '上向 Z',   '',     1.0),
    (11, 'speed',     '速度',     'km/h', 3.6),
    (12, 'throttle',  '油门',     '%',    100.0),
    (13, 'brake',     '刹车',     '%',    100.0),
    (14, 'gear',      '档位',     '',     1.0),
    (15, 'handbrake', '手刹',     '%',    100.0),
    (16, 'clutch',    '离合',     '%',    100.0),
    # format 4（LapLog 1.0.2+）：四轮垂直接地载荷（存储 N，展示 kN）与车身姿态
    # （存储 rad，展示角度）。角标固定为 前左/前右/后左/后右，缺轮记 0。
    (17, 'load_fl',   '前左载荷', 'kN',   0.001),
    (18, 'load_fr',   '前右载荷', 'kN',   0.001),
    (19, 'load_rl',   '后左载荷', 'kN',   0.001),
    (20, 'load_rr',   '后右载荷', 'kN',   0.001),
    (21, 'roll',      '侧倾',     '°',    DEGREES_PER_RADIAN),
    (22, 'pitch',     '俯仰',     '°',    DEGREES_PER_RADIAN),
]

# 只把画图用得到的通道发给前端（省流量）；前向向量在服务端算完派生量后即可丢弃。
SERVE_CHANNELS = [
    't', 'pos_x', 'pos_y', 'pos_z',
    'speed', 'throttle', 'brake', 'gear', 'handbrake', 'clutch',
    'load_fl', 'load_fr', 'load_rl', 'load_rr', 'roll', 'pitch',
]
# 服务端派生的通道：距离 / 纵向加速度 / 横向 G / 航向（播放箭头用）/ 地形坡度 / 去地形俯仰
DERIVED_CHANNELS = ['heading', 'dist', 'accel_lon', 'g_lat', 'grade', 'pitch_road']

# 地形坡度的前瞻窗口（米）：太小会被逐帧噪声带走，太大就跟不上坡顶/坡底
GRADE_WINDOW_M = 25.0

STANDARD_GRAVITY = 9.80665
NAME_SAFE_RE = re.compile(r'^[A-Za-z0-9_.\- ]+$')

# 旧版「按车辆存放」的库：模组的默认回放文件名是 lapLogs/<vehicleDirectory>/laplog.save.json，
# 而 BeamNG 的 vehicleDirectory 本身就是 "vehicles/<车名>"，于是**没有活动起点**时（地图上还没
# 设置起点就手动录制、或中途 reset 存残圈）会落地成 lapLogs/vehicles/<车名>/。它既不在
# freeRoam/ 也不在 races/ 下，早些版本的查看器只扫那两个分组，记录就此"看不见"。
# 这里把它单列成 group=vehicles/<车名>，语义与原目录一一对应。
LEGACY_VEHICLE_GROUP = 'vehicles'
LEGACY_VEHICLE_START_ID = 'library'

# 删除时把文件挪到这里（位于 lapLogs 根下，游戏不会扫描它，可手工恢复）
TRASH_DIRNAME = '_trash'

JSON_CACHE = {}
JSON_CACHE_LIMIT = 64


# ---------------------------------------------------------------------------
# 数据根定位
# ---------------------------------------------------------------------------
def _looks_like_lap_logs(path):
    return path.is_dir() and ((path / 'freeRoam').is_dir() or (path / 'races').is_dir()
                              or path.name.lower() == 'laplogs')


def find_lap_logs(explicit=None):
    """返回 lapLogs 目录。explicit 可以是用户目录、版本目录，或 lapLogs 本身。"""
    tried = []
    if explicit:
        p = Path(explicit).expanduser()
        tried.append(p)
        if _looks_like_lap_logs(p):
            return p
        if (p / 'lapLogs').is_dir():
            return p / 'lapLogs'
        raise SystemExit('找不到 lapLogs 目录。试过：\n  ' + '\n  '.join(str(t) for t in tried))

    local = os.environ.get('LOCALAPPDATA')
    bases = []
    if local:
        beamng = Path(local) / 'BeamNG'
        bases += [beamng / 'BeamNG.drive' / 'current', beamng / 'BeamNG.drive', beamng]
        bases.append(Path(local) / 'BeamNG.drive')
    for base in bases:
        tried.append(base)
        if (base / 'lapLogs').is_dir():
            return base / 'lapLogs'
        # 版本目录（current 之外）：挑名字最大的一个
        if base.is_dir():
            version_dirs = sorted((d for d in base.iterdir() if d.is_dir() and d.name != 'current'),
                                  key=lambda d: d.name, reverse=True)
            for d in version_dirs:
                tried.append(d)
                if (d / 'lapLogs').is_dir():
                    return d / 'lapLogs'
    raise SystemExit('未找到 BeamNG 的 lapLogs 目录，请用 --root 指定。试过：\n  '
                     + '\n  '.join(str(t) for t in tried))


# ---------------------------------------------------------------------------
# 读取与扫描
# ---------------------------------------------------------------------------
def read_json(path):
    """带 mtime 缓存的 JSON 读取；读不到返回 None。"""
    try:
        stat = path.stat()
    except OSError:
        return None
    key = str(path)
    cached = JSON_CACHE.get(key)
    if cached and cached[0] == stat.st_mtime_ns and cached[1] == stat.st_size:
        return cached[2]
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if len(JSON_CACHE) > JSON_CACHE_LIMIT:
        JSON_CACHE.clear()
    JSON_CACHE[key] = (stat.st_mtime_ns, stat.st_size, data)
    return data


def safe_name(value):
    value = str(value or '')
    return bool(NAME_SAFE_RE.match(value)) and '..' not in value


def start_dir(lap_logs, group, level, start_id):
    """定位起点目录，并拒绝目录穿越。

    常规：<group>/<level>/starts/<id>/；旧版按车辆存放的库是平的：vehicles/<车辆>/，
    此时 level 就是车辆目录名，start_id 只是占位（固定 LEGACY_VEHICLE_START_ID）。
    """
    if group == LEGACY_VEHICLE_GROUP:
        if not safe_name(level):
            return None
        path = (Path(lap_logs) / LEGACY_VEHICLE_GROUP / level).resolve()
        try:
            path.relative_to(Path(lap_logs).resolve())
        except ValueError:
            return None
        return path if path.is_dir() else None
    if not (safe_name(level) and safe_name(start_id)):
        return None
    path = (lap_logs / group / level / 'starts' / start_id).resolve()
    try:
        path.relative_to(Path(lap_logs).resolve())
    except ValueError:
        return None
    return path if path.is_dir() else None


def scan_ghost_files(directory):
    """返回 {id: Path}，只认可信的 <id>.json 文件名。"""
    ghosts = {}
    sub = directory / 'laplog.save.ghosts'
    if not sub.is_dir():
        return ghosts
    try:
        entries = sorted(sub.iterdir())
    except OSError:
        return ghosts
    for f in entries:
        if f.is_file() and f.suffix.lower() == '.json' and safe_name(f.stem):
            ghosts[f.stem] = f
    return ghosts


def resolve_sample_file(lap_logs, entry, directory, ghost_id):
    """优先用清单里的 file 字段（VFS 路径），否则回退到 <id>.json。"""
    file_field = str(entry.get('file') or '').replace('\\', '/').lstrip('/')
    if file_field:
        candidate = (Path(lap_logs).parent / file_field).resolve()
        try:
            candidate.relative_to(Path(lap_logs).resolve())
        except ValueError:
            candidate = None
        if candidate and candidate.is_file():
            return candidate
    files = scan_ghost_files(directory)
    return files.get(ghost_id)


def summarize_library(directory):
    """清单 + 磁盘样本的统计（起点目录与旧版按车辆目录共用）。"""
    library = read_json(directory / 'laplog.save.library.json') or {}
    ghosts = library.get('ghosts') or []
    on_disk = scan_ghost_files(directory)
    known = {str(g.get('id')) for g in ghosts}
    primary = read_json(directory / 'laplog.save.json') or {}
    lap_times = [float(g['lapTime']) for g in ghosts
                 if isinstance(g.get('lapTime'), (int, float))]
    return {
        'library': library,
        'pbTime': min(lap_times) if lap_times else (primary.get('lapTime') or None),
        'lapCount': len(ghosts),
        'incompleteCount': sum(1 for g in ghosts if g.get('complete') is False),
        'manualCount': sum(1 for g in ghosts if g.get('manual') is True),
        'orphanCount': len(set(on_disk) - known),
    }


def summarize_start(lap_logs, group, level, start_id, line):
    directory = start_dir(lap_logs, group, level, start_id)
    if directory is None:
        return None
    stats = summarize_library(directory)
    return {
        'id': start_id,
        'name': line.get('name') or start_id,
        'startKey': line.get('startKey') or start_id,
        'kind': line.get('kind'),
        'userNamed': bool(line.get('userNamed')),
        'position': line.get('position'),
        'normal': line.get('normal'),
        'finishPosition': line.get('finishPosition'),
        'finishNormal': line.get('finishNormal'),
        'startLine': stats['library'].get('startLine'),
        'pbTime': stats['pbTime'],
        'lapCount': stats['lapCount'],
        'incompleteCount': stats['incompleteCount'],
        'manualCount': stats['manualCount'],
        'orphanCount': stats['orphanCount'],
    }


def legacy_vehicle_dirs(lap_logs):
    """lapLogs/vehicles/<车辆>/ 里真正存了库的目录（按名称排序）。"""
    root = Path(lap_logs) / LEGACY_VEHICLE_GROUP
    if not root.is_dir():
        return []
    try:
        entries = sorted(root.iterdir(), key=lambda p: p.name)
    except OSError:
        return []
    result = []
    for directory in entries:
        if not directory.is_dir() or not safe_name(directory.name):
            continue
        if ((directory / 'laplog.save.library.json').is_file()
                or (directory / 'laplog.save.json').is_file()):
            result.append(directory)
    return result


def summarize_legacy_vehicle(lap_logs, directory):
    """旧版按车辆存放的库 → 目录树里的一个「起点」（id 固定 LEGACY_VEHICLE_START_ID）。"""
    stats = summarize_library(directory)
    if stats['lapCount'] + stats['orphanCount'] == 0:
        return None
    return {
        'id': LEGACY_VEHICLE_START_ID,
        'name': directory.name + '（按车辆存放）',
        'startKey': None,
        'kind': 'legacyVehicle',
        'userNamed': False,
        'position': None,
        'normal': None,
        'finishPosition': None,
        'finishNormal': None,
        'startLine': stats['library'].get('startLine'),
        'pbTime': stats['pbTime'],
        'lapCount': stats['lapCount'],
        'incompleteCount': stats['incompleteCount'],
        'manualCount': stats['manualCount'],
        'orphanCount': stats['orphanCount'],
        'legacyVehicle': True,
    }


def build_catalog(lap_logs):
    levels = []
    for group in ('freeRoam', 'races'):
        base = lap_logs / group
        if not base.is_dir():
            continue
        try:
            level_dirs = sorted((d for d in base.iterdir() if d.is_dir()), key=lambda d: d.name)
        except OSError:
            continue
        for level_dir in level_dirs:
            registry = read_json(level_dir / 'startLines.json') or {}
            starts = []
            seen = set()
            for line in registry.get('lines') or []:
                start_id = str(line.get('id') or '')
                if not safe_name(start_id):
                    continue
                summary = summarize_start(lap_logs, group, level_dir.name, start_id, line)
                if summary:
                    starts.append(summary)
                    seen.add(start_id)
            # 注册表里没写、但磁盘上存在的起点目录（罕见）：也列出来，避免"数据看不见"
            starts_root = level_dir / 'starts'
            if starts_root.is_dir():
                for d in sorted((x for x in starts_root.iterdir() if x.is_dir()), key=lambda x: x.name):
                    if d.name in seen or not safe_name(d.name):
                        continue
                    summary = summarize_start(lap_logs, group, level_dir.name, d.name,
                                              {'name': d.name})
                    if summary:
                        summary['unregistered'] = True
                        starts.append(summary)
            levels.append({
                'group': group,
                'level': level_dir.name,
                'activeId': registry.get('activeId'),
                'starts': starts,
            })
    # 旧版按车辆存放的库：不属于任何地图/起点（手动录制的片段常在这里），但同样要看得见。
    # 不给 activeId —— 否则前端 pickDefaultStart 会把它顶成默认选中项，掩盖真正的赛道。
    for directory in legacy_vehicle_dirs(lap_logs):
        summary = summarize_legacy_vehicle(lap_logs, directory)
        if summary is None:
            continue
        levels.append({
            'group': LEGACY_VEHICLE_GROUP,
            'level': directory.name,
            'activeId': None,
            'starts': [summary],
            'legacyVehicle': True,
        })
    return {'root': str(lap_logs), 'levels': levels, 'scannedAt': time.time(),
            'code': VIEWER_CODE_VERSION}


def build_laps(lap_logs, group, level, start_id):
    directory = start_dir(lap_logs, group, level, start_id)
    if directory is None:
        return None
    library = read_json(directory / 'laplog.save.library.json') or {}
    laps = []
    known = set()
    for ghost in library.get('ghosts') or []:
        ghost_id = str(ghost.get('id') or '')
        if not ghost_id:
            continue
        known.add(ghost_id)
        laps.append({
            'id': ghost_id,
            'label': ghost.get('label') or ghost_id,
            'lapTime': ghost.get('lapTime'),
            'duration': ghost.get('duration'),
            'sampleInterval': ghost.get('sampleInterval'),
            'source': ghost.get('source'),
            'complete': ghost.get('complete') is not False,
            'manual': ghost.get('manual') is True,
            'vehicle': ghost.get('vehicle'),
            'color': ghost.get('color'),
            'pinned': ghost.get('pinned') is True,
            'hasInputs': ghost.get('hasInputs') is True,
            'orphan': False,
        })
    # 清单外的样本（例如手动录制残留）：一并列出，标记 orphan
    for ghost_id in sorted(set(scan_ghost_files(directory)) - known):
        envelope = read_json(scan_ghost_files(directory)[ghost_id]) or {}
        laps.append({
            'id': ghost_id,
            'label': envelope.get('label') or '清单外样本',
            'lapTime': envelope.get('lapTime'),
            'duration': envelope.get('duration'),
            'sampleInterval': envelope.get('sampleInterval'),
            'source': envelope.get('source') or 'unknown',
            'complete': envelope.get('complete') is not False,
            'manual': envelope.get('source') == 'manual',
            'vehicle': envelope.get('vehicle'),
            'color': None,
            'pinned': False,
            'hasInputs': None,
            'orphan': True,
        })
    laps.sort(key=lambda lap: (lap['lapTime'] is None,
                               lap['lapTime'] if lap['lapTime'] is not None else 0.0))
    start_line = library.get('startLine')
    return {
        'group': group,
        'level': level,
        'startId': start_id,
        'startLine': start_line,
        'laps': laps,
    }


# ---------------------------------------------------------------------------
# 样本 → 命名通道
# ---------------------------------------------------------------------------
def build_channels(samples):
    """把样本数组展开成命名通道，并补上派生通道（距离/纵向加速度/横向 G）。

    旧档案（format 2/3）的样本更短：缺列按 0 填充，但会在通道上标 available=False，
    前端据此跳过该曲线，免得把「没记录」画成一条零线。
    """
    columns = max((len(row) for row in samples if isinstance(row, list)), default=0)
    values = {cid: [] for _, cid, _, _, _ in CHANNEL_TABLE}
    for row in samples:
        if not isinstance(row, list):
            continue
        for index, cid, _label, _unit, scale in CHANNEL_TABLE:
            raw = row[index - 1] if index - 1 < len(row) else None
            num = float(raw) if isinstance(raw, (int, float)) else 0.0
            values[cid].append(num * scale)

    times = values['t']
    count = len(times)
    pos_x, pos_y, pos_z = values['pos_x'], values['pos_y'], values['pos_z']
    speed = values['speed']

    # 距离轴：沿轨迹累计的 3D 距离（画图与多圈对齐都以它为横轴）
    dist = [0.0] * count
    for i in range(1, count):
        dx = pos_x[i] - pos_x[i - 1]
        dy = pos_y[i] - pos_y[i - 1]
        dz = pos_z[i] - pos_z[i - 1]
        dist[i] = dist[i - 1] + math.sqrt(dx * dx + dy * dy + dz * dz)
    values['dist'] = dist

    # 纵向加速度（g）：对速度（m/s）做中心差分
    accel = [0.0] * count
    for i in range(count):
        lo = max(0, i - 1)
        hi = min(count - 1, i + 1)
        span = times[hi] - times[lo]
        if span > 1e-6:
            accel[i] = (speed[hi] / 3.6 - speed[lo] / 3.6) / span / STANDARD_GRAVITY
    values['accel_lon'] = accel

    # 航向角（弧度）：播放时给轨迹图箭头定向；插值由前端按 sin/cos 处理，避免 ±pi 跳变
    front_x, front_y = values['front_x'], values['front_y']
    heading = [math.atan2(front_y[i], front_x[i]) if (front_x[i] or front_y[i]) else 0.0
               for i in range(count)]
    values['heading'] = heading

    # 横向 G：由前向向量求航向角速度，g_lat = v * yawRate / g
    lateral = [0.0] * count
    for i in range(count):
        lo = max(0, i - 1)
        hi = min(count - 1, i + 1)
        span = times[hi] - times[lo]
        if span <= 1e-6:
            continue
        delta = heading[hi] - heading[lo]
        while delta > math.pi:
            delta -= 2 * math.pi
        while delta < -math.pi:
            delta += 2 * math.pi
        yaw_rate = delta / span
        lateral[i] = speed[i] / 3.6 * yaw_rate / STANDARD_GRAVITY
    values['g_lat'] = lateral

    # 地形坡度（%）：沿行进方向的**水平**爬升率，用 ~25 m 前瞻窗口平滑。
    # 存在的理由：记录的 roll/pitch 是「世界姿态」，在坡道上几乎被地形主导
    # （278 s 的真实山道圈实测 corr(pitch, 坡度) = +0.97，与纵向加速度只有 −0.10），
    # 所以直接用 pitch 画悬架会变成"油门刹车对不上倾角"。
    horiz = [0.0] * count
    for i in range(1, count):
        dx = pos_x[i] - pos_x[i - 1]
        dy = pos_y[i] - pos_y[i - 1]
        horiz[i] = horiz[i - 1] + math.sqrt(dx * dx + dy * dy)
    grade = [0.0] * count
    lookahead = 0
    for i in range(count):
        j = max(i, min(lookahead, count - 1))
        while j + 1 < count and horiz[j] - horiz[i] < GRADE_WINDOW_M:
            j += 1
        lookahead = j
        span = horiz[j] - horiz[i]
        grade[i] = (pos_z[j] - pos_z[i]) / span * 100.0 if span > 1.0 else 0.0
    values['grade'] = grade

    # 俯仰（去地形）= 实测俯仰 − 坡度角（度）：剩下的才主要是悬架俯仰。
    # 符号已用真实数据验证：爬坡时 pitch 为正（与坡度同号），去掉之后加速抬头、刹车低头。
    pitch = values['pitch']
    values['pitch_road'] = [pitch[i] - math.degrees(math.atan(grade[i] / 100.0))
                            for i in range(count)]

    labels = {cid: (label, unit) for _i, cid, label, unit, _s in CHANNEL_TABLE}
    labels['heading'] = ('航向', 'rad')
    labels['dist'] = ('距离', 'm')
    labels['accel_lon'] = ('纵向加速度', 'g')
    labels['g_lat'] = ('横向 G', 'g')
    labels['grade'] = ('地形坡度', '%')
    labels['pitch_road'] = ('俯仰(去地形)', '°')

    columns_of = {cid: index for index, cid, _l, _u, _s in CHANNEL_TABLE}

    channels = {}
    for cid in SERVE_CHANNELS + DERIVED_CHANNELS:
        label, unit = labels[cid]
        channels[cid] = {
            'label': label,
            'unit': unit,
            # 派生通道永远可用；样本通道要看这一圈真的写到那一列没有
            'available': columns >= columns_of.get(cid, 0),
            'values': [round(v, 4) if cid == 't' else round(v, 3) for v in values[cid]],
        }
    return channels


def load_lap(lap_logs, group, level, start_id, ghost_id):
    directory = start_dir(lap_logs, group, level, start_id)
    if directory is None or not safe_name(ghost_id):
        return None
    library = read_json(directory / 'laplog.save.library.json') or {}
    entry = None
    for ghost in library.get('ghosts') or []:
        if str(ghost.get('id')) == ghost_id:
            entry = ghost
            break
    path = resolve_sample_file(lap_logs, entry or {}, directory, ghost_id)
    if path is None:
        return None
    envelope = read_json(path)
    if not envelope or not isinstance(envelope.get('samples'), list):
        return None
    samples = envelope['samples']
    channels = build_channels(samples)
    return {
        'meta': {
            'id': ghost_id,
            'group': group,
            'level': level,
            'startId': start_id,
            'label': (entry or {}).get('label') or envelope.get('label') or ghost_id,
            'lapTime': (entry or {}).get('lapTime') or envelope.get('lapTime'),
            'duration': envelope.get('duration'),
            'sampleInterval': envelope.get('sampleInterval'),
            'source': envelope.get('source') or (entry or {}).get('source'),
            'complete': envelope.get('complete') is not False,
            'vehicle': envelope.get('vehicle') or (entry or {}).get('vehicle'),
            'groundOffset': envelope.get('groundOffset'),
            'formatVersion': envelope.get('formatVersion'),
            'sampleCount': len(samples),
            'columns': max((len(r) for r in samples if isinstance(r, list)), default=0),
            'startLine': library.get('startLine') or envelope.get('startLine'),
        },
        'channels': channels,
    }


def export_csv(lap_logs, group, level, start_id, ghost_id):
    data = load_lap(lap_logs, group, level, start_id, ghost_id)
    if not data:
        return None
    channels = data['channels']
    order = ['t', 'dist', 'speed', 'throttle', 'brake', 'gear', 'handbrake', 'clutch']
    header = ['time_s', 'dist_m', 'speed_kmh', 'throttle_pct', 'brake_pct', 'gear',
              'handbrake_pct', 'clutch_pct']
    # format 4 的通道只出现在真的记录了它们的圈里（旧档案导出的 CSV 少这几列，
    # 而不是补一列 0 骗人）
    for cid, name in (('load_fl', 'load_fl_kn'), ('load_fr', 'load_fr_kn'),
                      ('load_rl', 'load_rl_kn'), ('load_rr', 'load_rr_kn'),
                      ('roll', 'roll_deg'), ('pitch', 'pitch_deg')):
        if channels[cid]['available']:
            order.append(cid)
            header.append(name)
    order += ['accel_lon', 'g_lat', 'pos_x', 'pos_y', 'pos_z']
    header += ['accel_lon_g', 'g_lat_g', 'x_m', 'y_m', 'z_m']
    rows = [','.join(header)]
    count = len(channels['t']['values'])
    for i in range(count):
        rows.append(','.join(str(channels[cid]['values'][i]) for cid in order))
    return '\n'.join(rows) + '\n'


# ---------------------------------------------------------------------------
# 删除（唯一的写入路径：样本与清单先移入 lapLogs/_trash/，再由用户手工清理）
# ---------------------------------------------------------------------------
def _trash_dir(lap_logs):
    path = Path(lap_logs) / TRASH_DIRNAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def move_to_trash(lap_logs, path, tag):
    """把文件移入 <lapLogs>/_trash/。返回 (是否成功, 目标路径)。"""
    try:
        if not path.is_file():
            return False, None
        stamp = time.strftime('%Y%m%d-%H%M%S')
        target = _trash_dir(lap_logs) / ('%s_%s_%s' % (stamp, tag, path.name))
        counter = 1
        while target.exists():
            target = _trash_dir(lap_logs) / ('%s_%s_%d_%s' % (stamp, tag, counter, path.name))
            counter += 1
        os.replace(str(path), str(target))
        return True, target
    except OSError:
        return False, None


def write_file_atomic(path, body, lap_logs=None, tag=None):
    """先写临时文件再原子替换；旧文件（若有）移入回收站。

    返回 (是否成功, 旧文件在回收站里的名字)。替换失败时会把旧文件搬回来，避免丢清单。
    """
    tmp = path.with_name(path.name + '.tmp')
    backup = None
    try:
        tmp.write_bytes(body)
        if path.is_file() and lap_logs is not None:
            ok, target = move_to_trash(lap_logs, path, tag or 'old')
            if ok:
                backup = target.name
        os.replace(str(tmp), str(path))
        return True, backup
    except OSError:
        if backup is not None:
            try:
                os.replace(str(Path(_trash_dir(lap_logs)) / backup), str(path))
            except OSError:
                pass
        try:
            if tmp.is_file():
                tmp.unlink()
        except OSError:
            pass
        return False, backup


def pick_best_ghost(ghosts):
    """对齐游戏 bestGhostEntry：优先计时完整圈里最快的一条，否则取最长的未完成圈。"""
    timed = [g for g in ghosts
             if g.get('complete') is not False and isinstance(g.get('lapTime'), (int, float))]
    if timed:
        return min(timed, key=lambda g: float(g['lapTime']))
    incompletes = [g for g in ghosts if g.get('complete') is False]
    if incompletes:
        return max(incompletes, key=lambda g: float(g.get('duration') or 0.0))
    return None


def delete_lap(lap_logs, group, level, start_id, ghost_id):
    """删除一条圈速记录。返回结果 dict；起点目录不合法返回 None。"""
    directory = start_dir(lap_logs, group, level, start_id)
    if directory is None or not safe_name(ghost_id):
        return None

    manifest_path = directory / 'laplog.save.library.json'
    manifest = read_json(manifest_path)
    ghosts = manifest.get('ghosts') if isinstance(manifest, dict) else None
    if not isinstance(ghosts, list):
        manifest = None
        ghosts = None

    entry = None
    if ghosts is not None:
        for ghost in ghosts:
            if str(ghost.get('id')) == ghost_id:
                entry = ghost
                break
    # 删掉的正是当前主档案对应的那条吗？不是的话主档案无需重写
    was_best = entry is not None and pick_best_ghost(ghosts) is entry

    # 样本文件：清单里的 file 字段优先，其次 <id>.json
    files = []
    if entry is not None:
        resolved = resolve_sample_file(lap_logs, entry, directory, ghost_id)
        if resolved is not None:
            files.append(resolved)
    fallback = scan_ghost_files(directory).get(ghost_id)
    if fallback is not None and fallback not in files:
        files.append(fallback)

    if entry is None and not files:
        return {'ok': False, 'error': '既不在清单里，也找不到样本文件'}

    # 顺序很重要：先把新清单原子落盘，再动样本文件。这样中途失败最坏只留下“清单外样本”，
    # 不会出现清单丢失而样本还在的悬空状态。
    remaining = None
    if ghosts is not None and entry is not None:
        stamp = time.strftime('%Y%m%d-%H%M%S')
        note = {'deletedAt': time.strftime('%Y-%m-%d %H:%M:%S'),
                'manifest': str(manifest_path),
                'group': group, 'level': level, 'startId': start_id,
                'entry': entry}
        ghosts.remove(entry)
        remaining = len(ghosts)
        body = json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        written, backup_name = write_file_atomic(manifest_path, body, lap_logs, 'manifest')
        if not written:
            return {'ok': False, 'error': '清单写入失败（已尝试回滚），未改动任何样本'}
        if backup_name:
            note['manifestBackup'] = backup_name
        try:
            (_trash_dir(lap_logs) / ('%s_%s_entry.json' % (stamp, ghost_id))).write_bytes(
                json.dumps(note, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
        except OSError:
            pass

    moved = []
    for path in files:
        ok, target = move_to_trash(lap_logs, path, 'sample')
        if ok:
            moved.append(target.name)

    if ghosts is not None and entry is not None:
        # 主档案 + .time 侧车：只有被删的是原最快圈时才同步（等价游戏 reconcilePrimaryGhost）
        if was_best:
            primary_path = directory / 'laplog.save.json'
            time_path = directory / 'laplog.save.json.time'
            best = pick_best_ghost(ghosts)
            best_file = None
            if best is not None:
                best_file = resolve_sample_file(lap_logs, best, directory, str(best.get('id')))
            if best_file is not None and best_file.is_file():
                write_file_atomic(primary_path, best_file.read_bytes(), lap_logs, 'primary')
                lap_time = best.get('lapTime')
                if isinstance(lap_time, (int, float)):
                    write_file_atomic(time_path, json.dumps([float(lap_time)],
                                                            separators=(',', ':')).encode('utf-8'),
                                      lap_logs, 'time')
                else:
                    move_to_trash(lap_logs, time_path, 'time')
            else:
                move_to_trash(lap_logs, primary_path, 'primary')
                move_to_trash(lap_logs, time_path, 'time')

    JSON_CACHE.clear()
    return {
        'ok': True,
        'id': ghost_id,
        'label': (entry or {}).get('label') or ghost_id,
        'scope': 'manifest' if entry is not None else 'orphan',
        'moved': moved,
        'remaining': remaining,
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
}


class Handler(BaseHTTPRequestHandler):
    lap_logs = None

    # ---------- 工具 ----------
    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, status, text, ctype='text/plain; charset=utf-8'):
        body = text.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, path):
        target = (WEB_DIR / path.lstrip('/')).resolve()
        try:
            target.relative_to(WEB_DIR)
        except ValueError:
            self.send_error(403)
            return
        if target.is_dir():
            target = target / 'index.html'
        if not target.is_file():
            self.send_error(404)
            return
        ctype = CONTENT_TYPES.get(target.suffix.lower(), 'application/octet-stream')
        body = target.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    @staticmethod
    def _parts(query):
        """把 ?start=freeRoam/smallgrid/s001 拆成 (group, level, id)。"""
        raw = (query.get('start') or [''])[0].replace('\\', '/').strip('/')
        pieces = raw.split('/')
        if len(pieces) != 3:
            return None
        return pieces[0], pieces[1], pieces[2]

    # ---------- 路由 ----------
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == '/':
            self._serve_static('/index.html')
            return

        if path == '/api/catalog':
            self._send_json(200, build_catalog(self.lap_logs))
            return

        if path == '/api/laps':
            parts = self._parts(query)
            if not parts:
                self._send_json(400, {'ok': False, 'error': 'start 参数应为 group/level/id'})
                return
            result = build_laps(self.lap_logs, *parts)
            if result is None:
                self._send_json(404, {'ok': False, 'error': '找不到该起点目录'})
                return
            self._send_json(200, result)
            return

        if path == '/api/lap':
            parts = self._parts(query)
            ghost_id = (query.get('id') or [''])[0]
            if not parts or not ghost_id:
                self._send_json(400, {'ok': False, 'error': '需要 start 与 id 参数'})
                return
            result = load_lap(self.lap_logs, *parts, ghost_id)
            if result is None:
                self._send_json(404, {'ok': False, 'error': '找不到该圈样本文件'})
                return
            self._send_json(200, result)
            return

        if path == '/api/export.csv':
            parts = self._parts(query)
            ghost_id = (query.get('id') or [''])[0]
            csv_text = export_csv(self.lap_logs, *parts, ghost_id) if (parts and ghost_id) else None
            if csv_text is None:
                self._send_json(404, {'ok': False, 'error': '找不到该圈样本文件'})
                return
            self._send_text(200, csv_text, 'text/csv; charset=utf-8')
            return

        self._serve_static(path)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == '/api/rescan':
            JSON_CACHE.clear()
            self._send_json(200, {'ok': True, 'rescan': True})
            return

        if path == '/api/delete':
            parts = self._parts(query)
            ghost_id = (query.get('id') or [''])[0]
            if not parts or not ghost_id:
                self._send_json(400, {'ok': False, 'error': '需要 start 与 id 参数'})
                return
            result = delete_lap(self.lap_logs, *parts, ghost_id)
            if result is None:
                self._send_json(404, {'ok': False, 'error': '找不到该起点目录或参数非法'})
                return
            status = 200 if result.get('ok') else 404
            self._send_json(status, result)
            return

        self._send_json(404, {'ok': False, 'error': '接口不存在'})

    def log_message(self, fmt, *args):
        sys.stderr.write('[%s] %s\n' % (self.log_date_time_string(), fmt % args))


def main(argv=None):
    parser = argparse.ArgumentParser(description='LapLog 本地查看器服务器（浏览只读；删除会写 lapLogs）')
    parser.add_argument('--port', type=int, default=8010, help='监听端口，默认 8010')
    parser.add_argument('--root', default=None,
                        help='BeamNG 用户目录、版本目录，或 lapLogs 目录本身')
    parser.add_argument('--addr', default='127.0.0.1', help='监听地址，默认只监听本机')
    args = parser.parse_args(argv)

    lap_logs = find_lap_logs(args.root)
    Handler.lap_logs = lap_logs
    server = ThreadingHTTPServer((args.addr, args.port), Handler)
    print('LapLog 查看器已启动: http://localhost:%d  （Ctrl+C 停止）' % args.port)
    print('数据目录: %s' % lap_logs)
    print('浏览只读；删除操作会把文件移入 %s\\ 回收站' % TRASH_DIRNAME)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n已停止')


if __name__ == '__main__':
    main()
