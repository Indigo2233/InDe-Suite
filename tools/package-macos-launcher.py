"""Create the small, architecture-selecting macOS installer ZIP on any host."""
import hashlib
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
release = root / "release"
release.mkdir(exist_ok=True)
name = "InDe-1.0.1-setup-macos"
archive = release / (name + ".zip")
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
    for relative in ("Install-macOS.command", "setup-macos.sh", "docs/INSTALL-macOS.zh-CN.md", "NOTICE.md"):
        entry = zipfile.ZipInfo(f"{name}/{relative}")
        entry.create_system = 3
        entry.external_attr = (0o100755 if relative.endswith((".sh", ".command")) else 0o100644) << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        output.writestr(entry, (root / relative).read_bytes())
with archive.open("rb") as stream:
    digest = hashlib.file_digest(stream, "sha256").hexdigest()
(release / "SHA256SUMS-setup-macos.txt").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
print(f"{archive}\nSHA256: {digest}")
