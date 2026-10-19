#!/usr/bin/env python3
"""Drive a Godot web export in headless Chromium over WebDriver.

Dev-only verification helper: loads a served export, waits for the game, takes
screenshots, clicks the Start button with a *real* input event (so the browser's
autoplay policy lets the AudioContext start) and reports the console log plus
the state of Godot's audio context.

    python3 tools/web_check.py <url> <out_dir> [--wait=20] [--click=640,584]

Requires chromedriver on port 9515 (chromedriver --port=9515 &).
"""

import base64
import json
import os
import sys
import time
import urllib.request

CD = "http://127.0.0.1:9515"


def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(CD + path, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        raise SystemExit(f"{method} {path} failed: {err.code} {err.read().decode()[:500]}")


def main():
    url = sys.argv[1]
    out_dir = sys.argv[2]
    wait = 20
    click = None
    for arg in sys.argv[3:]:
        if arg.startswith("--wait="):
            wait = int(arg.split("=", 1)[1])
        elif arg.startswith("--click="):
            click = [int(v) for v in arg.split("=", 1)[1].split(",")]
    os.makedirs(out_dir, exist_ok=True)

    caps = {
        "capabilities": {
            "alwaysMatch": {
                "browserName": "chrome",
                "goog:loggingPrefs": {"browser": "ALL"},
                "goog:chromeOptions": {
                    "args": [
                        "--headless=new", "--no-sandbox", "--disable-dev-shm-usage",
                        "--enable-unsafe-swiftshader", "--use-gl=angle", "--use-angle=swiftshader",
                        "--autoplay-policy=no-user-gesture-required",
                        "--window-size=1280,720", "--hide-scrollbars",
                    ]
                },
            }
        }
    }
    session = call("POST", "/session", caps)["value"]["sessionId"]
    print("session", session)

    # Record every AudioContext the page creates, before the game loads, so the
    # audio question (threads on/off) can be answered from the outside.
    call("POST", f"/session/{session}/goog/cdp/execute", {
        "cmd": "Page.addScriptToEvaluateOnNewDocument",
        "params": {"source": (
            "window.__ctxs = []; window.__worklets = []; window.__scriptProc = 0;"
            "const _AC = window.AudioContext || window.webkitAudioContext;"
            "if (_AC) { window.AudioContext = class extends _AC {"
            "  constructor(...a) { super(...a); window.__ctxs.push(this); } }; }"
            "const _AWN = window.AudioWorkletNode;"
            "if (_AWN) { window.AudioWorkletNode = class extends _AWN {"
            "  constructor(...a) { super(...a); window.__worklets.push(String(a[1] || 'unnamed')); } }; }"
            "if (_AC) { const _sp = _AC.prototype.createScriptProcessor;"
            "  _AC.prototype.createScriptProcessor = function(...a) {"
            "    window.__scriptProc++; return _sp.apply(this, a); }; }"
        )},
    })

    def shot(name):
        raw = call("GET", f"/session/{session}/screenshot")["value"]
        path = os.path.join(out_dir, name)
        with open(path, "wb") as f:
            f.write(base64.b64decode(raw))
        print("screenshot", path)
        return path

    try:
        call("POST", f"/session/{session}/url", {"url": url})
        time.sleep(wait)
        probe = (
            "const out = {"
            "audio: (window.__ctxs || []).map(c => c.state + '@' + c.sampleRate),"
            "worklets: window.__worklets || [],"
            "scriptProcessors: window.__scriptProc || 0,"
            "canvas: document.querySelector('canvas') ? "
            "document.querySelector('canvas').width + 'x' + document.querySelector('canvas').height : 'none',"
            "viewport: window.innerWidth + 'x' + window.innerHeight"
            "}; return JSON.stringify(out);"
        )
        print("probe:", call("POST", f"/session/{session}/execute/sync",
                             {"script": probe, "args": []})["value"])
        shot("menu.png")

        if click:
            actions = {"actions": [{
                "type": "pointer", "id": "mouse", "parameters": {"pointerType": "mouse"},
                "actions": [
                    {"type": "pointerMove", "duration": 0, "x": click[0], "y": click[1]},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pointerUp", "button": 0},
                ],
            }]}
            call("POST", f"/session/{session}/actions", actions)
            print(f"clicked {click}")
            time.sleep(8)
            print("probe after click:", call("POST", f"/session/{session}/execute/sync",
                                             {"script": probe, "args": []})["value"])
            shot("after_click.png")
            time.sleep(8)
            shot("after_click2.png")

        logs = call("POST", f"/session/{session}/log", {"type": "browser"})["value"]
        with open(os.path.join(out_dir, "console.log"), "w") as f:
            for entry in logs:
                f.write(f"[{entry['level']}] {entry['message']}\n")
        print(f"console log: {len(logs)} entries ->", os.path.join(out_dir, "console.log"))
        bad = [e for e in logs if e["level"] in ("SEVERE",) or "ERROR" in e["message"]
               or "cannot open" in e["message"].lower()]
        for entry in bad[:15]:
            print("  !", entry["level"], entry["message"][:160])
        print("RESULT:", "issues" if bad else "clean")
    finally:
        call("DELETE", f"/session/{session}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
