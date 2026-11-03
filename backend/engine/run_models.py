"""Self-contained runner for the InDeConv, InDeStars, and InDeNoise models.

Usage:
  python run_models.py <image> [--product conv|stars|noise|all] [--tile N] [--overlap F]
                       [--outdir outputs] [--ss F] [--ash F] [--nsd F] [--sn F]
                       [--preview]

Reads FITS / TIFF / PNG (float or integer), processes with tiled inference + feathered
blending, writes FITS (header copied from the input) and stretched PNG previews.

Model contracts:
  conv  in  [1,1024,1024,3] + parameters[1,6]   out [1,512,512,3]   (output is half-res)
  stars  in  [1,512,512,3]                       out Identity:0 (starless), Identity_1:0 (stars)
  noise  in  [1,512,512,3]                       out [1,512,512,3]   (denoised)
"""
import argparse, json, math, os, sys, time
from pathlib import Path
import numpy as np

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

HERE = Path(__file__).resolve().parent
MODELS = HERE / 'models'

FILES = {'conv': 'InDeConv.onnx',
         'stars': 'InDeStars.onnx',
         'noise': 'InDeNoise.onnx'}
# (input window, output region). conv takes a 1024 context window and returns the
# corrected centre 512x512 at the same resolution. noise/stars are 1:1.
GEOM = {'conv': (1024, 512), 'stars': (512, 512), 'noise': (512, 512)}

# Per-product contract for the bundled model catalog (normalization scheme,
# padding mode, and the model parameter vector order).
# The catalog orders the model inputs by "sinkIndex": ss, ash, nsd, ansp, sn,
# log10gain - note nsd is scaled by sinkScale 0.5 and log10gain is a private
# "Normalization Gain" (lp is an ENGINE parameter, not a model input).
CONTRACT = {
    'conv': {'normalization': 'arcsinh', 'wp': 1.0, 'reflectionPad': False},
    'stars': {'normalization': 'mtf', 'mt': 0.25, 'reflectionPad': False},
    'noise': {'normalization': 'mtf', 'mt': 0.25, 'reflectionPad': True},
}

# The catalog next to this bundle refreshes geometry, padding, and normalization
# settings. The constants above remain the fallback when the catalog is unavailable.
CATALOG = HERE.parent / 'catalog.json'


def _load_catalog():
    try:
        cat = json.loads(CATALOG.read_text(encoding='utf-8'))
    except Exception:
        return
    prods = cat.get('products') or []
    for p in prods:
        key = p.get('key')
        if key not in FILES:
            continue
        models = p.get('models')
        items = models.items() if isinstance(models, dict) else \
            [(str(i), m) for i, m in enumerate(models or [])]
        # Select the contract of the actual loaded model, not a newer catalog
        # entry whose graph/pipeline may have a different interface.
        model_base = Path(FILES[key]).stem
        selected = None
        for mv, m in items:
            if m.get('modelFileBase') == model_base:
                selected = m
                break
        if selected is None:
            continue
        m = selected
        tile = m.get('tile') or {}
        ts, ov = tile.get('tileSize'), tile.get('oversize')
        if ts and ov:
            in_tile = int(round(ts * float(ov)))
            GEOM[key] = (in_tile, int(ts))
        c = CONTRACT.setdefault(key, {})
        c['mlVersion'] = m.get('mlVersion')
        c['modelFileBase'] = model_base
        c['reflectionPad'] = bool(m.get('reflectionPad'))
        scheme = (m.get('normalization') or '').strip()
        c['scheme'] = scheme
        if scheme.startswith('arcsinh'):
            c['normalization'] = 'arcsinh'
        elif scheme.startswith('mtf+arcsinh'):
            c['normalization'] = 'mtf+arcsinh'
        elif scheme.startswith('mtf'):
            c['normalization'] = 'mtf'
        c['params'] = [(q.get('name'), q.get('sink'), q.get('sinkIndex'),
                        q.get('sinkScale')) for q in (m.get('parameters') or [])]


_load_catalog()


# ---------------------------------------------------------------- image io
_INPUT_FRAME = {"flipped": False, "int_dtype": None, "source_mono": False}
# 记录输入数组的行序与整数类型，写回时按原样恢复（见 siril 脚本的方向约定）


def _image_rgb(d, channel_axis=None):
    """Convert a single mono/RGB image to HWC; discard a raster alpha channel."""
    d = np.asarray(d)
    if d.ndim == 2:
        d = d[:, :, None]
    elif d.ndim == 3:
        if channel_axis is None:
            if d.shape[-1] in (1, 3, 4):
                channel_axis = 2
            elif d.shape[0] in (1, 3, 4):
                channel_axis = 0
            else:
                raise ValueError(f'Unsupported image channel layout: {d.shape}')
        d = np.moveaxis(d, channel_axis, -1)
    else:
        raise ValueError(f'Expected one 2-D mono/RGB image, got {d.shape}')
    if d.shape[-1] == 1:
        d = np.repeat(d, 3, axis=-1)
    elif d.shape[-1] == 4:
        d = d[:, :, :3]
    elif d.shape[-1] != 3:
        raise ValueError(f'Unsupported image channel count: {d.shape[-1]}')
    return np.ascontiguousarray(d)


def _integer_unit(d, bits=None):
    """Scale integer data using its declared or container bit depth."""
    d = np.asarray(d)
    if np.issubdtype(d.dtype, np.integer):
        if bits is None:
            imax = float(np.iinfo(d.dtype).max)
        else:
            signed = np.issubdtype(d.dtype, np.signedinteger)
            imax = float((1 << (int(bits) - int(signed))) - 1)
        return d.astype(np.float32) / imax
    return d.astype(np.float32)


