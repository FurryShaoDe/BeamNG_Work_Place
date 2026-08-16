#!/usr/bin/env python3
"""BeamNG 圈速榜本地服务器：静态文件 + 成绩录入（手动 & 游戏自动）。

两种录入方式：
1. 手动：POST /api/records（网页表单），校验后追加 data.json
2. 游戏自动：轮询 <BeamNG用户目录>/beamng_lap_bridge/records.jsonl
   （由 beamng_lap_bridge.lua 扩展写入），新行入库并去重

赛道显示名自动学习：游戏内地图名（hirochi_raceway）→ 榜单名（Hirochi赛车场）
映射保存在 track_map.json；未映射的新地图会进入待确认队列（pending_tracks.json），
网页可确认改名，或直接编辑 track_map.json。

用法：python server.py [端口] [--userfolder <BeamNG用户目录>]
默认用户目录：%USERPROFILE%/Documents/BeamNG.drive
"""
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA_FILE = ROOT / 'data.json'
TRACK_MAP_FILE = ROOT / 'track_map.json'
PENDING_FILE = ROOT / 'pending_tracks.json'
OFFSET_FILE = ROOT / '.lap_bridge_offset'

# 游戏自动录入时，控制设备无法从游戏读取，用此默认值（网页手动录入可改）
DEFAULT_CONTROL_TYPE = '手柄'

TIME_RE = re.compile(r'^\d{1,2}:\d{2}\.\d{3}$')
REQUIRED_FIELDS = [
    'car', 'track', 'layout', 'time', 'power_type',
    'game_version', 'control_type', 'drivetrain', 'power', 'date', 'mod',
]
# 游戏自动录入的核心字段：车辆规格类字段（power/drivetrain/power_type 等）
# 部分车辆无静态规格数据（mod 车等），允许缺失，前端以 '--' 展示；
# 手动录入仍按 REQUIRED_FIELDS 严格校验
CORE_FIELDS = ['car', 'track', 'layout', 'time', 'date']

CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.css': 'text/css; charset=utf-8',
    '.ico': 'image/x-icon',
}


# ---------- 数据读写 ----------

def load_records():
    with open(DATA_FILE, encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError('data.json 顶层应为数组')
    return data


def save_records(records):
    with open(DATA_FILE, 'w', encoding='utf-8') as f:
        json.dump(records, f, ensure_ascii=False, indent=2)
        f.write('\n')


def load_json(path, default):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, obj):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)


def track_map():
    return load_json(TRACK_MAP_FILE, {})


def pending_tracks():
    return load_json(PENDING_FILE, {})


def validate_record(rec, strict=True):
    """返回错误列表；空列表表示通过。strict=False 用于游戏自动录入。"""
    errors = []
    fields = REQUIRED_FIELDS if strict else CORE_FIELDS
    for field in fields:
        value = rec.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append('缺少字段: %s' % field)
    if errors:
        return errors
    if not TIME_RE.match(str(rec['time'])):
        errors.append('时间格式应为 MM:SS.mmm（如 01:15.856）')
    power = rec.get('power')
    if power is not None and (not isinstance(power, int) or power <= 0):
        errors.append('马力应为正整数')
    return errors


def append_record(rec, strict=True):
    """校验并追加；返回 (ok, message)。"""
    errors = validate_record(rec, strict=strict)
    if errors:
        return False, '；'.join(errors)
    records = load_records()
    # 去重：同一车辆/赛道/布局/圈速视为重复
    key = (rec['car'], rec['track'], rec['layout'], rec['time'])
    for existing in records:
        if (existing.get('car'), existing.get('track'), existing.get('layout'), existing.get('time')) == key:
            return False, '记录已存在（重复）'
    records.append(rec)
    save_records(records)
    return True, '已录入，共 %d 条' % len(records)


# ---------- 游戏 JSONL 轮询 ----------

