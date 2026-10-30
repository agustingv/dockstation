"""Fills the download page template with a release's packages.

Usage: python3 site/render.py <version> <deb> <rpm> <download base URL> <out dir>
"""

import hashlib
import re
import shutil
import sys
from pathlib import Path

ICON = "data/icons/hicolor/scalable/apps/io.github.agustingv.dockstation.svg"


def size(path: Path) -> str:
    mb = path.stat().st_size / 1_000_000
    return f"{mb:.1f} MB".replace(".", ",")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    version, deb, rpm, base, out = sys.argv[1:]
    deb, rpm, out = Path(deb), Path(rpm), Path(out)
    values = {
        "VERSION": version,
        "DEB": deb.name,
        "RPM": rpm.name,
        "DEB_URL": f"{base}/{deb.name}",
        "RPM_URL": f"{base}/{rpm.name}",
        "DEB_SIZE": size(deb),
        "RPM_SIZE": size(rpm),
        "DEB_SHA256": sha256(deb),
        "RPM_SHA256": sha256(rpm),
    }
    page = (Path(__file__).parent / "index.html").read_text()
    for key, value in values.items():
        page = page.replace(f"@{key}@", value)
    if re.search(r"@[A-Z0-9_]+@", page):
        sys.exit("Unfilled placeholders left in the page")
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    (out / "index.html").write_text(page)
    shutil.copy(Path(__file__).parent.parent / ICON, out / "dockstation.svg")


if __name__ == "__main__":
    main()
