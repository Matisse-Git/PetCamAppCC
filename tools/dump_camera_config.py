"""Read-only settings check for the pet camera (Xiongmai DVRIP, port 34567).

It logs in, READS the camera's info and settings, and saves them to
tools/camera_config_dump.json. It never changes anything on the camera.

Usage (on a PC on the home network, or connected through Tailscale):
    python tools/dump_camera_config.py              # camera at 192.168.1.2
    python tools/dump_camera_config.py 192.168.1.7  # another address

You'll be asked for the username (Enter = admin) and the device password.
The password is only sent to the camera, hashed, and is never written to disk.
"""
import getpass
import hashlib
import json
import os
import socket
import struct
import sys

PORT = 34567
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

# Everything we try to read. Missing ones are fine: they show what the camera doesn't support.
QUERIES = [
    ("SystemInfo", 1020),
    ("SystemFunction", 1360),
    ("StorageInfo", 1020),
    ("General.General", 1042),
    ("Camera.Param.[0]", 1042),
    ("Camera.ParamEx.[0]", 1042),
    ("Camera.WhiteLight", 1042),
    ("Camera.NightEnhance", 1042),
    ("Simplify.Encode", 1042),
    ("AVEnc.Encode.[0]", 1042),
    ("Detect.MotionDetect.[0]", 1042),
    ("Detect.HumanDetection.[0]", 1042),
    ("Detect.DetectTrack.[0]", 1042),
    ("General.OneKeyMaskVideo.[0]", 1042),
    ("Ability.VoiceTipType", 1042),
    ("fVideo.Volume", 1042),
    ("fVideo.AudioSupportType", 1042),
    ("Uart.PTZ.[0]", 1042),
    ("Uart.PTZPreset.[0]", 1042),
    ("NetWork.NetCommon", 1042),
]


def sofia_hash(password):
    md5 = hashlib.md5(password.encode("utf-8")).digest()
    return "".join(ALPHABET[(md5[i] + md5[i + 1]) % 62] for i in range(0, 16, 2))


class Camera:
    def __init__(self, host):
        self.sock = socket.create_connection((host, PORT), timeout=6)
        self.session = 0
        self.seq = 0

    def send(self, msg_id, body):
        data = json.dumps(body).encode("utf-8") + b"\x0a\x00"
        header = struct.pack("<BB2xII2xHI", 0xFF, 0, self.session, self.seq, msg_id, len(data))
        self.seq += 1
        self.sock.sendall(header + data)

    def recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("camera closed the connection")
            buf += chunk
        return buf

    def request(self, msg_id, body):
        self.send(msg_id, body)
        while True:
            header = self.recv_exact(20)
            reply_id = struct.unpack("<H", header[14:16])[0]
            length = struct.unpack("<I", header[16:20])[0]
            payload = self.recv_exact(length)
            if reply_id != msg_id + 1:
                continue
            text = payload.rstrip(b"\x00\n\r ").decode("utf-8", "replace")
            try:
                return json.loads(text)
            except ValueError:
                return {"_raw": text}

    def login(self, user, password):
        reply = self.request(1000, {
            "EncryptType": "MD5",
            "LoginType": "DVRIP-Web",
            "PassWord": sofia_hash(password),
            "UserName": user,
        })
        if reply.get("Ret") not in (100, 515):
            raise PermissionError("login refused (Ret=%s). Check the device password." % reply.get("Ret"))
        self.session = int(reply["SessionID"], 16)
        return reply

    def get(self, name, msg_id):
        return self.request(msg_id, {"Name": name, "SessionID": "0x%08X" % self.session})


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.2"
    user = input("Camera username [admin]: ").strip() or "admin"
    password = getpass.getpass("Camera device password (Enter if none): ")

    print("Connecting to %s:%d ..." % (host, PORT))
    cam = Camera(host)
    login = cam.login(user, password)
    print("Logged in. Reading settings (nothing will be changed) ...")

    result = {"host": host, "login": {k: v for k, v in login.items() if k != "SessionID"}, "configs": {}}
    for name, msg_id in QUERIES:
        try:
            reply = cam.get(name, msg_id)
            ret = reply.get("Ret")
            result["configs"][name] = reply
            print("  %-30s Ret=%s" % (name, ret))
        except (OSError, ConnectionError) as error:
            result["configs"][name] = {"error": str(error)}
            print("  %-30s failed: %s" % (name, error))
            break
    cam.sock.close()

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "camera_config_dump.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print("\nSaved to %s" % out)
    print("This file stays on this PC (it's ignored by git).")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled.")
    except Exception as error:  # noqa: BLE001 - show a friendly message
        print("\nError: %s" % error)
        sys.exit(1)