def default_userfolder_candidates(argv):
    """返回候选用户目录列表；显式 --userfolder 优先。
    注意：新版 BeamNG（0.39+）默认用户目录在
    %LOCALAPPDATA%/BeamNG/BeamNG.drive/current，旧版在 Documents/BeamNG.drive。"""
    for i, arg in enumerate(argv):
        if arg == '--userfolder' and i + 1 < len(argv):
            return [Path(argv[i + 1])]
    profile = os.environ.get('USERPROFILE') or os.environ.get('HOME')
    local = os.environ.get('LOCALAPPDATA')
    candidates = []
    if local:
        candidates.append(Path(local) / 'BeamNG' / 'BeamNG.drive' / 'current')
    if profile:
        candidates.extend([
            Path(profile) / 'Documents' / 'BeamNG.drive',
            Path(profile) / 'OneDrive' / '文档' / 'BeamNG.drive',
            Path(profile) / 'OneDrive' / 'Documents' / 'BeamNG.drive',
            Path(profile) / 'BeamNG.drive',
        ])
    return candidates


def locate_userfolder(candidates):
    """返回第一个已存在的候选；都不存在返回 None。"""
    for c in candidates:
        if c.is_dir():
            return c
    return None


def jsonl_to_record(raw, map_track):
    """JSONL 行 → data.json 记录；返回 None 表示跳过。"""
    try:
        track = raw.get('track') or {}
        vehicle = raw.get('vehicle') or {}
        result = raw.get('result') or {}
        meta = raw.get('meta') or {}

        level_id = str(track.get('id') or '').strip()
        if not level_id:
            return None
        display = track.get('levelDisplay') or level_id
        track_name = map_track.get(level_id) or display

        layout = (track.get('layoutName') or track.get('layoutKey') or '').strip()
        time_str = str(result.get('lapTimeFormatted') or '').strip()
        car = str(vehicle.get('name') or '').strip()
        power = vehicle.get('powerHp')
        if not car or not time_str or not layout:
            return None

        rec = {
            'car': car,
            'track': track_name,
            'layout': layout,
            'time': time_str,
            'power_type': str(vehicle.get('powerType') or '油车').strip() or '油车',
            'game_version': str(meta.get('gameVersion') or '').strip(),
            'control_type': DEFAULT_CONTROL_TYPE,
            'drivetrain': str(vehicle.get('drivetrain') or '').strip(),
            'power': int(power) if isinstance(power, (int, float)) and power > 0 else None,
            'date': str(meta.get('date') or '').strip(),
            'mod': '是' if vehicle.get('isMod') else '否',
        }
        return rec
    except Exception:
        return None


def poll_loop(candidates, stop_event):
    """轮询 records.jsonl，新行入库；offset 持久化防重复。
    用户目录尚未创建（游戏未首次启动）时持续等待，出现后自动生效。"""
    userfolder = locate_userfolder(candidates)
    if userfolder is None:
        sys.stderr.write('[lapBridge] 未找到 BeamNG 用户目录（首次运行游戏后会自动创建），'
                         '监听器将在目录出现后自动生效；也可用 --userfolder <路径> 指定\n')
    jsonl_path = None
    offset = 0
    try:
        offset = int(OFFSET_FILE.read_text().strip() or 0)
    except (OSError, ValueError):
        offset = 0

    while not stop_event.is_set():
        try:
            if userfolder is None:
                userfolder = locate_userfolder(candidates)
                if userfolder is None:
                    stop_event.wait(2.0)
                    continue
                jsonl_path = None
                sys.stderr.write('[lapBridge] 已检测到用户目录 %s，开始监听\n' % userfolder)

            if jsonl_path is None:
                bridge_dir = userfolder / 'beamng_lap_bridge'
                jsonl_path = bridge_dir / 'records.jsonl'
                if not bridge_dir.exists():
                    bridge_dir.mkdir(parents=True, exist_ok=True)
                if not jsonl_path.exists():
                    jsonl_path.write_text('', encoding='utf-8')
                sys.stderr.write('[lapBridge] 监听 %s\n' % jsonl_path)

            try:
                size = jsonl_path.stat().st_size
            except OSError:
                stop_event.wait(1.0)
                continue
            if size > offset:
                # 二进制读取 + 容错解码：坏行会被 json.loads 拒绝并跳过，offset 始终推进
                with open(jsonl_path, 'rb') as f:
                    f.seek(offset)
                    new_bytes = f.read()
                offset = jsonl_path.stat().st_size
                OFFSET_FILE.write_text(str(offset), encoding='utf-8')
                new_lines = new_bytes.decode('utf-8', errors='replace')
                for line in new_lines.splitlines():
                    line = line.strip().lstrip('\ufeff')  # 防御记事本等写入的 BOM
                    if not line:
                        continue
                    try:
                        raw = json.loads(line)
                    except ValueError:
                        sys.stderr.write('[lapBridge] 忽略无法解析的行: %.120s\n' % line)
                        continue
                    rec = jsonl_to_record(raw, track_map())
                    if rec is None:
                        sys.stderr.write('[lapBridge] 跳过无效记录: %.160s\n' % line)
                        continue
                    # 待确认的赛道进入队列（不阻塞入库）
                    level_id = str((raw.get('track') or {}).get('id') or '')
                    if level_id and level_id not in track_map():
                        pending = pending_tracks()
                        pending.setdefault(level_id, {
                            'display': (raw.get('track') or {}).get('levelDisplay') or level_id,
                            'firstSeen': raw.get('ts') or int(time.time()),
                            'count': 0,
                        })
                        pending[level_id]['count'] += 1
                        save_json(PENDING_FILE, pending)
                    ok, msg = append_record(rec, strict=False)
                    sys.stderr.write('[lapBridge] %s: %s (%s)\n' % ('OK' if ok else 'SKIP', msg, rec.get('car')))
        except Exception as e:
            sys.stderr.write('[lapBridge] 轮询异常: %s\n' % e)
        stop_event.wait(1.0)


