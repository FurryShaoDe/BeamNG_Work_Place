#!/usr/bin/env python3
"""BeamNG 圈速榜本地服务器：静态文件服务 + 成绩录入接口。

本地录入成绩用（线上 GitHub Pages 只读展示，无需本服务器）：

    python server.py [端口]      # 默认 8000

POST /api/records 接收一条成绩记录，校验后追加写入 data.json，
格式与现有数据完全一致（ensure_ascii=False + 2 空格缩进）。
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA_FILE = ROOT / 'data.json'

TIME_RE = re.compile(r'^\d{1,2}:\d{2}\.\d{3}$')
REQUIRED_FIELDS = [
    'car', 'track', 'layout', 'time', 'power_type',
    'game_version', 'control_type', 'drivetrain', 'power', 'date', 'mod',
]

CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.css': 'text/css; charset=utf-8',
    '.ico': 'image/x-icon',
}


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


def validate_record(rec):
    """返回错误列表；空列表表示通过。"""
    errors = []
    for field in REQUIRED_FIELDS:
        value = rec.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append('缺少字段: %s' % field)
    if errors:
        return errors
    if not TIME_RE.match(str(rec['time'])):
        errors.append('时间格式应为 MM:SS.mmm（如 01:15.856）')
    if not isinstance(rec['power'], int) or rec['power'] <= 0:
        errors.append('马力应为正整数')
    return errors


class Handler(BaseHTTPRequestHandler):
    # ---------- 工具 ----------

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, path):
        # 防目录穿越：解析后必须仍在站点根目录内
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

    # ---------- 路由 ----------

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/':
            path = '/index.html'
        self._serve_static(path)

    def do_POST(self):
        path = self.path.split('?')[0]
        if path != '/api/records':
            self._send_json(404, {'ok': False, 'error': '接口不存在'})
            return

        try:
            length = int(self.headers.get('Content-Length', 0))
            rec = json.loads(self.rfile.read(length).decode('utf-8'))
        except Exception:
            self._send_json(400, {'ok': False, 'error': '请求体不是合法 JSON'})
            return

        errors = validate_record(rec)
        if errors:
            self._send_json(400, {'ok': False, 'error': '；'.join(errors)})
            return

        try:
            records = load_records()
            records.append(rec)
            save_records(records)
        except Exception as e:
            self._send_json(500, {'ok': False, 'error': '写入失败: %s' % e})
            return

        self._send_json(201, {'ok': True, 'count': len(records)})

    def log_message(self, fmt, *args):
        sys.stderr.write('[%s] %s\n' % (self.log_date_time_string(), fmt % args))


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    server = ThreadingHTTPServer(('0.0.0.0', port), Handler)
    print('圈速榜本地服务器已启动: http://localhost:%d （Ctrl+C 停止）' % port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n已停止')
