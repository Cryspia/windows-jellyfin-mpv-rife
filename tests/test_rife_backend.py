from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import hashlib
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "assets/examples/rife_backend.py.example"
LOADER = SourceFileLoader("rife_backend_test", str(SOURCE))
MODULE = module_from_spec(spec_from_loader(LOADER.name, LOADER))
LOADER.exec_module(MODULE)


class BackendCacheTests(unittest.TestCase):
    def setUp(self):
        tmp = self.enterContext(TemporaryDirectory())
        self.directory = Path(tmp)
        self.enterContext(patch.object(MODULE, "__file__", str(self.directory / "rife_backend.py")))
        self.enterContext(patch.dict(os.environ, RIFE_TRT_CACHE_DIR=str(self.directory / "cache")))
        torch = SimpleNamespace(
            __version__="2.14.0+cu130",
            version=SimpleNamespace(cuda="13.0"),
            cuda=SimpleNamespace(get_device_name=lambda _: "Test RTX"),
        )
        self.enterContext(patch.dict(sys.modules, torch=torch))
        self.find_spec = self.enterContext(patch.object(MODULE.importlib.util, "find_spec", return_value=None))
        self.import_runtime = self.enterContext(patch.object(MODULE.importlib, "import_module"))
        self.enterContext(patch.object(MODULE.importlib.metadata, "distribution",
                                       side_effect=MODULE.importlib.metadata.PackageNotFoundError))
        self.enterContext(patch.object(MODULE.importlib.metadata, "version", return_value="2.14.0"))
        self.addCleanup(MODULE.profile.cache_clear)

    def write_profile(self, backend, version, precision="mixed"):
        data = dict(backend=backend, version=version, precision=precision, bridge="2.14.0",
                    torch="2.14.0+cu130", cuda="13.0", gpu="Test RTX")
        fingerprint = hashlib.sha256(b"2.14.0|2.14.0+cu130|13.0|Test RTX").hexdigest()[:16]
        data["namespace"] = f"v1-{backend}-{version}-{precision}-{fingerprint}"
        (self.directory / "rife-backend.json").write_text(json.dumps(data), "utf-8")
        self.import_runtime.return_value = SimpleNamespace(__version__=version)
        MODULE.profile.cache_clear()

    def test_engine_and_marker_namespaces_are_isolated(self):
        self.write_profile("standard", "11.1.0.106")
        standard = MODULE.cache_dir()
        (standard / "test.ok").touch()
        self.write_profile("rtx", "1.6.1.120")
        rtx = MODULE.cache_dir()
        self.assertNotEqual(rtx, standard)
        self.assertFalse((rtx / "test.ok").exists())
        self.write_profile("rtx", "1.6.1.120", "fp32")
        self.assertNotEqual(MODULE.cache_dir(), rtx)

    def test_conflicting_bindings_fail_before_import(self):
        self.write_profile("rtx", "1.6.1.120")
        self.find_spec.return_value = object()
        with self.assertRaisesRegex(RuntimeError, "conflicting TensorRT"):
            MODULE.cache_dir()
        self.import_runtime.assert_not_called()

    def test_runtime_version_mismatch_cannot_use_existing_engine(self):
        self.write_profile("rtx", "1.6.1.120")
        self.import_runtime.return_value = SimpleNamespace(__version__="1.7.0")
        with self.assertRaisesRegex(RuntimeError, "package versions changed"):
            MODULE.cache_dir()
        self.assertFalse((self.directory / "cache").exists())


if __name__ == "__main__":
    unittest.main()
