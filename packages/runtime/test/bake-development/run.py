#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import urlopen


TIMEOUT = 20


class WebSocket:
    def __init__(self, host: str, port: int, path: str) -> None:
        self.socket = socket.create_connection((host, port), timeout=TIMEOUT)
        self.socket.settimeout(TIMEOUT)
        self.buffer = bytearray()
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f'GET {path} HTTP/1.1\r\n'
            f'Host: {host}:{port}\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {key}\r\n'
            'Sec-WebSocket-Version: 13\r\n\r\n'
        )
        self.socket.sendall(request.encode())
        response = self._read_until(b'\r\n\r\n')
        headers, remaining = response.split(b'\r\n\r\n', 1)
        self.buffer.extend(remaining)
        if not headers.startswith(b'HTTP/1.1 101 '):
            raise AssertionError(f'WebSocket upgrade failed: {headers!r}')
        expected = base64.b64encode(
            hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()
        )
        if b'sec-websocket-accept: ' + expected.lower() not in headers.lower():
            raise AssertionError('WebSocket upgrade returned an invalid accept key')

    def _read_until(self, delimiter: bytes) -> bytes:
        data = bytearray(self.buffer)
        self.buffer.clear()
        while delimiter not in data:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise EOFError('WebSocket closed during handshake')
            data.extend(chunk)
        return bytes(data)

    def _read_exactly(self, length: int) -> bytes:
        while len(self.buffer) < length:
            chunk = self.socket.recv(max(4096, length - len(self.buffer)))
            if not chunk:
                raise EOFError('WebSocket closed while reading a frame')
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:length])
        del self.buffer[:length]
        return result

    def receive(self) -> tuple[int, bytes]:
        while True:
            first, second = self._read_exactly(2)
            opcode = first & 0x0F
            masked = second & 0x80
            length = second & 0x7F
            if length == 126:
                length = struct.unpack('!H', self._read_exactly(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self._read_exactly(8))[0]
            mask = self._read_exactly(4) if masked else b''
            payload = self._read_exactly(length)
            if mask:
                payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0x8:
                raise EOFError('WebSocket closed before the expected HMR frame')
            return opcode, payload

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = bytes((0x80 | opcode, 0x80 | length))
        elif length < 65536:
            header = bytes((0x80 | opcode, 0x80 | 126)) + struct.pack('!H', length)
        else:
            header = bytes((0x80 | opcode, 0x80 | 127)) + struct.pack('!Q', length)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.socket.sendall(header + mask + masked)

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode())

    def close(self) -> None:
        try:
            self._send_frame(0x8, struct.pack('!H', 1000))
        except OSError:
            pass
        self.socket.close()


def reserve_port() -> int:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def wait_for_server(
    process: subprocess.Popen[bytes], url: str, expected_content_type: str
) -> bytes:
    deadline = time.monotonic() + TIMEOUT
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f'Home exited before serving the fixture (status {process.returncode})')
        try:
            with urlopen(url, timeout=1) as response:
                content_type = response.headers.get_content_type()
                if content_type != expected_content_type:
                    raise AssertionError(
                        f'expected {expected_content_type}, received {content_type}'
                    )
                return response.read()
        except OSError as error:
            last_error = error
            time.sleep(0.05)
    raise AssertionError(f'timed out waiting for Home development server: {last_error}')


