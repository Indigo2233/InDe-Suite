"""In-memory PixInsight bridge for InDeConv, InDeStars and InDeNoise.

The worker uses a small framed binary protocol over stdin/stdout. Pixel payloads
are planar little-endian float32 arrays. The protocol owns a duplicate of the
original stdout pipe while inherited text output is suppressed.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import traceback
from types import SimpleNamespace

import numpy as np


REQUEST_MAGIC = b"IDE1"
RESPONSE_MAGIC = b"IDR1"
PREFIX = struct.Struct("<4sI")
MAX_HEADER_BYTES = 1 << 20


def _reserve_protocol_stdout():
    """Keep one clean pipe while silencing stdout/stderr inherited by engines.

    PixInsight's ExternalProcess combines a child's stdout and stderr into its
    stdout stream. A duplicated handle preserves the original pipe for framed
    responses; redirecting file descriptors 1 and 2 also catches native code
    and modules that retained references to the original Python streams.
    """
    protocol_fd = os.dup(sys.stdout.fileno())
    protocol_sink = os.fdopen(protocol_fd, "wb", buffering=0)
    null_fd = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(null_fd, sys.stdout.fileno())
        os.dup2(null_fd, sys.stderr.fileno())
    finally:
        os.close(null_fd)
    return protocol_sink


def _read_exact(stream, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise EOFError(f"unexpected end of stream; wanted {remaining} more bytes")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _read_frame(stream):
    prefix = stream.read(PREFIX.size)
    if not prefix:
        return None
    if len(prefix) != PREFIX.size:
        prefix += _read_exact(stream, PREFIX.size - len(prefix))
    magic, header_size = PREFIX.unpack(prefix)
    if magic != REQUEST_MAGIC:
        raise ValueError(f"invalid request magic: {magic!r}")
    if not 0 < header_size <= MAX_HEADER_BYTES:
        raise ValueError(f"invalid request header size: {header_size}")
    header = json.loads(_read_exact(stream, header_size).decode("utf-8"))
    payload_size = int(header.get("payloadBytes", 0))
    if payload_size < 0:
        raise ValueError("negative payload size")
    return header, _read_exact(stream, payload_size)


def _padded_json(value: dict) -> bytes:
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return data + b" " * (-len(data) % 4)


def _write_frame(stream, header: dict, planes=()):
    arrays = [np.ascontiguousarray(a, dtype="<f4") for a in planes]
    payload_size = sum(a.nbytes for a in arrays)
    header = dict(header)
    header["payloadBytes"] = payload_size
    encoded = _padded_json(header)
    stream.write(PREFIX.pack(RESPONSE_MAGIC, len(encoded)))
    stream.write(encoded)
    for array in arrays:
        stream.write(memoryview(array).cast("B"))
    stream.flush()


def _bounded_float(params: dict, name: str, default: float, low: float, high: float) -> float:
    value = float(params.get(name, default))
    if not math.isfinite(value) or not low <= value <= high:
        raise ValueError(f"{name} must be in [{low}, {high}]")
    return value


def _boolean(params: dict, name: str, default: bool = False) -> bool:
    return bool(params.get(name, default))


def _arguments(product: str, params: dict, source_mono: bool):
    args = SimpleNamespace(
        product=product,
        overlap=_bounded_float(params, "overlap", 0.2, 0.0, 0.5),
        device=str(params.get("device", "auto")),
        tile=None,
        no_normalization=False,
        norm_p=None,
        norm_g=None,
        log10gain=None,
        source_mono=source_mono,
        ss=_bounded_float(params, "ss", 0.5, 0.0, 0.7),
        ash=_bounded_float(params, "ash", 0.0, -0.5, 0.5),
        nsd=_bounded_float(params, "nsd", 0.0, 0.0, 8.0),
        ansp=_boolean(params, "ansp", True),
        sn=_bounded_float(params, "sn", 0.5, 0.0, 1.0),
        correct_only=_boolean(params, "correctOnly"),
        lp=_boolean(params, "lunarPlanetary"),
        stars=_boolean(params, "stars"),
        unscreen=_boolean(params, "unscreen"),
        noise_params=None,
        noise_it=int(params.get("iterations", 2)),
        noise_dn=_bounded_float(params, "dn", 0.9, 0.0, 1.0),
        noise_dn_explicit=False,
        noise_csep=_boolean(params, "csep"),
        noise_fsep=_boolean(params, "fsep"),
        noise_fs=_bounded_float(params, "fs", 5.0, 1.0, 100.0),
    )
    if args.device not in ("auto", "dml", "cpu", "coreml"):
        raise ValueError("device must be auto, dml, cpu or coreml")
    if not 1 <= args.noise_it <= 5:
        raise ValueError("iterations must be in [1, 5]")
    if args.correct_only and args.lp:
        raise ValueError("correct-only and lunar/planetary modes are mutually exclusive")

    for name in ("di", "dc", "dhf", "dlf", "dihf", "dilf", "dchf", "dclf"):
        setattr(args, "noise_" + name, None)
    if args.noise_csep and args.noise_fsep:
        active = ("dihf", "dilf", "dchf", "dclf")
    elif args.noise_csep:
        active = ("di", "dc")
    elif args.noise_fsep:
        active = ("dhf", "dlf")
    else:
        active = ()
    for name in active:
        setattr(args, "noise_" + name, _bounded_float(params, name, 0.9, 0.0, 1.0))
    return args


def _decode_image(header: dict, payload: bytes):
    width = int(header["width"])
    height = int(header["height"])
    channels = int(header["channels"])
    if width <= 0 or height <= 0 or channels not in (1, 3):
        raise ValueError(f"unsupported image geometry: {width}x{height}x{channels}")
    expected = width * height * channels * 4
    if len(payload) != expected:
        raise ValueError(f"pixel payload has {len(payload)} bytes; expected {expected}")
    planar = np.frombuffer(payload, dtype="<f4").reshape(channels, height, width)
    if not np.isfinite(planar).all():
        raise ValueError("image contains NaN or infinite samples")
    if channels == 1:
        image = np.repeat(planar[0, :, :, None], 3, axis=2)
    else:
        image = np.transpose(planar, (1, 2, 0))
    return np.ascontiguousarray(image, dtype=np.float32), channels


def _planes(image: np.ndarray, channels: int):
    image = np.asarray(image, dtype=np.float32)
    if channels == 1:
        return (np.ascontiguousarray(image.mean(axis=2)),)
    return tuple(np.ascontiguousarray(image[:, :, channel]) for channel in range(3))


def _process(engine, header: dict, payload: bytes):
    product = str(header.get("product", "")).lower()
    if product not in ("conv", "stars", "noise"):
        raise ValueError(f"unknown product: {product}")
    image, channels = _decode_image(header, payload)
    args = _arguments(product, dict(header.get("params") or {}), channels == 1)

    minimum = {"conv": 512, "stars": 8, "noise": 8}[product]
    padded, padding = engine._pad_to_min_window(image, minimum)
    with contextlib.redirect_stdout(sys.stderr):
        if product == "conv":
            result, extra = engine.run_product(product, padded, args)
        elif product == "stars":
            result, extra = engine.run_stars_product(padded, args)
        else:
            engine._noise_separation_settings(args)
            result, extra = engine.run_noise_product(padded, args)
    result = engine._crop_back(result, padding)
    if extra is not None:
        extra = engine._crop_back(extra, padding)

    outputs = [
        {"name": "main", "channels": channels},
    ]
    planes = list(_planes(result, channels))
    if extra is not None:
        outputs.append({"name": "stars", "channels": channels})
        planes.extend(_planes(extra, channels))
    return {
        "ok": True,
        "width": int(result.shape[1]),
        "height": int(result.shape[0]),
        "outputs": outputs,
    }, planes


def _load_engine(engine_dir: Path):
    if not (engine_dir / "run_models.py").is_file():
        raise FileNotFoundError(f"run_models.py was not found in {engine_dir}")
    sys.path.insert(0, str(engine_dir))
    import run_models as engine

    # Isolated Python (-I) omits the script directory from sys.path.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from inde_runtime import make_session as original_make_session
    sessions = {}

    def cached_make_session(model_path, device="auto"):
        key = (str(Path(model_path).resolve()), str(device))
        session = sessions.get(key)
        if session is None:
            session = original_make_session(model_path, device)
            sessions[key] = session
        return session

    engine.make_session = cached_make_session
    return engine


def main(argv=None) -> int:
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    protocol_sink = _reserve_protocol_stdout()
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-dir", type=Path, required=True)
    options = parser.parse_args(argv)
    engine = _load_engine(options.engine_dir.resolve())
    source = sys.stdin.buffer
    sink = protocol_sink

    while True:
        try:
            frame = _read_frame(source)
            if frame is None:
                return 0
            header, payload = frame
            command = header.get("command", "process")
            if command == "shutdown":
                _write_frame(sink, {"ok": True, "command": "shutdown"})
                return 0
            if command != "process":
                raise ValueError(f"unknown command: {command}")
            response, planes = _process(engine, header, payload)
            _write_frame(sink, response, planes)
        except Exception as exc:  # keep protocol errors recoverable for the dialog
            traceback.print_exc(file=sys.stderr)
            try:
                _write_frame(sink, {"ok": False, "error": str(exc)})
            except Exception:
                return 2


if __name__ == "__main__":
    raise SystemExit(main())