# ---------- HTTP 处理 ----------

class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, path):
        target = (ROOT / path.lstrip('/')).resolve()
        if not str(target).startswith(str(ROOT)):
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
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self):
        length = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(length).decode('utf-8'))

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/':
            return self._serve_static('/index.html')
        if path == '/api/pending_tracks':
            return self._send_json(200, {'ok': True, 'pending': pending_tracks()})
        self._serve_static(path)

    def do_POST(self):
        path = self.path.split('?')[0]
        if path == '/api/records':
            try:
                rec = self._read_json_body()
            except Exception:
                return self._send_json(400, {'ok': False, 'error': '请求体不是合法 JSON'})
            try:
                ok, msg = append_record(rec)
            except Exception as e:
                return self._send_json(500, {'ok': False, 'error': '写入失败: %s' % e})
            return self._send_json(201 if ok else 409, {'ok': ok, 'error': None if ok else msg, 'message': msg})

        if path == '/api/pending_tracks':
            try:
                body = self._read_json_body()
            except Exception:
                return self._send_json(400, {'ok': False, 'error': '请求体不是合法 JSON'})
            level_id = str(body.get('levelId') or '').strip()
            name = str(body.get('name') or '').strip()
            if not level_id or not name:
                return self._send_json(400, {'ok': False, 'error': 'levelId 与 name 必填'})
            mapping = track_map()
            mapping[level_id] = name
            save_json(TRACK_MAP_FILE, mapping)
            pending = pending_tracks()
            pending.pop(level_id, None)
            save_json(PENDING_FILE, pending)
            return self._send_json(200, {'ok': True})

        self._send_json(404, {'ok': False, 'error': '接口不存在'})

    def log_message(self, fmt, *args):
        sys.stderr.write('[%s] %s\n' % (self.log_date_time_string(), fmt % args))


def main():
    argv = sys.argv[1:]
    port = 8000
    rest = []
    for arg in argv:
        if arg.isdigit():
            port = int(arg)
        else:
            rest.append(arg)

    userfolder_candidates = default_userfolder_candidates(rest)
    if not userfolder_candidates:
        sys.stderr.write('[lapBridge] 无法确定用户目录候选，可加参数 --userfolder <路径> 指定\n')

    server = ThreadingHTTPServer(('0.0.0.0', port), Handler)
    stop_event = threading.Event()
    threading.Thread(target=poll_loop, args=(userfolder_candidates, stop_event), daemon=True).start()

    print('圈速榜本地服务器已启动: http://localhost:%d （Ctrl+C 停止）' % port)
    if userfolder_candidates:
        print('游戏自动录入: 等待 BeamNG 用户目录（默认 %s\\Documents\\BeamNG.drive）' % os.environ.get('USERPROFILE', ''))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.server_close()


if __name__ == '__main__':
    main()
