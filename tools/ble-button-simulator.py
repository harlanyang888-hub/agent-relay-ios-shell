"""Windows BLE peripheral for Agent Relay. Run with Python 3.12 + PyWinRT."""
import asyncio
import json
import os
from pathlib import Path
import secrets
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import UUID

deps = Path(__file__).resolve().parents[2] / 'agent-relay-ios-shell-builds' / 'ble-simulator-deps'
sys.path.insert(0, str(deps))
from winrt.windows.devices.bluetooth import BluetoothAdapter, BluetoothError
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattServiceProvider, GattServiceProviderAdvertisingParameters,
    GattLocalCharacteristicParameters, GattCharacteristicProperties, GattProtectionLevel)
from winrt.windows.storage.streams import DataWriter

SERVICE = UUID('a8d70100-6b44-4e93-a2d5-73f2a34b8180')
EVENT = UUID('a8d70101-6b44-4e93-a2d5-73f2a34b8180')
TOKEN = secrets.token_hex(24)
state = {'advertising': 'starting', 'subscribers': 0, 'sequence': 0, 'last': '尚未发送'}
loop = None
characteristic = None
stop_event = None
last_press = 0
nonce = secrets.token_bytes(4)

def log(message):
    print(time.strftime('%H:%M:%S'), message, flush=True)

async def press():
    global last_press
    count = len(characteristic.subscribed_clients)
    state['subscribers'] = count
    if count == 0:
        state['last'] = '手机未连接／未订阅，本次没有发送。请在 iPhone 设备测试页连接 RN12108（电脑按钮）。'
        raise ValueError('没有手机订阅，未发送。请在 Agent Relay 设备测试页连接电脑按钮。')
    if time.monotonic() - last_press < 0.8:
        raise ValueError('点击过快，请稍后再按')
    last_press = time.monotonic()
    state['sequence'] += 1
    packet = b'AR\x01\x01' + nonce + struct.pack('<I', state['sequence'])
    writer = DataWriter()
    writer.write_bytes(packet)
    results = await characteristic.notify_value_async(writer.detach_buffer())
    statuses = [str(item.status) for item in results]
    state['last'] = f"已调用蓝牙发送 seq={state['sequence']}，状态={statuses}；手机是否执行以 App 日志为准"
    log(state['last'])
    return dict(state)

HTML = '''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent Relay 电脑蓝牙按钮</title>
<style>body{font:18px system-ui;max-width:680px;margin:60px auto;padding:20px;background:#f5f7fa;color:#202632}button{font:inherit;padding:22px;border-radius:12px;cursor:pointer;background:#1765db;color:white;border:0}pre{white-space:pre-wrap;line-height:1.7}</style>
<h1>电脑 BLE 测试按钮</h1><p>先在 iPhone 设备测试页连接「Agent Relay 电脑按钮」，再进入语音验证建立会话。录音时按下停止并发送，暂停时按下恢复录音。</p>
<h2 id="connection">正在检查连接</h2><button id="press" disabled onclick="send('/press')">按一下：开始／停止录音</button><pre id="status"></pre>
<p>没有订阅时不会发送。电脑仅发送蓝牙事件，不使用媒体键；实际录音结果请看手机日志。</p>
<button onclick="send('/stop')">停止模拟器并关闭广播</button>
<script>const token='TOKEN';let busy=false;function display(s){let ready=s.subscribers>0;document.querySelector('#connection').textContent=ready?'手机已订阅；录音会话是否就绪请看手机':'手机未连接／未订阅：请在 App 设备测试页连接 RN12108';document.querySelector('#connection').style.color=ready?'green':'#ba2020';document.querySelector('#press').disabled=!ready||busy;document.querySelector('#status').textContent=JSON.stringify(s,null,2)}async function send(path){if(busy)return;busy=true;document.querySelector('#press').disabled=true;try{let r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});document.querySelector('#status').textContent=JSON.stringify(await r.json(),null,2)}catch(e){document.querySelector('#status').textContent=e.message}finally{busy=false;await poll()}}async function poll(){if(busy)return;try{let r=await fetch('/status');display(await r.json())}catch(e){document.querySelector('#connection').textContent='模拟器已停止或无法连接';document.querySelector('#press').disabled=true}}setInterval(poll,2000);poll();</script>'''.replace('TOKEN', TOKEN)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, value, code=200):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store'); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path == '/status': self.respond(state); return
        if self.path != '/': self.respond({'error':'not found'},404); return
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(HTML.encode())
    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length','0'))
            if not 0 < length < 1024: raise ValueError('invalid request')
            body = json.loads(self.rfile.read(length))
            if not secrets.compare_digest(str(body.get('token','')),TOKEN): self.respond({'error':'forbidden'},403); return
            if self.path == '/stop':
                self.respond({'message':'正在停止广播'})
                loop.call_soon_threadsafe(stop_event.set); return
            if self.path != '/press': self.respond({'error':'not found'},404); return
            future = asyncio.run_coroutine_threadsafe(press(),loop)
            try: self.respond(future.result(timeout=5))
            except TimeoutError: future.cancel(); raise ValueError('蓝牙发送超时，请检查手机日志再重试')
        except Exception as e: self.respond({'error':str(e)},400)

async def main():
    global loop, characteristic, stop_event
    loop=asyncio.get_running_loop(); stop_event=asyncio.Event()
    adapter=await BluetoothAdapter.get_default_async()
    if not adapter or not adapter.is_peripheral_role_supported: raise RuntimeError('蓝牙适配器不支持 BLE 外设模式')
    result=await GattServiceProvider.create_async(SERVICE)
    if result.error != BluetoothError.SUCCESS: raise RuntimeError(f'创建服务失败: {result.error}')
    provider=result.service_provider
    params=GattLocalCharacteristicParameters()
    params.characteristic_properties=GattCharacteristicProperties.NOTIFY
    params.read_protection_level=GattProtectionLevel.PLAIN
    params.write_protection_level=GattProtectionLevel.PLAIN
    result=await provider.service.create_characteristic_async(EVENT,params)
    if result.error != BluetoothError.SUCCESS: raise RuntimeError(f'创建特征失败: {result.error}')
    characteristic=result.characteristic
    def subscribed(sender,args):
        state['subscribers']=len(sender.subscribed_clients);log(f"手机订阅数: {state['subscribers']}")
        state['last'] = '手机已订阅，等待按键；请确认手机语音会话已建立' if state['subscribers'] else '手机订阅已断开，请重新连接；没有新的按钮事件发送'
    def advertising(sender,args):
        state['advertising']=str(args.status);log(f'广播状态: {args.status}, error={args.error}')
    characteristic.add_subscribed_clients_changed(subscribed)
    provider.add_advertisement_status_changed(advertising)
    options=GattServiceProviderAdvertisingParameters();options.is_connectable=True;options.is_discoverable=True
    server=ThreadingHTTPServer(('127.0.0.1',8766),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    provider.start_advertising(options)
    log('本地控制页 http://127.0.0.1:8766/ ; service='+str(SERVICE))
    try: await stop_event.wait()
    finally:
        provider.stop_advertising();server.shutdown();server.server_close();log('模拟器已停止')

if __name__=='__main__':
    try: asyncio.run(main())
    except KeyboardInterrupt: pass
    except Exception as e: log(f'失败: {e}');raise
