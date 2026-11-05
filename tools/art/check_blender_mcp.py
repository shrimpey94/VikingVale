"""Read-only MCP initialize/tools-list/scene-info smoke test; no scene changes."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

root = Path(__file__).resolve().parents[2]
local = root / '.tools' / 'blender_mcp'
env = dict(os.environ)
env.update(UV_CACHE_DIR=str(local / 'cache'), UV_PYTHON_INSTALL_DIR=str(local / 'python'),
           TEMP=str(local / 'tmp'), TMP=str(local / 'tmp'),
           APPDATA=str(local / 'appdata'), BLENDER_MCP_DISABLE_TELEMETRY='true')
proc = subprocess.Popen([str(local / 'uv' / 'bin' / 'uvx.exe'), 'mcp-for-blender@2.2.4'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, encoding='utf-8', env=env,
                        creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
messages = queue.Queue()
errors = []
def read_stdout():
    for line in proc.stdout:
        try:
            messages.put(json.loads(line))
        except json.JSONDecodeError:
            pass
def read_stderr():
    for line in proc.stderr:
        errors.append(line.rstrip())
threading.Thread(target=read_stdout, daemon=True).start()
threading.Thread(target=read_stderr, daemon=True).start()
def send(message):
    proc.stdin.write(json.dumps({'jsonrpc': '2.0', **message}) + '\n')
    proc.stdin.flush()
def response(identifier, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        message = messages.get(timeout=max(.1, deadline-time.monotonic()))
        if message.get('id') == identifier:
            return message
    raise TimeoutError(identifier)
report = {}
try:
    send({'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05',
          'capabilities': {}, 'clientInfo': {'name': 'VikingVale-readonly-check', 'version': '1'}}})
    report['initialize'] = response(1)
    send({'method': 'notifications/initialized'})
    send({'id': 2, 'method': 'tools/list', 'params': {}})
    tools = response(2).get('result', {}).get('tools', [])
    report['tools'] = [tool['name'] for tool in tools]
    if 'get_scene_info' in report['tools']:
        send({'id': 3, 'method': 'tools/call', 'params': {'name': 'get_scene_info', 'arguments': {}}})
        report['scene_info'] = response(3)
finally:
    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=5)
    report['stderr_tail'] = errors[-12:]
    destination = root / 'art_source/previews/stone_pickup/v001/blender_mcp_check.json'
    destination.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report, indent=2))
