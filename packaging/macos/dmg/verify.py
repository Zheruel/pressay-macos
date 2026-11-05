"""Check the actual mounted installer, including Finder's saved layout."""

import pathlib
import subprocess
import sys
import tempfile

from ds_store import DSStore


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify(image):
    with tempfile.TemporaryDirectory(prefix="pressay-dmg-check-") as directory:
        mount = pathlib.Path(directory) / "volume"
        mount.mkdir()
        subprocess.run(
            ["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(image)],
            check=True, stdout=subprocess.DEVNULL,
        )
        try:
            app = mount / "Pressay.app"
            require(app.is_dir(), "Installer is missing Pressay.app")
            applications = mount / "Applications"
            require(applications.is_symlink() and str(applications.readlink()) == "/Applications", "Invalid Applications link")
            require((mount / ".background.tiff").is_file(), "Installer background is missing")
            representations = subprocess.run(
                ["tiffutil", "-info", str(mount / ".background.tiff")],
                check=True, capture_output=True, text=True,
            )
            dimensions = representations.stdout + representations.stderr
            require("Image Width: 660 Image Length: 400" in dimensions, "Missing 1x installer artwork")
            require("Image Width: 1320 Image Length: 800" in dimensions, "Missing 2x installer artwork")
            with DSStore.open(str(mount / ".DS_Store"), "r") as store:
                require(store["Pressay.app"]["Iloc"] == (170, 178), "App icon does not match the artwork")
                require(store["Applications"]["Iloc"] == (490, 178), "Applications icon does not match the artwork")
                view = store["."]["icvp"]
                require(view["iconSize"] == 128, "Incorrect Finder icon size")
                require(view["backgroundType"] == 2, "Finder is not configured to use the artwork")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
    print("Verified app signature, Applications link, background, and Finder icon layout.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify.py <disk-image>")
    verify(pathlib.Path(sys.argv[1]).resolve())