def load_image(path):
    """-> (H,W,3) float32, header or None; preserve floating-point values."""
    p = Path(path)
    suf = p.suffix.lower()
    _INPUT_FRAME.update(flipped=False, int_dtype=None, source_mono=False)
    if suf in ('.fits', '.fit', '.fts'):
        from astropy.io import fits
        # 带 BZERO/BSCALE/BLANK 的 FITS（16 位无符号图几乎都有）不能 memmap
        try:
            with fits.open(p, memmap=True) as h:
                raw = h[0].data
                hdr = h[0].header.copy()
        except (ValueError, OSError):
            with fits.open(p, memmap=False) as h:
                raw = h[0].data
                hdr = h[0].header.copy()
        was_int = np.issubdtype(np.asarray(raw).dtype, np.integer)
        # FITS cubes conventionally store channels first, even when H is 1 or 3.
        axis = 0 if raw.ndim == 3 and raw.shape[0] in (1, 3) else None
        _INPUT_FRAME['source_mono'] = bool(raw.ndim == 2 or
                                         (raw.ndim == 3 and raw.shape[axis if axis is not None else -1] == 1))
        d = _image_rgb(raw, axis)
        # 统一成「逻辑图像」朝向：ROWORDER=BOTTOM-UP 时存储是自下而上。
        # 注意必须在转置成 (H,W,C) 之后翻转，否则翻的是通道轴（CHW 的上下轴是 -2）。
        mode = os.environ.get('RCA_ROWORDER', 'auto').lower()
        ro = str(hdr.get('ROWORDER', '')).upper()
        if mode == 'asis':
            flipped = False
        elif mode == 'top':
            flipped = False
        elif mode == 'bottom':
            flipped = True
        else:                                     # auto：按头判断
            flipped = ro.startswith('BOTTOM')
        if flipped:
            d = d[::-1]
        d = np.ascontiguousarray(d)
        _INPUT_FRAME['flipped'] = flipped
        _INPUT_FRAME['int_dtype'] = np.asarray(raw).dtype if was_int else None
        return _integer_unit(d), hdr
    bits = None
    axis = None
    if suf in ('.tif', '.tiff'):
        import tifffile
        with tifffile.TiffFile(p) as tif:
            series = tif.series[0]
            d = series.asarray()
            axes = series.axes
            samples = [i for i, name in enumerate(axes) if name in ('S', 'C')]
            if d.ndim == 3 and len(samples) == 1:
                axis = samples[0]
            elif d.ndim != 2:
                raise ValueError(f'Expected one TIFF image, got axes {axes}, shape {d.shape}')
            depth = tif.pages[0].bitspersample
            depths = (depth,) if np.isscalar(depth) else tuple(depth)
            if len(set(depths)) != 1:
                raise ValueError(f'Unsupported mixed TIFF sample bit depths: {depths}')
            bits = int(depths[0])
    else:
        from PIL import Image
        with Image.open(p) as im:
            # Pillow may decode 16-bit grayscale PNG as int32 and colour PNG as
            # uint8. Inspect IHDR so neither decoder container nor scene peak
            # silently changes the source's range or precision.
            if im.format == 'PNG':
                with p.open('rb') as stream:
                    ihdr = stream.read(26)
                bits = int(ihdr[24])
                colour = int(ihdr[25])
                if bits == 16 and colour != 0:
                    try:
                        import cv2
                    except ImportError as exc:
                        raise RuntimeError('16-bit colour PNG requires OpenCV; use TIFF instead') from exc
                    d = cv2.imdecode(np.frombuffer(p.read_bytes(), np.uint8), cv2.IMREAD_UNCHANGED)
                    if d is None or d.dtype != np.uint16:
                        raise ValueError('Could not decode PNG at its declared 16-bit depth')
                    if d.ndim == 3:
                        d = d[:, :, 2::-1]  # BGR(A) -> RGB; discard alpha.
                else:
                    if im.mode in ('P', 'PA', 'LA', 'RGBA'):
                        im = im.convert('RGB')
                    d = np.asarray(im)
                    # Packed 1/2/4-bit and palette PNG expand to uint8 values.
                    if bits == 16:
                        d = d.astype(np.uint16)  # PNG samples are unsigned, including Pillow mode I.
                    else:
                        bits = None
            else:
                if im.mode in ('P', 'PA', 'LA', 'RGBA', 'CMYK'):
                    im = im.convert('RGB')
                d = np.asarray(im)
        axis = 2 if d.ndim == 3 else None
    _INPUT_FRAME['source_mono'] = bool(d.ndim == 2 or
                                     (d.ndim == 3 and d.shape[axis if axis is not None else -1] == 1))
    return _integer_unit(_image_rgb(d, axis), bits), None


def _to_unit(d):
    """整数数据按满量程缩放到 [0,1]；浮点数据保持原样。"""
    if np.issubdtype(d.dtype, np.integer):
        info = np.iinfo(d.dtype)
        return d.astype(np.float32) / float(info.max)
    return d.astype(np.float32)


def save_fits(path, data_hwc, hdr):
    from astropy.io import fits
    out = np.transpose(data_hwc, (2, 0, 1)).astype(np.float32)
    # 写回前恢复输入数组的行序：输入被翻转过（BOTTOM-UP）就翻回去并如实声明。
    # out 是 (C,H,W)，上下轴是 -2；用 [::-1] 会翻通道。
    if _INPUT_FRAME.get('flipped'):
        out = np.ascontiguousarray(np.flip(out, axis=-2))
    h = hdr.copy() if hdr is not None else fits.Header()
    h['ROWORDER'] = 'BOTTOM-UP' if _INPUT_FRAME.get('flipped') else 'TOP-DOWN'
    # PrimaryHDU updates and orders NAXIS cards, including mono -> RGB expansion.
    fits.PrimaryHDU(data=out, header=h).writeto(path, overwrite=True)


def save_preview(path, data_hwc, lo=None, hi=None, max_side=1400):
    from PIL import Image
    x = data_hwc
    if lo is None:
        lo = float(np.percentile(x, 0.5))
    if hi is None:
        hi = float(np.percentile(x, 99.9))
    y = np.clip((x - lo) / max(hi - lo, 1e-9), 0, 1) ** (1 / 2.2)
    img = (y * 255).astype(np.uint8)
    im = Image.fromarray(img)
    if max(im.size) > max_side:
        s = max_side / max(im.size)
        im = im.resize((max(1, int(im.width * s)), max(1, int(im.height * s))), Image.LANCZOS)
    im.save(path)


# ---------------------------------------------------------------- tiling
# Fixed-window tiling and feathered blending used by the bundled model runner:
#   window = trunc(tileSize * oversize)            conv 1024 (margin 256), stars/noise 512 (0)
#   N      = 2 * floor(overlap * tileSize / 2)     feather band, also decides the block count
#   stride = tileSize - N                          only used for nx/ny
#   nx     = ceil(W / stride)                      (1 when W <= tileSize)
#   stepX  = W / nx                                the real pitch (even division, not stride)
#   ox[i]  = clamp(floor((i+0.5)*stepX - window/2 + 0.5), -margin, W - window + margin)
# Feather weights are a Hann ramp of width N: v[i] = 0.5*(1+cos(pi*i/(N+1))), i = 1..N-1.
def cli_axis_origins(total, tile, window_size, overlap):
    """Return tile origins along one axis and the feather width."""
    margin = (window_size - tile) // 2
    n_band = 2 * int(overlap * tile / 2)           # 2 * floor(overlap*tile/2)
    stride = max(1, tile - n_band)
    n = 1 if total <= tile else int(math.ceil(total / stride))
    step = total / n
    lo, hi = -margin, total - window_size + margin
    out = []
    for i in range(n):
        v = math.floor((i + 0.5) * step - window_size / 2.0 + 0.5)
        if hi >= lo:                                # empty interval -> no clamping (centred)
            v = min(max(v, lo), hi)
        out.append(int(v))
    return out, n_band


def cli_feather(tile, n_band):
    """1-D output-tile weight profile: Hann ramps of width n_band at both ends."""
    w = np.ones(tile, np.float32)
    if n_band > 1:
        v = (0.5 * (1.0 + np.cos(np.pi * np.arange(1, n_band) / (n_band + 1.0)))
             ).astype(np.float32)
        w[:v.size] = v
        w[tile - v.size:] = v[::-1]
    return w