def stop_process(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f'usage: {sys.argv[0]} HOME_EXECUTABLE')

    home_exe = Path(sys.argv[1]).resolve()
    fixture = Path(__file__).with_name('fixture')
    temp_root = Path(tempfile.mkdtemp(prefix='home-bake-development.'))
    log_path = temp_root / 'server.log'
    framework_log_path = temp_root / 'framework' / 'server.log'
    process: subprocess.Popen[bytes] | None = None
    websocket: WebSocket | None = None

    try:
        shutil.copytree(fixture, temp_root, dirs_exist_ok=True)
        port = reserve_port()
        server_path = temp_root / 'server.ts'
        server_path.write_text(
            server_path.read_text().replace('__HOME_BAKE_TEST_PORT__', str(port))
        )
        client_path = temp_root / 'client.ts'
        original_client = client_path.read_text()

        with log_path.open('wb') as server_log:
            process = subprocess.Popen(
                [str(home_exe), './server.ts'],
                cwd=temp_root,
                env={**os.environ, 'NO_COLOR': '1'},
                stdout=server_log,
                stderr=subprocess.STDOUT,
            )

            base_url = f'http://127.0.0.1:{port}'
            html = wait_for_server(process, base_url + '/', 'text/html')
            if b'Home Bake development' not in html:
                raise AssertionError('development HTML did not contain the fixture document')

            match = re.search(rb'(/_bun/client/[^"\']+\.js)', html)
            if match is None:
                raise AssertionError('development HTML did not contain a generated client bundle URL')
            with urlopen(base_url + match.group(1).decode(), timeout=TIMEOUT) as response:
                client_bundle = response.read()
            if b'HOME_BAKE_CLIENT_LOADED' not in client_bundle or b'bun:hmr' not in client_bundle:
                raise AssertionError('generated client bundle is missing application or HMR code')

            websocket = WebSocket('127.0.0.1', port, '/_bun/hmr')
            _, version = websocket.receive()
            if len(version) != 17 or version[:1] != b'V':
                raise AssertionError(f'expected 17-byte Bake version frame, received {version!r}')

            websocket.send_text('she')
            websocket.send_text('n/')
            while True:
                _, route_frame = websocket.receive()
                if route_frame[:1] == b'n':
                    break

            marker = f'HOME_BAKE_HMR_{time.time_ns()}'
            client_path.write_text(original_client + f'\nconsole.log({marker!r});\n')

            while True:
                _, update = websocket.receive()
                message_id = update[:1]
                if message_id == b'e':
                    raise AssertionError(f'incremental bundle failed: {update!r}')
                if message_id == b'u':
                    if marker.encode() not in update:
                        raise AssertionError('hot-update frame did not contain the edited module')
                    break

            if process.poll() is not None:
                raise AssertionError(f'Home crashed after the hot update (status {process.returncode})')

            client_path.write_text('export const broken = ;\n')
            while True:
                _, diagnostic = websocket.receive()
                message_id = diagnostic[:1]
                if message_id == b'u':
                    raise AssertionError('invalid source unexpectedly produced a hot-update frame')
                if message_id == b'e':
                    if b'Unexpected' not in diagnostic or b'client.ts' not in diagnostic:
                        raise AssertionError(
                            f'build-error frame did not identify the syntax failure: {diagnostic!r}'
                        )
                    break

            client_path.write_text(original_client)
            while True:
                _, recovery = websocket.receive()
                if recovery[:1] == b'u':
                    break

            if process.poll() is not None:
                raise AssertionError(
                    f'Home crashed after recovering from a build error (status {process.returncode})'
                )

        websocket.close()
        websocket = None
        stop_process(process)
        process = None

        framework_fixture = Path(__file__).with_name('framework-fixture')
        framework_root = temp_root / 'framework'
        shutil.copytree(framework_fixture, framework_root)
        framework_port = reserve_port()
        framework_server_path = framework_root / 'server.ts'
        framework_server_path.write_text(
            framework_server_path.read_text().replace(
                '__HOME_BAKE_TEST_PORT__', str(framework_port)
            )
        )
        with framework_log_path.open('wb') as framework_log:
            process = subprocess.Popen(
                [str(home_exe), './server.ts'],
                cwd=framework_root,
                env={**os.environ, 'NO_COLOR': '1'},
                stdout=framework_log,
                stderr=subprocess.STDOUT,
            )
            framework_url = f'http://127.0.0.1:{framework_port}'
            index_body = wait_for_server(process, framework_url + '/', 'text/plain')
            if index_body != b'HOME_BAKE_FRAMEWORK_INDEX':
                raise AssertionError(f'unexpected framework index response: {index_body!r}')
            with urlopen(framework_url + '/alpha', timeout=TIMEOUT) as response:
                slug_body = response.read()
            if slug_body != b'HOME_BAKE_FRAMEWORK_SLUG:alpha':
                raise AssertionError(f'unexpected framework parameter response: {slug_body!r}')

            try:
                urlopen(framework_url + '/invalid', timeout=TIMEOUT)
            except HTTPError as error:
                invalid_status = error.code
                invalid_content_type = error.headers.get_content_type()
                invalid_body = error.read()
            else:
                raise AssertionError('invalid framework return unexpectedly succeeded')
            if invalid_status != 500 or invalid_content_type != 'text/html':
                raise AssertionError(
                    'invalid framework return did not produce an HTML 500 response: '
                    f'{invalid_status} {invalid_content_type}'
                )
            if b'__bunfallback' not in invalid_body:
                raise AssertionError('invalid framework return did not produce a Bake error page')

        framework_log_text = framework_log_path.read_text(errors='replace')
        if 'Server-side request handler was expected to return a Response object.' not in framework_log_text:
            raise AssertionError('invalid framework return did not report the expected message')
        if 'ERR_SSR_RESPONSE_EXPECTED' not in framework_log_text:
            raise AssertionError('invalid framework return did not report its generated error code')
        if 'ReferenceError: $ERR_SSR_RESPONSE_EXPECTED is not defined' in framework_log_text:
            raise AssertionError('Bake server runtime leaked an unresolved generated error builtin')

        print('Bake development HTML, HMR diagnostics/recovery, framework routing, and response validation passed')
    except Exception:
        for label, path in (
            ('Home development server', log_path),
            ('Home framework server', framework_log_path),
        ):
            if path.exists():
                print(f'\n--- {label} log ---', file=sys.stderr)
                print(path.read_text(errors='replace'), file=sys.stderr)
        raise
    finally:
        if websocket is not None:
            websocket.close()
        stop_process(process)
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == '__main__':
    main()
