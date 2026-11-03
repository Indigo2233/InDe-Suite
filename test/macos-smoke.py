"""Exercise the packaged dylib, dependencies, and persistent binary worker."""
import argparse
import ctypes
import json
from pathlib import Path
import platform
import struct
import subprocess
import sys
import time

import numpy as np
import onnxruntime as ort
import cv2


def frame(header, payload=b""):
    header["payloadBytes"] = len(payload)
    encoded = json.dumps(header).encode()
    return struct.pack("<4sI", b"IDE1", len(encoded)) + encoded + payload


def native_frame(header):
    header["payloadBytes"] = 0
    encoded = json.dumps(header).encode()
    return struct.pack("<4sI", b"IDE1", len(encoded)) + encoded


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    options = parser.parse_args()
    root = options.package.resolve()
    if sys.platform == "darwin":
        module = ctypes.CDLL(str(root / "InDe-pxm.dylib"))
        assert module.InstallPixInsightModule
        subprocess.run(["codesign", "--verify", "--strict", str(root / "InDe-pxm.dylib")], check=True)
    backend = root / "InDeBackend"
    worker = backend / "tools" / "inde_worker.py"
    size = 32
    rng = np.random.default_rng(20261028)
    pixels = (0.2 + 0.05 * rng.random((3, size, size))).astype("<f4")
    requests = []
    for repetition in range(2):
        for product in ("conv", "stars", "noise"):
            params = {"device": "cpu", "iterations": 1}
            if product == "stars":
                params["stars"] = True
            if product == "noise":
                params.update(csep=True, fsep=True)
            requests.append(frame(dict(command="process", product=product, width=size, height=size,
                                       channels=3, params=params), pixels.tobytes()))
    requests.append(native_frame({"command": "shutdown"}))
    started = time.monotonic()
    result = subprocess.run([sys.executable, "-I", "-B", str(worker), "--engine-dir", str(backend / "engine")],
                            input=b"".join(requests), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=900, check=True)
    data, outputs, offset = result.stdout, [], 0
    for index in range(7):
        magic, length = struct.unpack_from("<4sI", data, offset)
        assert magic == b"IDR1", f"Protocol contaminated at response {index}"
        offset += 8
        header = json.loads(data[offset:offset + length])
        offset += length
        assert header["ok"], header
        count = header["payloadBytes"]
        output = np.frombuffer(data[offset:offset + count], dtype="<f4")
        offset += count
        if index < 6:
            expected_planes = 6 if index % 3 == 1 else 3
            assert (header["width"], header["height"]) == (size, size)
            assert output.size == size * size * expected_planes
            assert np.isfinite(output).all()
            assert np.std(output[:size * size * 3]) > 0
            outputs.append(output)
        else:
            assert header["command"] == "shutdown"
    assert offset == len(data)
    for index in range(3):
        np.testing.assert_allclose(outputs[index], outputs[index + 3], atol=1e-6, rtol=1e-5)
    print(json.dumps({"ok": True, "architecture": platform.machine(), "providers": ort.get_available_providers(),
                      "opencv": cv2.__version__, "workerRequests": 6, "elapsedSeconds": round(time.monotonic()-started, 2)}, indent=2))


if __name__ == "__main__":
    main()
