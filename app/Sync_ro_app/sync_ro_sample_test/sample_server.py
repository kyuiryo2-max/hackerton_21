"""Sync_ro offline sample route API. No external API calls or credentials."""
import json
import math
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DATA = json.loads((Path(__file__).parent / 'samples' / 'kakao_publictraffic.json').read_text(encoding='utf-8'))
TYPE = {'WALKING': 'walking', 'BUS': 'bus', 'SUBWAY': 'subway'}

def convert():
    result = []
    for i, route in enumerate(DATA['routes']):
        prop = route['properties']
        segments = []
        for step in route['steps']:
            sp = step['properties']
            kind = TYPE.get(sp.get('type'))
            if not kind:
                continue
            points = step.get('path', {}).get('points', [])
            geometry = [{'latitude': float(p[1]), 'longitude': float(p[0])} for p in points if isinstance(p, list) and len(p) >= 2]
            segments.append({'type': kind, 'description': sp.get('guidance') or {'walking':'도보 이동','bus':'버스 이동','subway':'지하철 이동'}[kind], 'durationMinutes': math.ceil(float(sp.get('time', 0))/60), 'geometry': geometry})
        modes = []
        for s in segments:
            if s['type'] in ('bus','subway') and s['type'] not in modes:
                modes.append(s['type'])
        title = ' + '.join({'bus':'버스','subway':'지하철'}[m] for m in modes) if modes else '도보'
        result.append({'id': f'sample_route_{i+1}', 'title': f'샘플 · {title}', 'transferCount': int(prop.get('transfers',0)), 'isRecommended': i == 0, 'totalDurationMinutes': math.ceil(float(prop['totalTime'])/60), 'segments': segments})
    return {'routes': result, 'sampleMode': True, 'sampleRequestedAt': DATA.get('requested_at'), 'notice': '고정 샘플 데이터입니다. 입력한 출발지/목적지와 무관합니다.'}

class Handler(BaseHTTPRequestHandler):
    def send_json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    def do_GET(self):
        if self.path == '/health':
            self.send_json(200, {'ok':True, 'sampleMode':True, 'routes':len(DATA['routes'])})
        else:
            self.send_json(404, {'error':'Not found'})
    def do_POST(self):
        if self.path != '/api/routes/search':
            return self.send_json(404, {'error':'Not found'})
        try:
            length = int(self.headers.get('Content-Length','0'))
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict) or not all(k in body for k in ('origin','destination','desiredArrivalTime')):
                return self.send_json(400, {'error':'origin, destination, desiredArrivalTime required'})
            return self.send_json(200, convert())
        except (ValueError, TypeError, json.JSONDecodeError) as e:
            return self.send_json(400, {'error':str(e)})

if __name__ == '__main__':
    print('Sync_ro sample API: http://127.0.0.1:8000/health')
    ThreadingHTTPServer(('127.0.0.1',8000), Handler).serve_forever()
