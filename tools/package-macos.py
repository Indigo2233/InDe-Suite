"""Build a self-contained Mac release from pinned, checksum-verified inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_NAME = "InDe-1.0.1-local-windows-x64.zip"
SOURCE_URL = "https://github.com/Indigo2233/InDe-Suite/releases/download/v1.0.1-local/" + SOURCE_NAME
SOURCE_SHA = "af2033ceeb2105236a8a18861fd10422fdfbd7712dfb8a1bcb6201ad3d49e870"
PYTHON_SHA = {
    "arm64": "fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e",
    "x86_64": "a962e47df522889eaa7ff0d6a56203f1079f68aabb65ffdbe8455f362bc769f3",
}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(url, path, expected):
    if not path.exists() or sha(path) != expected:
        print(f"Downloading {path.name}", flush=True)
        urllib.request.urlretrieve(url, path)
    if sha(path) != expected:
        raise RuntimeError(f"SHA-256 mismatch: {path.name}")


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-distribution-authorized", action="store_true", required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in PYTHON_SHA:
        raise RuntimeError("Package on a native arm64 or x86_64 Mac.")
    arch = platform.machine()
    name = f"InDe-1.0.1-local-macos-{arch}"
    release = ROOT / "release"
    release.mkdir(exist_ok=True)
    stage = release / name
    if stage.exists():
        raise RuntimeError(f"Use a fresh staging directory: {stage}")
    stage.mkdir()
    downloads = ROOT / "build" / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    source = downloads / SOURCE_NAME
    download(SOURCE_URL, source, SOURCE_SHA)
    backend = stage / "InDeBackend"
    required = ["catalog.json"] + [
        f"engine/models/{n}.onnx" for n in ("InDeConv", "InDeNoise", "InDeStars")]
    with zipfile.ZipFile(source) as archive:
        for relative in required:
            suffix = "InDeBackend/" + relative
            matches = [n for n in archive.namelist() if n == suffix or n.endswith("/" + suffix)]
            if len(matches) != 1:
                raise RuntimeError(f"Ambiguous or missing release entry: {suffix}")
            destination = backend / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(matches[0]) as src, destination.open("wb") as dst:
                shutil.copyfileobj(src, dst)
    engine_destination = backend / "engine" / "run_models.py"
    engine_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "backend" / "engine" / "run_models.py", engine_destination)
    shutil.copytree(ROOT / "backend" / "tools", backend / "tools", ignore=shutil.ignore_patterns("__pycache__"))
    triplet = "aarch64" if arch == "arm64" else "x86_64"
    py_name = f"cpython-3.12.16+20261026-{triplet}-apple-darwin-install_only.tar.gz"
    py_archive = downloads / py_name
    download("https://github.com/astral-sh/python-build-standalone/releases/download/20261026/" + py_name,
             py_archive, PYTHON_SHA[arch])
    with tarfile.open(py_archive) as archive:
        archive.extractall(backend, filter="data")
    (backend / "python").rename(backend / "runtime")
    python = backend / "runtime" / "bin" / "python3"
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    run(python, "-I", "-m", "pip", "install", "--no-compile", "--only-binary=:all:",
        "numpy==2.2.6", "onnxruntime==1.23.2", "opencv-python-headless==4.12.0.88", env=env)
    run(python, "-I", "-m", "pip", "check", env=env)
    with (stage / "python-packages.txt").open("w") as output:
        run(python, "-I", "-m", "pip", "freeze", stdout=output)
    # Remove bytecode before hashing; -B also prevents runtime writes on users' Macs.
    for cache in (backend / "runtime").rglob("__pycache__"):
        shutil.rmtree(cache)
    shutil.copy2(ROOT / "build" / f"macos-{arch}" / "bin" / "InDe-pxm.dylib", stage)
    for filename in ("Install-macOS.command", "setup-macos.sh", "NOTICE.md"):
        shutil.copy2(ROOT / filename, stage)
    for filename in ("Install-macOS.command", "setup-macos.sh"):
        (stage / filename).chmod(0o755)
    (stage / "docs").mkdir()
    shutil.copy2(ROOT / "docs" / "INSTALL-macOS.zh-CN.md", stage / "docs")
    (stage / "test").mkdir()
    for filename in ("native-selftest.js", "macos-smoke.py"):
        shutil.copy2(ROOT / "test" / filename, stage / "test")
    # Retain complete SDK legal notices and the Python/wheel licenses bundled upstream.
    sdk = ROOT / "build" / "pcl-macos"
    notices = stage / "licenses" / "PCL"
    notices.mkdir(parents=True)
    shutil.copy2(sdk / "LICENSE", notices / "LICENSE")
    shutil.copy2(sdk / "COPYING.md", notices / "COPYING.md")
    for dependency in ("lcms", "lz4", "zlib", "zstd"):
        shutil.copy2(sdk / "src" / "3rdparty" / dependency / "LICENSE", notices / f"{dependency}-LICENSE")
    shutil.copy2(sdk / "src/3rdparty/cminpack/CopyrightMINPACK.txt", notices)
    # RFC6234 carries its license in source headers rather than a LICENSE file.
    rfc_notices = notices / "RFC6234"
    rfc_notices.mkdir()
    for source in (sdk / "src/3rdparty/RFC6234").iterdir():
        if source.suffix in (".c", ".h"):
            shutil.copy2(source, rfc_notices)
    metadata = {"version": "1.0.1", "platform": "macos", "architecture": arch,
                "minimumMacOS": "14.0", "pclCommit": "201860a364c05308cde8271f5ca517b69b487fa1",
                "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "modelSourceSHA256": SOURCE_SHA, "pythonSourceSHA256": PYTHON_SHA[arch],
                "pixInsightUITested": False, "coreML": "experimental"}
    (stage / "package-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    (stage / "architecture.txt").write_text(arch + "\n", encoding="ascii")
    run(python, "-I", "-B", stage / "test" / "macos-smoke.py", "--package", stage)
    # Include symlink targets in a separate list, so relocation remains checkable.
    files, links = [], []
    for path in sorted(stage.rglob("*")):
        relative = path.relative_to(stage).as_posix()
        if path.is_symlink():
            links.append(f"{os.readlink(path)}\t{relative}")
        elif path.is_file():
            files.append(f"{sha(path)}  {relative}")
    (stage / "package-links.txt").write_text("\n".join(links) + "\n", encoding="utf-8")
    files.append(f"{sha(stage / 'package-links.txt')}  package-links.txt")
    (stage / "package-sha256.txt").write_text("\n".join(files) + "\n", encoding="utf-8")
    archive_path = release / (name + ".tar.gz")
    with tarfile.open(archive_path, "w:gz") as archive:
        archive.add(stage, arcname=name)
    (release / f"SHA256SUMS-macos-{arch}.txt").write_text(
        f"{sha(archive_path)}  {archive_path.name}\n", encoding="ascii")
    print(f"Packaged {archive_path}", flush=True)


if __name__ == "__main__":
    main()
