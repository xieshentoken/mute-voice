"""Package the standalone executable without installing or changing audio drivers."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def create_icon(source: Path, destination: Path) -> None:
    """Convert the supplied artwork into the standard macOS icon representations."""
    details = subprocess.run(
        ["/usr/bin/sips", "-g", "format", "-g", "pixelWidth", "-g", "pixelHeight", str(source)],
        check=True, capture_output=True, text=True,
    ).stdout
    metadata = dict(line.strip().split(": ", 1) for line in details.splitlines() if ": " in line)
    width = int(metadata.get("pixelWidth", "0"))
    height = int(metadata.get("pixelHeight", "0"))
    if metadata.get("format") != "png" or width != height or width < 1024:
        raise ValueError("App logo must be a square PNG at least 1024 × 1024 pixels.")

    with tempfile.TemporaryDirectory(prefix="mute-voice-icon-") as temporary:
        folder = Path(temporary)
        iconset = folder / "MuteVoice.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = str(points * scale)
                suffix = "@2x" if scale == 2 else ""
                subprocess.run(
                    ["/usr/bin/sips", "-z", pixels, pixels, str(source), "--out",
                     str(iconset / f"icon_{points}x{points}{suffix}.png")],
                    check=True, stdout=subprocess.DEVNULL,
                )
        icon = folder / "MuteVoice.icns"
        subprocess.run(
            ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(icon)],
            check=True, stdout=subprocess.DEVNULL,
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(icon, destination)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    app = root / "build" / "Mute Voice.app" / "Contents"
    create_icon(root / "mute voice logo.png", app / "Resources" / "MuteVoice.icns")
    (app / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / ".build" / "release" / "MuteVoice", app / "MacOS" / "MuteVoice")
    with (app / "Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleExecutable": "MuteVoice",
            "CFBundleIdentifier": "local.frontspark.mute-voice",
            "CFBundleName": "Mute Voice",
            "CFBundleDisplayName": "Mute Voice",
            "CFBundleIconFile": "MuteVoice.icns",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
        }, file)


if __name__ == "__main__":
    main()
