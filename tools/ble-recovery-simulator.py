"""Real Windows GATT recovery lab; keeps commands until an iPhone execution ACK."""
import argparse
import asyncio
import json
from pathlib import Path
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'agent-relay-ios-shell-builds' / 'ble-simulator-deps'))
from winrt.windows.devices.bluetooth import BluetoothAdapter, BluetoothError
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattServiceProvider, GattServiceProviderAdvertisingParameters,
    GattLocalCharacteristicParameters, GattCharacteristicProperties, GattProtectionLevel)
from winrt.windows.storage.streams import DataReader, DataWriter
from ble_command_queue import CommandQueue, START, STOP, decode

SERVICE = UUID('a8d70200-6b44-4e93-a2d5-73f2a34b8180')
EVENT = UUID('a8d70201-6b44-4e93-a2d5-73f2a34b8180')
ACK = UUID('a8d70202-6b44-4e93-a2d5-73f2a34b8180')
IDENTITY = UUID('a8d70203-6b44-4e93-a2d5-73f2a34b8180')
TOKEN = secrets.token_hex(24)
parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=8767)
parser.add_argument('--state-file', type=Path, default=Path(__file__).resolve().parents[2] / 'agent-relay-ios-shell-builds' / 'ble-recovery-state.json')
args = parser.parse_args()
queue = CommandQueue(args.state_file)
loop = characteristic = provider = stop_event = options = None
state = {'advertising': 'starting', 'subscribers': 0, 'last': '等待手机订阅', 'last_notify': None}
last_notify_at = 0
last_press = 0


def log(message):
    print(time.strftime('%H:%M:%S'), message, flush=True)


def buffer(data):
    writer = DataWriter()
    writer.write_bytes(data)
    return writer.detach_buffer()


async def notify(packet=None):
    global last_notify_at
    state['subscribers'] = len(characteristic.subscribed_clients)
    packet = packet if packet is not None else queue.head()
    if not packet or not state['subscribers']:
        return
    results = await characteristic.notify_value_async(buffer(packet))
    last_notify_at = time.monotonic()
    state['last_notify'] = {'sequence': decode(packet)['sequence'], 'transport': [str(x.status) for x in results]}
    log('已调用 GATT 通知；执行结果以手机 ACK 为准 ' + str(state['last_notify']))


async def snapshot():
    result = queue.snapshot()
    state['subscribers'] = len(characteristic.subscribed_clients)
    result.update(state)
    for key in ('pending', 'history'):
        result[key] = [dict(item, **decode(bytes.fromhex(item['packet']))) for item in result[key]]
    for item in result['history']:
        item['result'] = {1: '已执行', 2: '执行失败', 3: '已过期'}.get(item['status'], '未知')
    return result


async def action(path):
    global last_press
    if path in ('/start', '/finish'):
        if time.monotonic() - last_press < .5:
            raise ValueError('请勿快速重复点击')
        packet = queue.enqueue(START if path == '/start' else STOP)
        last_press = time.monotonic()
        state['last'] = '命令已持久保存，等待手机执行确认；未连接时也不会丢弃'
        log(state['last'] + ' seq=' + str(decode(packet)['sequence']))
        await notify()
    elif path == '/replay':
        packet = queue.head().hex() or queue.data['last_packet']
        if not packet:
            raise ValueError('还没有可重发的命令')
        await notify(bytes.fromhex(packet))
        state['last'] = '重发原编号，用于验证去重；不创建新命令'
    elif path == '/advertising/off':
        provider.stop_advertising()
        state['last'] = '已暂停广播；此操作不保证断开现有连接'
    elif path == '/advertising/on':
        if int(provider.advertisement_status) != 2:
            provider.start_advertising(options)
        state['last'] = '已恢复广播，等待系统恢复连接'
    elif path == '/stop-server':
        stop_event.set()
    else:
        raise ValueError('unknown action')
    return await snapshot()