def _support_range(weights, n_tiles, total, tile, overlap):
    """Return the nonzero support interval [lo, hi) for each tile."""
    N = 2 * int(overlap * tile / 2)
    step = total / n_tiles
    out = []
    for k in range(n_tiles):
        lo = int(math.floor(k * step + 0.5)) - (N // 2 if N else 0)
        hi = int(math.floor((k + 1) * step + 0.5)) + (N // 2 if N else 0)
        out.append((max(0, lo), min(total, hi)))
    return out


def _fill_uncovered(acc, wsum, ref):
    """wsum==0 的像元（没有任何瓦片贡献）用参考图（通常是输入）补齐，避免塌成 0。

    这是 1.197% "地板" 伪影的兜底：几何上权重支撑可能超出瓦片输出范围，
    官方在这种情形下的行为尚未钉死（见 ../noise-output-floor.md）。
    """
    bad = (wsum[:, :, 0] <= 0)
    if not bad.any():
        return acc, int(bad.sum())
    if ref is not None:
        acc[bad] = ref[bad]
    return acc, int(bad.sum())


def cli_axis_weights(total, tile, overlap, n):
    """Return the per-axis feather weights with unit-sum overlap blending.

      Feather bands are placed at internal boundaries C_k = round(k*step);
      剖面 v[j] = 0.5(1+cos(pi(j+1)/(N+1)))，j=0..N-1（恰好 N 项）；
      左格取降沿 v[t]，右格取升沿 v[N-1-t]；带外为 0。
      v[j] + v[N-1-j] ≡ 1 ⇒ Σ_i W_i ≡ 1，所以拼接不需要再除以权重和。
    """
    N = 2 * int(overlap * tile / 2)
    step = total / n
    W = np.zeros((n, total), np.float64)
    for k in range(n):
        lo = int(math.floor(k * step + 0.5))
        hi = int(math.floor((k + 1) * step + 0.5))
        W[k, max(0, lo):min(total, hi)] = 1.0
    if N > 0:
        v = 0.5 * (1.0 + np.cos(np.pi * (np.arange(N) + 1.0) / (N + 1.0)))
        for k in range(1, n):
            C = int(math.floor(k * step + 0.5))
            lo = C - N // 2
            for t in range(N):
                x = lo + t
                if 0 <= x < total:
                    W[k - 1, x] = v[t]              # 降沿
                    W[k, x] = v[N - 1 - t]          # 升沿
    return W


# ---------------------------------------------------------------- normalization
# Per-image normalization used by the model runner:
#   N(x) = asinh((x - p) * g) / asinh((1 - p) * g)
# with a black point p and a gain g computed per image, applied to all channels alike.
#
# The per-image statistics use the following stable contract:
#   * crop the image by 5% on each side                  (0.05 @ 0x1412ad818)
#   * nearest-neighbour resample to 128x128 per channel  (1/128 @ 0x1412ad810)
#   * p = interpolated quantile q = 0.001 of the positive values, idx = (n-1)*q
#         (0.001 @ 0x14129b0e0, 1.0 @ 0x1412989d8)
#   * m = median(map - p)
#   * g = 1.0 if m <= 1e-6 (0x1412ad800), else min(0.2/((m+0.1)*m + 1e-12), 1e6)
#         (0.2 @ 0x14129c168, 0.1 @ 0x1412ad820, 1e-12 @ 0x1412ad7f0, 1e6 @ 0x1412989e0)
#   * log10gain = log10(g / asinh(g))
CROP_FRAC = 0.05
THUMB = 128
QUANTILE = 0.001


def _quantile_interp(sorted_vals, q):
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    idx = (n - 1.0) * q
    lo = int(math.floor(idx))
    frac = idx - lo
    if lo + 1 >= n:
        return float(sorted_vals[-1])
    return float(sorted_vals[lo]) + (float(sorted_vals[lo + 1]) - float(sorted_vals[lo])) * frac


def _resample_nearest(crop, thumb_w=THUMB):
    """Nearest-neighbour resample with a fixed output width."""
    h, w = crop.shape[:2]
    th = max(1, int(round(h * thumb_w / w)))
    try:
        import cv2
        return np.stack([cv2.resize(crop[:, :, k].astype(np.float32), (thumb_w, th),
                                    interpolation=cv2.INTER_NEAREST)
                         for k in range(crop.shape[2])], axis=2).astype(np.float64)
    except ImportError:
        ys = np.clip((np.arange(th) * h / th).astype(int), 0, h - 1)
        xs = np.clip((np.arange(thumb_w) * w / thumb_w).astype(int), 0, w - 1)
        return crop[np.ix_(ys, xs)].astype(np.float64)


def _auto_norm_params(img):
    """Return the per-image black point, gain, and log10 gain."""
    h, w = img.shape[:2]
    my, mx = int(h * CROP_FRAC), int(w * CROP_FRAC)
    crop = img[my:h - my, mx:w - mx] if (my or mx) else img
    vals = _resample_nearest(crop).ravel()
    pos = np.sort(vals[vals > 0])
    p = _quantile_interp(pos, QUANTILE)
    # Estimate gain from the linearly normalized thumbnail.
    m = float(np.median((vals - p) / (1.0 - p)))
    if m <= 1e-6:
        g = 1.0
    else:
        g = min(0.2 / ((m + 0.1) * m + 1e-12), 1e6)
    return p, g, float(math.log10(g / math.asinh(g)))


def _conv_norm_params(img, lunar_planetary=False, source_mono=False):
    """Return CONV black-point statistics and the selected gain."""
    h, w = img.shape[:2]
    my, mx = int(h * CROP_FRAC), int(w * CROP_FRAC)
    crop = img[my:h - my, mx:w - mx] if (my or mx) else img
    vals = _resample_nearest(crop[:, :, :1] if source_mono else crop).ravel()
    p = _quantile_interp(np.sort(vals[vals > 0]), QUANTILE)
    linear = (vals - p) / (1.0 - p)
    # The host selects sorted[len/2], the upper middle, rather than averaging
    # two middle samples. This matters for gradients and small test frames.
    middle = linear.size // 2
    m = float(np.partition(linear, middle)[middle])
    if lunar_planetary or m <= 1e-6:
        g = 1.0
    else:
        g = min(max(0.2 / ((m + 0.1) * m + 1e-12), 1.0), 1e6)
    return p, g, float(math.log10(g / math.asinh(g)))


def _conv_model_parameters(args, log10gain):
    """Apply catalog mode pins without changing the user's saved parameters."""
    if getattr(args, 'correct_only', False):
        return np.array([[0.0, 0.0, 0.0, 1.0, 0.0, log10gain]], np.float32)
    if getattr(args, 'lp', False):
        return np.array([[0.0, 0.0, args.nsd * 0.5, 0.0, args.sn,
                          log10gain]], np.float32)
    nsd = 0.0 if args.ansp else args.nsd
    return np.array([[args.ss, args.ash, nsd * 0.5, args.ansp, args.sn,
                      log10gain]], np.float32)


def norm_forward(x, product, p, g):
    """Per-product normalization applied before the model (catalog contract)."""
    c = CONTRACT[product]
    if c['normalization'] == 'arcsinh':
        # Preserve values below the black point during normalization.
        if product == 'conv':
            # First map black..white to 0..1, then apply arcsinh.
            linear = (x.astype(np.float64) - p) / (1.0 - p)
            return (np.arcsinh(linear * g) / np.arcsinh(g)).astype(np.float32)
        return (np.arcsinh((x - p) * g) / np.arcsinh((1.0 - p) * g)).astype(np.float32)
    if c['normalization'] == 'mtf':
        m = c['mt']
        return (((m - 1.0) * x) / ((2.0 * m - 1.0) * x - m)).astype(np.float32)
    return x.astype(np.float32)


def make_session(model_path, device='auto'):
    """建推理会话。device: auto(有 DML 就用) / dml / cpu。

    DirectML 是厂商中立的 GPU 后端（Intel/NVIDIA/AMD 都能用）。
    """
    import onnxruntime as ort
    ort.set_default_logger_severity(3)
    avail = ort.get_available_providers()
    if device in ('auto', 'dml') and 'DmlExecutionProvider' in avail:
        try:
            return ort.InferenceSession(str(model_path),
                                        providers=['DmlExecutionProvider', 'CPUExecutionProvider'])
        except Exception:
            if device == 'dml':
                raise
    return ort.InferenceSession(str(model_path), providers=['CPUExecutionProvider'])


def norm_inverse(y, product, p, g):
    c = CONTRACT[product]
    if c['normalization'] == 'arcsinh':
        if product == 'conv':
            return (p + (1.0 - p) * np.sinh(y.astype(np.float64) * np.arcsinh(g)) / g).astype(np.float32)
        return (p + np.sinh(y * np.arcsinh((1.0 - p) * g)) / g).astype(np.float32)
    if c['normalization'] == 'mtf':
        m = c['mt']
        return ((m * y) / ((2.0 * m - 1.0) * y - (m - 1.0))).astype(np.float32)
    return y.astype(np.float32)


# ---------------------------------------------------------------- noise (InDeNoise)
# Per-tile normalization and iterative model blending:
#   t = clamp((x - black[ch]) / R, 0, 1)          per-channel black, global range R
#   y = MTF(m, t) = ((m-1)t) / ((2m-1)t - m)
#   iteration k:  t_k = t_{k-1} + w_k*(model(t_{k-1}) - t_{k-1}),  w_k = 1/(it-k+1)
#   out_norm = t0 + dn*(t_it - t0)                t0 = the first iteration's input
#   out      = denorm(out_norm)
def mtf_forward(x, R, m, black):
    t = np.clip((x - np.asarray(black, np.float64)) / R, 0.0, 1.0)
    den = (2.0 * m - 1.0) * t - m
    # 平坦图会让 m 退化到 0，此时分母为 0；按极限取值避免 inf/nan
    den = np.where(np.abs(den) < 1e-12, -1e-12, den)
    return (((m - 1.0) * t) / den).astype(np.float64)


def mtf_inverse(y, R, m, black):
    t = (y * m) / ((2.0 * m - 1.0) * y - (m - 1.0))
    return (t * R + np.asarray(black, np.float64)).astype(np.float64)


def noise_params(img, override=None):
    """noise 每图归一化参数（闭式见 ../noise-params-formula.md 与 ../noise-G.md）。

    统计所见的图像 = flipud(输入) → 越界先重标定到 [0,1] → 每边裁 floor(dim/50) = 2%，逐通道：
        S[ch] = 上中位（sort[n//2]）      V[ch] = 均值
        E[ch] = ROI 低尾第 k 小，k = max(1, floor(N*1e-7))，收集上限 max(1024, 64k)
        G     = max_ch( S[ch] - E[ch] )        ← 闭式（noise-G.md，11/12 图逐位相同）
        black[ch] = S[ch] - G ；R = 1 - min(black)（range<=0 时取 1.0）
        T = mean_ch(V[ch]-black[ch]) / R ；m = 解 MTF(m,T)=0.18
    真实图上 k=1 且每通道 ROI 最小值唯一，于是 E = ROI 最小值。
    """
    if override:
        return float(override['R']), float(override['m']), [float(v) for v in override['black']]
    work, _ = rescale_to_unit(img)
    H, W, _ = work.shape
    cy, cx = H // 50, W // 50                     # floor(dim/50) = 2% 裁边
    roi = work[cy:H - cy, cx:W - cx] if (cy or cx) else work
    n = roi.shape[0] * roi.shape[1]
    # 大图时中位/均值走采样网格；低尾收集器仍走全像素（noise-G.md）
    step = 1 if n <= (1 << 22) else int(math.ceil(math.sqrt(n / float(1 << 22))))
    grid = roi[::step, ::step].reshape(-1, roi.shape[2]).astype(np.float64)
    S = np.sort(grid, axis=0)[grid.shape[0] // 2]   # 上中位（不是 np.median）
    V = grid.mean(axis=0)
    flat = roi.reshape(n, roi.shape[2]).astype(np.float64)
    k = max(1, int(n * 1e-7))                     # 常量是 1e-7
    limit = max(1024, 64 * k)
    tail = np.sort(flat, axis=0)[:limit]          # 低尾收集器走全像素
    E = tail[min(k, limit) - 1]
    G = float(np.max(S - E))                      # ★ 闭式：逐通道(上中位-低尾)之差取最大
    black = S - G
    R = 1.0 - float(black.min())
    if R <= 0.0:
        R = 1.0
    T = float(np.mean(V - black)) / R
    tb = 0.18
    m = ((tb - 1.0) * T) / ((2.0 * tb - 1.0) * T - tb)
    return R, m, [float(b) for b in black]


def _pad_to_min_window(img, minwin):
    """小于固定窗口的图先镜像补到 minwin，处理完再裁回（否则会报尺寸错误）。"""
    H, W, _ = img.shape
    py = max(0, minwin - H)
    px = max(0, minwin - W)
    if py == 0 and px == 0:
        return img, None
    big = np.pad(img, ((0, py), (0, px), (0, 0)), mode='reflect')
    return big, (H, W)


def _crop_back(out, info):
    if info is None:
        return out
    H, W = info
    return np.ascontiguousarray(out[:H, :W])


def run_product(product, img, args):
    """Run a product with tiled inference and feathered blending."""
    img, rescale = rescale_to_unit(img)
    import onnxruntime as ort
    ort.set_default_logger_severity(3)
    print('[阶段] 载入模型…', flush=True)
    sess = make_session(MODELS / FILES[product], getattr(args, 'device', 'auto'))
    in_tile, out_tile = GEOM[product]
    if args.tile:
        out_tile = args.tile
        in_tile = args.tile + 2 * (GEOM[product][0] - GEOM[product][1]) // 2
    H, W, _ = img.shape
    margin = (in_tile - out_tile) // 2          # context border (0 for noise/stars)
    xs, band_x = cli_axis_origins(W, out_tile, in_tile, args.overlap)
    ys, band_y = cli_axis_origins(H, out_tile, in_tile, args.overlap)
    stride = max(1, out_tile - band_x)
    norm = CONTRACT[product]['normalization'] if not args.no_normalization else 'none'
    if args.norm_p is not None and args.norm_g is not None:
        p, g = args.norm_p, args.norm_g
        lgg = args.log10gain if args.log10gain is not None \
            else float(math.log10(g / math.asinh(g)))
    else:
        print('[阶段] 统计归一化参数…', flush=True)
        if product == 'conv':
            lp = bool(getattr(args, 'lp', False) and not getattr(args, 'correct_only', False))
            p, g, lgg = _conv_norm_params(img, lunar_planetary=lp,
                                       source_mono=bool(getattr(args, 'source_mono', False)))
        else:
            p, g, lgg = _auto_norm_params(img)
        if args.log10gain is not None:
            lgg = args.log10gain
    print(f'  {product}: 输入 {H}x{W}; 输出块 {out_tile}, 输入窗口 {in_tile} '
          f'(上下文 {margin}px), stride {stride}, {len(xs)}x{len(ys)} = {len(xs)*len(ys)} 块; '
          f'归一化 {norm}')
    print(f'    归一化参数 p={p:.6f} g={g:.1f} (log10g={np.log10(g):.4f}); '
          f'喂模型的 log10gain={lgg:.4f}')

    work = norm_forward(img, product, p, g) if not args.no_normalization else img.astype(np.float32)
    # Use zero padding in normalized space for the CONV context window.
    padmode = 'reflect' if CONTRACT[product]['reflectionPad'] else 'constant'
    padded = np.pad(work, ((margin, margin), (margin, margin), (0, 0)), mode=padmode) \
        if margin else work
    wx_all = cli_axis_weights(W, out_tile, args.overlap, len(xs))
    wy_all = cli_axis_weights(H, out_tile, args.overlap, len(ys))
    sup_x = _support_range(wx_all, len(xs), W, out_tile, args.overlap)
    sup_y = _support_range(wy_all, len(ys), H, out_tile, args.overlap)
    acc = np.zeros((H, W, 3), np.float32)
    wsum = np.zeros((H, W, 1), np.float32)
    extra = None
    n = 0
    last_el, last_n = 0.0, 0
    t0 = time.time()
    last_el, last_n = 0.0, 0
    print(f'[阶段] 逐块处理（{len(ys)}x{len(xs)} 块）…', flush=True)
    for iy, y in enumerate(ys):
        for ix, x in enumerate(xs):
            # the padded image's origin is (-margin, -margin), so shift the (possibly
            # negative) window origin into padded coordinates
            patch = padded[y + margin:y + margin + in_tile, x + margin:x + margin + in_tile]
            feed = {'input' if product != 'stars' else 'input:0': patch[None]}
            if product == 'conv':
                # catalog sinkIndex order: ss, ash, nsd*0.5, ansp, sn, log10gain
                # The public nonstellar-diameter control maps to half-scale model units.
                feed['parameters'] = _conv_model_parameters(args, lgg)
            outs = sess.run(None, feed)
            main = np.asarray(outs[0])[0]
            if margin:                          # take the centre region
                c = (main.shape[0] - out_tile) // 2
                main = main[c:c + out_tile, c:c + out_tile]
            # the model returns the CENTRE out_tile of the window, so the output tile lands at
            # (origin + margin) - that is what makes the tiles cover the image exactly
            yo, xo = y + margin, x + margin
            y0, y1 = max(0, yo), min(H, yo + out_tile)
            x0, x1 = max(0, xo), min(W, xo + out_tile)
            if y1 <= y0 or x1 <= x0:
                continue
            sub = main[y0 - yo:y1 - yo, x0 - xo:x1 - xo]
            wsub = np.outer(wy_all[iy, y0:y1], wx_all[ix, x0:x1])[:, :, None]
            acc[y0:y1, x0:x1] += sub * wsub
            wsum[y0:y1, x0:x1] += wsub
            if product == 'stars' and len(outs) > 1:
                if extra is None:
                    extra = np.zeros((H, W, 3), np.float32)
                e = np.asarray(outs[1])[0]
                if margin:
                    c = (e.shape[0] - out_tile) // 2
                    e = e[c:c + out_tile, c:c + out_tile]
                extra[y0:y1, x0:x1] += e[y0 - yo:y1 - yo, x0 - xo:x1 - xo] * wsub
            n += 1
            if n % 10 == 0:
                el = time.time() - t0
                # 预计 = 剩余时间（不是总耗时）；用近期速率平滑，避免跳变
                rate = (el - last_el) / max(1, n - last_n)
                eta = rate * (len(xs) * len(ys) - n)
                print(f'    {n}/{len(xs)*len(ys)} 块, {el:.0f}s, 预计 {eta:.0f}s', flush=True)
                last_el, last_n = el, n
    acc /= np.maximum(wsum, 1e-6)
    # wsum==0 的像元用输入补齐（同 stars/noise）
    bad = (wsum[:, :, 0] <= 0)
    if bad.any():
        acc[bad] = img[bad].astype(np.float32)
        if extra is not None:
            extra[bad] = img[bad].astype(np.float32)
        print(f'    （{int(bad.sum())} 个像元无瓦片覆盖，已用输入补齐）')
    if extra is not None:
        extra /= np.maximum(wsum, 1e-6)
    if product == 'conv' and getattr(args, 'source_mono', False):
            # A mono source is fed to the RGB model; its channels are averaged before
            # the nonlinear inverse.
        acc = np.repeat(acc.astype(np.float64).mean(axis=2, keepdims=True), 3,
                        axis=2)
    if not args.no_normalization:
        acc = norm_inverse(acc, product, p, g)
        if extra is not None:
            extra = norm_inverse(extra, product, p, g)
    # CONV's final output is clipped to [0,1], after inverse normalization.
    # LP limb ringing confirmed the lower bound: the model can produce negatives
    # Preserve the output contract for the other products.
    acc = np.clip(acc, 0.0, 1.0) if product == 'conv' else np.minimum(acc, 1.0)
    if extra is not None:
        extra = np.minimum(extra, 1.0)
    if rescale:                                  # 把入口的越界重标定反解回去
        a, b = rescale
        acc = ((acc.astype(np.float64) - b) / a).astype(np.float32)
        if extra is not None:
            extra = ((extra.astype(np.float64) - b) / a).astype(np.float32)
    print(f'  {product}: 完成, {time.time()-t0:.0f}s')
    return acc, extra


def stars_ml11_stats(img, tb=0.2):
    """stars ML11 (scheme `mtf,tb=0.2,zc=1`) 每图归一化参数 —— 见 ../stars-ml11-formula.md。

    统计量取中央 96% ROI（每边裁 floor(dim/50)），逐通道：
        A = ROI 上中位（索引 n/2，不是 np.median 的平均）
        C = ROI 均值          E = max(0, ROI 最小值)
    black[ch] = A[ch] + min_ch(E-A)；R = 1 - min(black)；T = mean_ch((C-black)/R)
    m = MTF(T; tb) —— tb 只通过 m 参与，zc 对像元无作用。
    """
    H, W, _ = img.shape
    cy, cx = H // 50, W // 50
    roi = img[cy:H - cy, cx:W - cx] if (cy or cx) else img
    n = roi.shape[0] * roi.shape[1]
    flat = roi.reshape(n, roi.shape[2]).astype(np.float64)
    A = np.partition(flat, n // 2, axis=0)[n // 2]
    C = flat.mean(axis=0)
    E = np.maximum(0.0, flat.min(axis=0))
    K = float(np.min(E - A))
    black = A + K
    R = 1.0 - float(black.min())
    T = float(np.mean((C - black) / R))
    m = ((tb - 1.0) * T) / ((2.0 * tb - 1.0) * T - tb)
    return R, m, [float(b) for b in black]


def rescale_to_unit(img):
    """Rescale only when pixels exceed [0,1], preserving the observed range."""
    lo, hi = float(img.min()), float(img.max())
    if lo < 0.0 or hi > 1.0:
        lo2, hi2 = min(lo, 0.0), max(hi, 0.0)
        a = np.float32(1.0 / (hi2 - lo2))
        b = np.float32(-lo2 * float(a))
        return (a * img.astype(np.float32) + b).astype(np.float32), (float(a), float(b))
    return img, None


def _stars_rescale_to_unit(img):
    """Match the current host reader's independent float32 scale/offset rounding."""
    lo, hi = float(img.min()), float(img.max())
    if lo < 0.0 or hi > 1.0:
        lo, hi = min(lo, 0.0), max(hi, 0.0)
        scale64 = 1.0 / (hi - lo)
        offset64 = -lo * scale64
        scale, offset = np.float32(scale64), np.float32(offset64)
        return scale * img.astype(np.float32) + offset, (float(scale), float(offset))
    return img, None


def run_stars_product(img, args):
    """stars（StarXTerminator 11）：窗口 = 瓦片 = 512，无参数张量，两个输出（去星后 + 星点层）。"""
    import onnxruntime as ort
    ort.set_default_logger_severity(3)
    print('[阶段] 载入模型…', flush=True)
    sess = make_session(MODELS / FILES['stars'], getattr(args, 'device', 'auto'))
    in_tile = out_tile = 512
    margin = 0
    H, W, _ = img.shape
    # 引擎内部现在统一是「逻辑图像」朝向（load_image 已按 ROWORDER 归一化），
    # Input orientation has already been normalized by load_image.
    work, rescale = _stars_rescale_to_unit(img)
    xs, band_x = cli_axis_origins(W, out_tile, in_tile, args.overlap)
    ys, band_y = cli_axis_origins(H, out_tile, in_tile, args.overlap)
    R, m, black = stars_ml11_stats(work)
    print(f'  stars: 输入 {H}x{W}; 窗口 {in_tile}; {len(xs)}x{len(ys)} = {len(xs)*len(ys)} 块; '
          f'R={R:.9f} m={m:.9f} black={[round(b, 9) for b in black]}'
          + (f'; 越界重标定 a={rescale[0]:.9f} b={rescale[1]:.9f}' if rescale else ''))
    wx_all = cli_axis_weights(W, out_tile, args.overlap, len(xs))
    wy_all = cli_axis_weights(H, out_tile, args.overlap, len(ys))
    sup_x = _support_range(wx_all, len(xs), W, out_tile, args.overlap)
    sup_y = _support_range(wy_all, len(ys), H, out_tile, args.overlap)
    acc = np.zeros((H, W, 3), np.float64)
    wsum = np.zeros((H, W, 1), np.float64)
    t0s = time.time()
    n = 0
    last_el, last_n = 0.0, 0
    print(f'[阶段] 逐块处理（{len(ys)}x{len(xs)} 块）…', flush=True)
    for iy, y in enumerate(ys):
        for ix, x in enumerate(xs):
            y0, x0 = max(0, y), max(0, x)
            y1, x1 = min(H, y + in_tile), min(W, x + in_tile)
            if y1 <= y0 or x1 <= x0:
                continue
            sub = work[y0:y1, x0:x1]
            # Padding is zero in normalized space. Normalizing raw zero padding
            # produces a positive context when a channel's black point is negative.
            t = np.zeros((in_tile, in_tile, 3), np.float64)
            t[y0 - y:y1 - y, x0 - x:x1 - x] = mtf_forward(sub, R, m, black)
            outs = sess.run(None, {'input:0': t.astype(np.float32)[None]})
            starless = np.asarray(outs[0])[0].astype(np.float64)
            oy, ox = y, x
            ry0, ry1 = max(0, oy), min(H, oy + out_tile)
            rx0, rx1 = max(0, ox), min(W, ox + out_tile)
            if ry1 <= ry0 or rx1 <= rx0:
                continue
            wsub = np.outer(wy_all[iy, ry0:ry1], wx_all[ix, rx0:rx1])[:, :, None]
            # Blend tiles in normalized space and apply inverse normalization once.
            acc[ry0:ry1, rx0:rx1] += starless[ry0 - oy:ry1 - oy, rx0 - ox:rx1 - ox] * wsub
            wsum[ry0:ry1, rx0:rx1] += wsub
            n += 1
            if n % 20 == 0:
                el = time.time() - t0s
                # 预计 = 剩余时间（不是总耗时）；用近期速率平滑
                rate = (el - last_el) / max(1, n - last_n)
                eta = rate * (len(xs) * len(ys) - n)
                print(f'    {n}/{len(xs)*len(ys)} 块, {el:.0f}s, 预计 {eta:.0f}s', flush=True)
                last_el, last_n = el, n
    acc = acc / np.maximum(wsum, 1e-6)
    # wsum==0 的像元（权重支撑超出瓦片输出范围）用输入补齐，避免塌成 0 的地板伪影
    bad = (wsum[:, :, 0] <= 0)
    if bad.any():
        acc[bad] = img[bad].astype(np.float32)
        print(f'    （{int(bad.sum())} 个像元无瓦片覆盖，已用输入补齐）')
    # Apply inverse normalization once after blending.
    background = np.clip(mtf_inverse(acc, R, m, black), 0.0, 1.0)
    acc = background.astype(np.float32)
    # Keep the image in the unit scale used for processing, including the
    # background and stars outputs.
    # 引擎内部统一是逻辑图像朝向（load_image 已按 ROWORDER 归一化），不再翻转
    # Clamp background before forming the stars layer in float64.
    # 星点层支持两种输出模式：
    #   默认 --stars   : stars = clip(原始 - 去星, 0, 1)
    #   --unscreen     : stars = (原始-去星) * sum(去星**k, k=0..9)
    # The second model output is not needed for this output mode.
    if not getattr(args, 'stars', False):
        return acc, None
    ref_img = work.astype(np.float64)
    if getattr(args, 'unscreen', False):
        # Use ten terms of the inverse-screen geometric series. The finite series
        # avoids the singularity near a white background.
        power = background.copy()
        factor = 1.0 + power
        for _ in range(2, 10):
            power = power * background
            factor = factor + power
        stars_out = np.clip((ref_img - background) * factor, 0.0, 1.0)
        stars_out = np.where(ref_img == 0.0, 0.0, stars_out).astype(np.float32)
    else:
        stars_out = (ref_img - background).astype(np.float32)
    # Both modes clamp stars and preserve zero-valued source pixels.
    stars_out = np.where(ref_img == 0.0, 0.0, np.clip(stars_out, 0.0, 1.0)).astype(np.float32)
    return acc, stars_out


def _window_with_boundary(img, y, x, size, mode='reflect'):
    """Sample image coordinates into a fixed HWC window, including negative origins."""
    H, W, _ = img.shape
    if H == 0 or W == 0:
        raise ValueError('Cannot sample an empty image')

    def indices(start, length):
        coords = np.arange(start, start + size, dtype=np.int64)
        if mode == 'reflect':
            if length == 1:
                return np.zeros(size, dtype=np.int64), None
            period = 2 * (length - 1)
            folded = coords % period
            return np.minimum(folded, period - folded), None
        if mode == 'constant':
            return np.clip(coords, 0, length - 1), (coords >= 0) & (coords < length)
        raise ValueError(f'Unsupported window boundary mode: {mode}')

    rows, valid_y = indices(y, H)
    cols, valid_x = indices(x, W)
    win = img[rows[:, None], cols[None, :], :]
    if mode == 'constant':
        win[~(valid_y[:, None] & valid_x[None, :])] = 0
    return np.ascontiguousarray(win)


def _noise_separation_settings(args):
    """Resolve ML3.1 host controls; explicit component options enable separation."""
    color_names = ('di', 'dc')
    freq_names = ('dhf', 'dlf')
    combined_names = ('dihf', 'dilf', 'dchf', 'dclf')

    def supplied(names):
        return any(getattr(args, 'noise_' + name, None) is not None for name in names)

    combined = supplied(combined_names)
    csep = bool(getattr(args, 'noise_csep', False) or supplied(color_names) or combined)
    fsep = bool(getattr(args, 'noise_fsep', False) or supplied(freq_names) or combined)

    def value(name, default=0.9):
        item = getattr(args, 'noise_' + name, None)
        return float(default if item is None else item)

    supplied_strengths = supplied(color_names + freq_names + combined_names)
    if supplied_strengths:
        # Explicit options cover disjoint intensity/color and HF/LF
        # bands. Unspecified bands are zero, not the GUI's 0.9 initial value.
        # For example --di 0.1 alone leaves both color bands at zero.
        bands = {'di': (0, 1), 'dc': (2, 3), 'dhf': (0, 2), 'dlf': (1, 3),
                 'dihf': (0,), 'dilf': (1,), 'dchf': (2,), 'dclf': (3,)}
        weights = [0.0] * 4
        owners = [None] * 4
        if getattr(args, 'noise_dn_explicit', False):
            raise ValueError('NOISE --dn conflicts with separate denoise options')
        for name, indices in bands.items():
            if getattr(args, 'noise_' + name, None) is None:
                continue
            for index in indices:
                if owners[index] is not None:
                    raise ValueError(f'NOISE --{name} conflicts with --{owners[index]}: '
                                     'both control the same denoise band')
                owners[index] = name
                weights[index] = value(name)
        weights = tuple(weights)
    elif csep or fsep:
        # An API/GUI caller can enable the mode before supplying controls.
        weights = (0.9,) * 4
    else:
        weights = (float(args.noise_dn),) * 4
    fs = value('fs', 5.0)
    if any(not math.isfinite(w) or not 0.0 <= w <= 1.0 for w in weights):
        raise ValueError('NOISE denoise strengths must be in [0, 1]')
    if not math.isfinite(fs) or not 1.0 <= fs <= 100.0:
        raise ValueError('NOISE frequency scale must be in [1, 100] pixels')
    return csep, fsep, weights, fs


def _noise_postprocess(t0, model, settings):
    """Separate intensity/color and high/low frequency components before feathering.

    Intensity is the arithmetic RGB mean of the residual; color is its complement.
    HF/LF is a Gaussian split with half-sample symmetric image boundaries. The
    separated mixture is clamped before inverse MTF.
    """
    csep, fsep, (dihf, dilf, dchf, dclf), fs = settings
    residual = model - t0
    if fsep:
        # BORDER_REFLECT gives consistent edge pixels for single and overlapping tiles.
        import cv2
        low = cv2.GaussianBlur(residual, (0, 0), fs, borderType=cv2.BORDER_REFLECT)
    else:
        low = residual
    if csep:
        intensity = residual.mean(axis=-1, keepdims=True)
        color = residual - intensity
        if fsep:
            intensity_low = low.mean(axis=-1, keepdims=True)
            color_low = low - intensity_low
            change = (dihf * (intensity - intensity_low) + dilf * intensity_low
                      + dchf * (color - color_low) + dclf * color_low)
        else:
            change = dihf * intensity + dchf * color
    else:
        change = dihf * (residual - low) + dilf * low
    return np.clip(t0 + change, 0.0, 1.0)


def run_noise_product(img, args):
    """InDeNoise per-tile normalize -> iterate -> mix with t0 -> denorm.

    Processing structure:
        t  = clamp((x - black[ch]) / R, 0, 1);  y = MTF(m, t)
        t_k = t_{k-1} + w_k*(model(t_{k-1}) - t_{k-1}),  w_k = 1/(it - k + 1)
        out = denorm(t0 + dn*(t_it - t0))          t0 = the first iteration's input
    Tile geometry and Hann feathering are shared with CONV.
    """
    import onnxruntime as ort
    ort.set_default_logger_severity(3)
    print('[阶段] 载入模型…', flush=True)
    sess = make_session(MODELS / FILES['noise'], getattr(args, 'device', 'auto'))
    in_tile, out_tile = GEOM['noise']
    H, W, _ = img.shape
    margin = (in_tile - out_tile) // 2
    xs, band_x = cli_axis_origins(W, out_tile, in_tile, args.overlap)
    ys, band_y = cli_axis_origins(H, out_tile, in_tile, args.overlap)
    print('[阶段] 统计归一化参数…', flush=True)
    R, m, black = noise_params(img, args.noise_params)
    it, dn = args.noise_it, args.noise_dn
    separation = _noise_separation_settings(args)
    separate = separation[0] or separation[1]
    print(f'  noise: 输入 {H}x{W}; 窗口 {in_tile}; {len(xs)}x{len(ys)} = {len(xs)*len(ys)} 块; '
          f'R={R:.9f} m={m:.9f} black={[round(b, 9) for b in black]}; it={it} dn={dn}')
    if separate:
        print(f'    分离：强度/颜色={separation[0]} 高频/低频={separation[1]}; '
              f'IHF/ILF/CHF/CLF={separation[2]}; scale={separation[3]:g}px')
    padmode = 'reflect' if CONTRACT['noise']['reflectionPad'] else 'constant'
    padded = np.pad(img.astype(np.float64), ((margin, margin), (margin, margin), (0, 0)),
                    mode=padmode) if margin else img.astype(np.float64)
    wx_all = cli_axis_weights(W, out_tile, args.overlap, len(xs))
    wy_all = cli_axis_weights(H, out_tile, args.overlap, len(ys))
    sup_x = _support_range(wx_all, len(xs), W, out_tile, args.overlap)
    sup_y = _support_range(wy_all, len(ys), H, out_tile, args.overlap)
    acc = np.zeros((H, W, 3), np.float64)
    wsum = np.zeros((H, W, 1), np.float64)
    n = 0
    last_el, last_n = 0.0, 0
    t0s = time.time()
    print(f'[阶段] 逐块处理（{len(ys)}x{len(xs)} 块）…', flush=True)
    for iy, y in enumerate(ys):
        for ix, x in enumerate(xs):
            if H < in_tile or W < in_tile:
                # Center small images in a fixed window with a negative origin.
                # Reflect original coordinates instead of applying NumPy negative slices.
                win = _window_with_boundary(img.astype(np.float64), y, x, in_tile, padmode)
            else:
                win = padded[y + margin:y + margin + in_tile, x + margin:x + margin + in_tile]
                if win.shape[0] < in_tile or win.shape[1] < in_tile:
                    win = np.pad(win, ((0, in_tile - win.shape[0]), (0, in_tile - win.shape[1]),
                                       (0, 0)), mode='reflect')
            t0 = mtf_forward(win, R, m, black)
            t = t0
            for k in range(1, it + 1):
                y_m = np.asarray(sess.run(None, {'input': t.astype(np.float32)[None]})[0])[0]
                t = t + (1.0 / (it - k + 1)) * (y_m.astype(np.float64) - t)
            # 与 stars 一致：先在归一化域拼接，最后只做一次反归一化
            out_img = _noise_postprocess(t0, t, separation) if separate else t0 + dn * (t - t0)
            yo, xo = y + margin, x + margin
            y0, y1 = max(0, yo), min(H, yo + out_tile)
            x0, x1 = max(0, xo), min(W, xo + out_tile)
            if y1 <= y0 or x1 <= x0:
                continue
            sub = out_img[y0 - yo:y1 - yo, x0 - xo:x1 - xo]
            wsub = np.outer(wy_all[iy, y0:y1], wx_all[ix, x0:x1])[:, :, None]
            acc[y0:y1, x0:x1] += sub * wsub
            wsum[y0:y1, x0:x1] += wsub
            n += 1
            if n % 20 == 0:
                el = time.time() - t0s
                # 预计 = 剩余时间（不是总耗时）；用近期速率平滑
                rate = (el - last_el) / max(1, n - last_n)
                eta = rate * (len(xs) * len(ys) - n)
                print(f'    {n}/{len(xs)*len(ys)} 块, {el:.0f}s, 预计 {eta:.0f}s', flush=True)
                last_el, last_n = el, n
    acc = acc / np.maximum(wsum, 1e-6)
    # wsum==0 的像元用输入补齐（同 stars）
    bad = (wsum[:, :, 0] <= 0)
    if bad.any():
        acc[bad] = img[bad].astype(np.float32)
        print(f'    （{int(bad.sum())} 个像元无瓦片覆盖，已用输入补齐）')
    acc = mtf_inverse(acc, R, m, black).astype(np.float32)
    # InDeNoise has no lower output clamp; preserve values below the black point
    # and clamp only the upper output bound.
    acc = np.minimum(acc, 1.0)
    print(f'  noise: 完成, {time.time()-t0s:.0f}s')
    return acc, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('--product', default='all', choices=['conv', 'noise', 'stars', 'all'])
    ap.add_argument('--tile', type=int, default=None)
    ap.add_argument('--overlap', type=float, default=0.2,
                    help='tile overlap; the default is 0.2 and it is converted into '
                         'N = 2*floor(overlap*tileSize/2) with origins by even division '
                         'for stable tile placement')
    ap.add_argument('--outdir', default=str(HERE / 'outputs'))
    ap.add_argument('--ss', type=float, default=0.5)
    ap.add_argument('--ash', type=float, default=0.0)
    ap.add_argument('--nsd', type=float, default=0.0)
    ap.add_argument('--sn', type=float, default=0.5)
    ap.add_argument('--ansp', type=float, default=1.0)
    ap.add_argument('--lp', action='store_true', default=False,
                    help='lunar/planetary mode: manual PSF, no stellar sharpening, gain=1')
    ap.add_argument('--no-lp', dest='lp', action='store_false')
    ap.add_argument('--correct-only', action='store_true', default=False,
                    help='correct PSF aberrations without sharpening (overrides lunar/planetary)')
    ap.add_argument('--log10gain', type=float, default=None,
                    help='normalization gain fed to the model; default is derived from g')
    ap.add_argument('--norm-p', type=float, default=None, help='override the black point')
    ap.add_argument('--norm-g', type=float, default=None, help='override the gain')
    ap.add_argument('--no-normalization', action='store_true',
                    help='skip the per-product normalization/inverse')
    ap.add_argument('--device', default='auto', choices=['auto', 'dml', 'cpu'],
                    help='auto：有 DirectML 就走 GPU，否则使用 CPU')
    ap.add_argument('--preview', action='store_true')
    ap.add_argument('--crop', type=int, default=512, help='1:1 星点裁剪预览边长')
    ap.add_argument('--noise-it', '--it', dest='noise_it', type=int, default=2,
                    help='iteration count (default 2; w_k = 1/(it-k+1))')
    ap.add_argument('--noise-dn', '--dn', dest='noise_dn', type=float, default=0.9,
                    help='denoise strength (default 0.9); out = t0 + dn*(t_it - t0)')
    for name in ('di', 'dc', 'dhf', 'dlf', 'dihf', 'dilf', 'dchf', 'dclf'):
        ap.add_argument('--noise-' + name, '--' + name, dest='noise_' + name,
                        type=float, default=None,
                        help='NOISE separated denoise strength; unspecified bands are zero')
    ap.add_argument('--noise-fs', '--fs', dest='noise_fs', type=float, default=None,
                    help='NOISE high/low frequency transition scale in pixels (default 5)')
    ap.add_argument('--noise-csep', '--csep', dest='noise_csep', action='store_true',
                    help='enable intensity/color controls at their default strengths')
    ap.add_argument('--noise-fsep', '--fsep', dest='noise_fsep', action='store_true',
                    help='enable high/low frequency controls at their default strengths')
    ap.add_argument('--noise-params', type=Path, default=None,
                    help='JSON with normalization values {"R":..,"m":..,"black":[..]} for noise')
    ap.add_argument('--stars', action='store_true', default=False,
                    help='STARS: also write the stars layer beside the starless output')
    ap.add_argument('--unscreen', action='store_true', default=False,
                    help='STARS: use inverse-screen stars instead of arithmetic difference')
    args = ap.parse_args()
    if not math.isfinite(args.overlap) or not 0.0 <= args.overlap <= 0.5:
        ap.error('Tile overlap must be in [0, 0.5]')
    if args.unscreen and not args.stars:
        ap.error('--unscreen requires --stars')
    args.noise_dn_explicit = any(arg.split('=')[0] in ('--dn', '--noise-dn')
                               for arg in sys.argv[1:])
    if args.product in ('noise', 'all'):
        try:
            _noise_separation_settings(args)
            if not 1 <= args.noise_it <= 5:
                raise ValueError('NOISE iterations must be in [1, 5]')
        except ValueError as exc:
            ap.error(str(exc))
    if args.noise_params is not None:
        args.noise_params = json.loads(Path(args.noise_params).read_text(encoding='utf-8'))

    out = Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)
    img, hdr = load_image(args.image)
    args.source_mono = bool(_INPUT_FRAME.get('source_mono',
                                           hdr is not None and int(hdr.get('NAXIS', 3)) == 2))
    print(f'图像 {args.image}: {img.shape} 范围 [{img.min():.6f}, {img.max():.6f}] '
          f'中位 {np.median(img):.6f}')

    # crop window for 1:1 detail preview: brightest 512x512 region
    from scipy.ndimage import uniform_filter          # noqa: F401  (optional)
    try:
        lum = img.mean(axis=2)
        k = args.crop // 4
        box = uniform_filter(lum, size=k)
        cy, cx = np.unravel_index(np.argmax(box), box.shape)
    except Exception:
        cy, cx = img.shape[0] // 2, img.shape[1] // 2
    y0 = int(np.clip(cy - args.crop // 2, 0, max(0, img.shape[0] - args.crop)))
    x0 = int(np.clip(cx - args.crop // 2, 0, max(0, img.shape[1] - args.crop)))
    print(f'1:1 裁剪窗口: y={y0} x={x0} 边长 {args.crop}')

    products = list(FILES) if args.product == 'all' else [args.product]
    lo, hi = float(np.percentile(img, 0.5)), float(np.percentile(img, 99.9))
    if args.preview:
        save_preview(out / 'input_preview.png', img, lo, hi)
        save_preview(out / f'input_crop.png', img[y0:y0 + args.crop, x0:x0 + args.crop], lo, hi)

    for p in products:
        if p == 'noise':
            res, extra = run_noise_product(img, args)
        elif p == 'stars':
            res, extra = run_stars_product(img, args)
        else:
            res, extra = run_product(p, img, args)
        stem = f'{p}_{Path(args.image).stem}'
        save_fits(out / f'{stem}.fits', res, hdr)
        d = res - img
        print(f'  {p}: 输出范围 [{res.min():.6f}, {res.max():.6f}] 中位 {np.median(res):.6f}; '
              f'与输入差 mean|Δ|={np.abs(d).mean():.6f} max|Δ|={np.abs(d).max():.6f}')
        if extra is not None:
            save_fits(out / f'{stem}_stars.fits', extra, hdr)
            print(f'  {p}: 附加输出（星点层）范围 [{extra.min():.6f}, {extra.max():.6f}]')
        if args.preview:
            save_preview(out / f'{stem}_preview.png', res, lo, hi)
            save_preview(out / f'{stem}_crop.png', res[y0:y0 + args.crop, x0:x0 + args.crop], lo, hi)
            save_preview(out / f'{stem}_crop_diff.png',
                         np.clip(np.abs(d[y0:y0 + args.crop, x0:x0 + args.crop]) * 50, 0, 1))
    print(f'\n输出目录: {out}')


if __name__ == '__main__':
    main()
