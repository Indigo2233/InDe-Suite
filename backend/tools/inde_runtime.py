"""Portable ONNX sessions for the packaged bridge; source engines stay intact."""
import sys


def make_session(model_path, device="auto"):
    import onnxruntime as ort

    if device not in ("auto", "cpu", "dml", "coreml"):
        raise ValueError(f"Unsupported compute device: {device}")
    ort.set_default_logger_severity(3)
    available = ort.get_available_providers()
    cpu = ["CPUExecutionProvider"]
    options = ort.SessionOptions()
    if device == "coreml":
        if sys.platform != "darwin" or "CoreMLExecutionProvider" not in available:
            raise RuntimeError("Core ML requires a macOS runtime with CoreMLExecutionProvider. Select CPU.")
        providers = [("CoreMLExecutionProvider", {
            "ModelFormat": "MLProgram", "MLComputeUnits": "ALL",
            "RequireStaticInputShapes": "1",
        }), *cpu]
    elif device == "dml" or (device == "auto" and sys.platform == "win32" and "DmlExecutionProvider" in available):
        if "DmlExecutionProvider" not in available:
            raise RuntimeError("DirectML is unavailable. Select CPU or Auto.")
        options.enable_mem_pattern = False
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        providers = ["DmlExecutionProvider", *cpu]
    else:
        # Core ML is explicit until validated on users' real Mac GPU/ANE hardware.
        providers = cpu
    try:
        session = ort.InferenceSession(str(model_path), sess_options=options, providers=providers)
        if device == "coreml" and "CoreMLExecutionProvider" not in session.get_providers():
            raise RuntimeError("Core ML session initialization failed. Select CPU.")
        return session
    except Exception:
        if device != "auto" or providers == cpu:
            raise
        return ort.InferenceSession(str(model_path), providers=cpu)