HTML = '''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent Relay 蓝牙恢复测试</title><style>body{font:17px system-ui;max-width:850px;margin:30px auto;padding:16px;background:#f5f7fa}button{font:inherit;padding:16px;margin:5px;border:0;border-radius:10px;background:#1765db;color:white}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}small{display:block;margin:12px 0}</style>
<h1>蓝牙恢复测试</h1><p>只连接手机测试版中的「恢复测试按钮」。无需提前建立语音会话。</p>
<h2 id="connection">读取状态中</h2><button onclick="send('/start')">开始录音</button><button onclick="send('/finish')">结束并发送</button>
<button onclick="send('/replay')">重发上条原编号（去重测试）</button>
<small>断线时命令保存最多120秒。收到不等于执行；只有手机执行确认才出队。停止确认表示已停止且上传已排队，服务端成功以手机 HTTP accepted 日志为准。</small>
<details><summary>广播控制</summary><button onclick="send('/advertising/off')">暂停广播</button><button onclick="send('/advertising/on')">恢复广播</button><p>暂停广播不保证断开已有连接。真实断链测试使用手机测试页的“断链15秒”。</p></details>
<pre id="status"></pre><p id="error" style="color:#b00"></p><button onclick="send('/stop-server')">停止测试模拟器</button>
<script>const token='TOKEN';let busy=false;async function poll(){try{let s=await(await fetch('/status')).json();document.querySelector('#connection').textContent=s.subscribers?'手机已订阅；待发 '+s.pending.length+' 条':'手机未订阅；已缓存 '+s.pending.length+' 条';document.querySelector('#status').textContent=JSON.stringify(s,null,2)}catch(e){document.querySelector('#connection').textContent='模拟器未运行'}}async function send(path){if(busy)return;busy=true;try{let r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});let s=await r.json();document.querySelector('#error').textContent=r.ok?'':s.error}catch(e){document.querySelector('#error').textContent=e.message}finally{busy=false;await poll()}}setInterval(poll,1000);poll();</script>'''.replace('TOKEN', TOKEN)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def respond(self, value, code=200):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(HTML.encode())
        elif self.path == '/status':
            self.respond(asyncio.run_coroutine_threadsafe(snapshot(), loop).result(5))
        else:
            self.respond({'error': 'not found'}, 404)

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length < 1024:
                raise ValueError('invalid request')
            body = json.loads(self.rfile.read(length))
            if not secrets.compare_digest(str(body.get('token', '')), TOKEN):
                self.respond({'error': 'forbidden'}, 403)
                return
            if self.path == '/stop-server':
                self.respond({'message': '正在停止，已保存命令队列'})
                loop.call_soon_threadsafe(stop_event.set)
                return
            future = asyncio.run_coroutine_threadsafe(action(self.path), loop)
            self.respond(future.result(5))
        except Exception as error:
            self.respond({'error': str(error)}, 400)


async def handle_read(event, deferral, supplier):
    try:
        request = await event.get_request_async()
        if request:
            request.respond_with_value(buffer(supplier()[request.offset:]))
    except Exception as error:
        log('READ error: ' + str(error))
    finally:
        deferral.complete()


async def handle_write(event, deferral):
    global last_notify_at
    try:
        request = await event.get_request_async()
        if request:
            try:
                data = bytearray(request.value.length)
                DataReader.from_buffer(request.value).read_bytes(data)
                if request.offset:
                    raise ValueError('unsupported offset')
                result = queue.acknowledge(bytes(data))
                state['last'] = '手机 ACK: ' + result + ' seq=' + str(decode(bytes(data[:16]))['sequence']) + ' status=' + str(data[-1])
                log(state['last'])
                request.respond()
                if result == 'terminal':
                    last_notify_at = 0
            except Exception as error:
                log('ACK rejected: ' + str(error))
                request.respond_with_protocol_error(0x0e)
    finally:
        deferral.complete()


async def main():
    global loop, characteristic, provider, options, stop_event
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    adapter = await BluetoothAdapter.get_default_async()
    if not adapter or not adapter.is_peripheral_role_supported:
        raise RuntimeError('蓝牙适配器不支持 BLE 外设模式')
    result = await GattServiceProvider.create_async(SERVICE)
    if result.error != BluetoothError.SUCCESS:
        raise RuntimeError('创建服务失败: ' + str(result.error))
    provider = result.service_provider
    async def create(uuid, properties):
        parameters = GattLocalCharacteristicParameters()
        parameters.characteristic_properties = properties
        parameters.read_protection_level = GattProtectionLevel.PLAIN
        parameters.write_protection_level = GattProtectionLevel.PLAIN
        result = await provider.service.create_characteristic_async(uuid, parameters)
        if result.error != BluetoothError.SUCCESS:
            raise RuntimeError('创建特征失败: ' + str(result.error))
        return result.characteristic
    characteristic = await create(EVENT, GattCharacteristicProperties.READ | GattCharacteristicProperties.NOTIFY)
    ack = await create(ACK, GattCharacteristicProperties.WRITE)
    identity = await create(IDENTITY, GattCharacteristicProperties.READ)
    def read(supplier):
        def callback(sender, event):
            deferral = event.get_deferral()
            loop.call_soon_threadsafe(lambda: asyncio.create_task(handle_read(event, deferral, supplier)))
        return callback
    def written(sender, event):
        deferral = event.get_deferral()
        loop.call_soon_threadsafe(lambda: asyncio.create_task(handle_write(event, deferral)))
    def subscribed(sender, event):
        def update():
            global last_notify_at
            state['subscribers'] = len(sender.subscribed_clients)
            last_notify_at = 0
            log('手机订阅数: ' + str(state['subscribers']))
        loop.call_soon_threadsafe(update)
    def advertising(sender, event):
        state['advertising'] = str(event.status)
        log('广播状态: ' + str(event.status) + ' error=' + str(event.error))
    characteristic.add_read_requested(read(queue.head))
    identity.add_read_requested(read(lambda: UUID(queue.data['device_id']).bytes))
    ack.add_write_requested(written)
    characteristic.add_subscribed_clients_changed(subscribed)
    provider.add_advertisement_status_changed(advertising)
    options = GattServiceProviderAdvertisingParameters()
    options.is_connectable = True
    options.is_discoverable = True
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    provider.start_advertising(options)
    log(f'控制页 http://127.0.0.1:{args.port}/ ; device={queue.data["device_id"]} ; 状态={args.state_file}')
    try:
        while not stop_event.is_set():
            if time.monotonic() - last_notify_at >= 2:
                await notify()
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=.5)
            except asyncio.TimeoutError:
                pass
    finally:
        provider.stop_advertising()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    asyncio.run(main())
