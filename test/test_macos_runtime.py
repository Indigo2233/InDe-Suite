import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("inde_runtime", Path(__file__).resolve().parents[1] / "backend/tools/inde_runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ProviderTests(unittest.TestCase):
    def fake(self, providers, fail_dml=False, drop_coreml=False):
        self.calls = []
        def create(path, **kwargs):
            self.calls.append(kwargs)
            selected = kwargs["providers"]
            if fail_dml and "DmlExecutionProvider" in selected:
                raise RuntimeError("driver error")
            active = [p[0] if isinstance(p, tuple) else p for p in selected]
            if drop_coreml:
                active = ["CPUExecutionProvider"]
            return SimpleNamespace(get_providers=lambda: active)
        return SimpleNamespace(set_default_logger_severity=lambda v: None,
                               get_available_providers=lambda: providers,
                               SessionOptions=SimpleNamespace,
                               ExecutionMode=SimpleNamespace(ORT_SEQUENTIAL=0), InferenceSession=create)

    def test_mac_auto_uses_cpu_even_with_coreml(self):
        ort = self.fake(["CoreMLExecutionProvider", "CPUExecutionProvider"])
        with patch.dict("sys.modules", onnxruntime=ort), patch.object(runtime.sys, "platform", "darwin"):
            runtime.make_session("model", "auto")
        self.assertEqual(self.calls[0]["providers"], ["CPUExecutionProvider"])

    def test_coreml_fallback_nodes_and_failed_initialization(self):
        ort = self.fake(["CoreMLExecutionProvider", "CPUExecutionProvider"])
        with patch.dict("sys.modules", onnxruntime=ort), patch.object(runtime.sys, "platform", "darwin"):
            runtime.make_session("model", "coreml")
        self.assertEqual(self.calls[0]["providers"][-1], "CPUExecutionProvider")
        ort = self.fake(["CoreMLExecutionProvider"], drop_coreml=True)
        with patch.dict("sys.modules", onnxruntime=ort), patch.object(runtime.sys, "platform", "darwin"):
            with self.assertRaisesRegex(RuntimeError, "initialization failed"):
                runtime.make_session("model", "coreml")

    def test_windows_auto_fallback_but_explicit_dml_reports_failure(self):
        ort = self.fake(["DmlExecutionProvider", "CPUExecutionProvider"], fail_dml=True)
        with patch.dict("sys.modules", onnxruntime=ort), patch.object(runtime.sys, "platform", "win32"):
            runtime.make_session("model")
            self.assertEqual(self.calls[-1]["providers"], ["CPUExecutionProvider"])
            with self.assertRaisesRegex(RuntimeError, "driver error"):
                runtime.make_session("model", "dml")

    def test_wrong_platform_reports_unavailable_provider(self):
        ort = self.fake(["CPUExecutionProvider"])
        with patch.dict("sys.modules", onnxruntime=ort), patch.object(runtime.sys, "platform", "darwin"):
            with self.assertRaisesRegex(RuntimeError, "DirectML"):
                runtime.make_session("model", "dml")
        with patch.dict("sys.modules", onnxruntime=ort), patch.object(runtime.sys, "platform", "win32"):
            with self.assertRaisesRegex(RuntimeError, "Core ML"):
                runtime.make_session("model", "coreml")


if __name__ == "__main__":
    unittest.main()
