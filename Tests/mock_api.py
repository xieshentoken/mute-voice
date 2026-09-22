"""Loopback-only contract fixtures; no real credentials, speakers, or meeting audio."""
import base64
import hashlib
import json
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

PCM = b"\x00\x00\xff\x7f\x00\x80\xff\xff"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_event(self, event):
        payload = json.dumps(event).encode()
        header = bytes([0x81])
        if len(payload) < 126:
            header += bytes([len(payload)])
        else:
            header += b"\x7e" + struct.pack("!H", len(payload))
        self.wfile.write(header + payload)
        self.wfile.flush()

    def read_event(self):
        while True:
            header = self.rfile.read(2)
            if len(header) != 2 or header[0] & 15 == 8:
                raise EOFError()
            size = header[1] & 127
            if size == 126:
                size = struct.unpack("!H", self.rfile.read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.rfile.read(8))[0]
            assert size < 4 * 1024 * 1024
            mask = self.rfile.read(4) if header[1] & 128 else None
            data = self.rfile.read(size)
            if mask:
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            if header[0] & 15 == 1:
                return json.loads(data)

    def expect(self, kind):
        event = self.read_event()
        assert event.get("type", event.get("event")) == kind, (kind, event)
        return event

    def expect_voice(self, actual):
        # Live rejects query parameters, so encode fixture expectations in the path.
        _, marker, expected = urlsplit(self.path).path.partition("/voice/")
        if marker:
            assert actual == unquote(expected), (unquote(expected), actual)

    def do_GET(self):
        path = urlsplit(self.path).path.partition("/voice/")[0]
        assert self.headers.get("Authorization") == "Bearer fixture-key"
        accept = base64.b64encode(hashlib.sha1(
            (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        try:
            if path.startswith("/qwen"):
                assert "model=qwen3-tts-flash-realtime" in self.path
                self.send_event({"type": "session.created"})
                config = self.expect("session.update")["session"]
                self.expect_voice(config["voice"])
                assert config["mode"] == "commit" and config["response_format"] == "pcm"
                assert config["sample_rate"] == 24000
                self.send_event({"type": "session.updated"})
                assert self.expect("input_text_buffer.append")["text"] == "你好，测试。"
                self.expect("input_text_buffer.commit")
                if path == "/qwen-stall":
                    self.rfile.read(1)
                    return
                for chunk in [PCM[:1], PCM[1:4], PCM[4:]]:
                    self.send_event({"type": "response.audio.delta", "delta": base64.b64encode(chunk).decode()})
                    time.sleep(0.05)
                self.send_event({"type": "response.audio.done"})
                self.expect("session.finish")
                self.send_event({"type": "session.finished"})
            elif path == "/minimax":
                self.send_event({"event": "connected_success"})
                task = self.expect("task_start")
                self.expect_voice(task["voice_setting"]["voice_id"])
                assert task["model"] == "speech-2.8-turbo"
                assert task["audio_setting"] == {"sample_rate": 24000, "format": "pcm", "channel": 1}
                self.send_event({"event": "task_started"})
                assert self.expect("task_continue")["text"] == "你好，测试。"
                self.send_event({"event": "task_continued", "data": {"audio": PCM[:3].hex()}, "is_final": False})
                time.sleep(0.1)
                self.send_event({"event": "task_continued", "data": {"audio": PCM[3:].hex()}, "is_final": True})
                self.expect("task_finish")
                self.send_event({"event": "task_finished", "base_resp": {"status_code": 0}})
            elif path == "/live":
                config = self.expect("session.start")["session"]
                self.expect_voice(config["audio"]["output"]["voice"])
                assert config["model"] == "gpt-live-1"
                assert config["audio"]["format"] == {"type": "audio/pcm", "rate": 24000}
                assert config["delegation"] == {"type": "client"}
                self.send_event({"type": "session.started", "session": {"id": "fixture-live"}})
                instruction = self.expect("session.instructions.append")
                assert "你好，测试。" in instruction["content"]
                self.send_event({"type": "session.instructions.appended", "client_event_id": instruction["event_id"]})
                silence = self.expect("session.input_audio.append")
                assert base64.b64decode(silence["audio"]) == bytes(960)
                self.send_event({"type": "session.output_audio.delta", "delta": base64.b64encode(PCM).decode()})
                self.send_event({"type": "session.closed"})
        except EOFError:
            pass
        except (ConnectionError, BrokenPipeError):
            pass
        except Exception as error:
            self.send_event({"type": "error", "error": {"message": str(error)}})
        finally:
            self.close_connection = True

    def do_POST(self):
        path = urlsplit(self.path).path.partition("/voice/")[0]
        if path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "http://127.0.0.1:1/must-not-receive-credentials")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.expect_voice(body["req_params"]["speaker"])
        if path == "/doubao-legacy":
            assert self.headers.get("X-Api-App-Id") == "fixture-app"
            assert self.headers.get("X-Api-Access-Key") == "fixture-key"
        else:
            assert self.headers.get("X-Api-Key") == "fixture-key"
        assert self.headers.get("X-Api-Resource-Id") == "seed-tts-2.0"
        assert body["req_params"]["audio_params"] == {"format": "pcm", "sample_rate": 24000}
        assert body["req_params"]["text"] == "你好，测试。"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        if path == "/doubao-error":
            frames = [("153", {"code": 55000000, "message": "invalid fixture-key"})]
        else:
            frames = [("352", {"code": 0, "data": base64.b64encode(PCM[:3]).decode()}),
                      ("352", {"code": 0, "data": base64.b64encode(PCM[3:]).decode()})]
            if path != "/doubao-truncated":
                frames.append(("152", {"code": 20000000, "data": ""}))
        for kind, data in frames:
            record = f": heartbeat\r\nevent: {kind}\r\ndata: {json.dumps(data)}\r\n\r\n".encode()
            for i in range(0, len(record), 7):
                self.wfile.write(record[i:i + 7])
                self.wfile.flush()
            time.sleep(0.05)
        self.close_connection = True


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
