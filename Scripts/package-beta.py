#!/usr/bin/env python3
"""Package an existing universal build for private testing; never publish it."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(*args, capture=False):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE if capture else None)


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def validate(app):
    info = read_plist(app / "Contents/Info.plist")
    assert info["CFBundleIdentifier"] == "dev.julienmerault.FiltreMusique"
    assert "CFBundleURLTypes" not in info
    assert not list(app.rglob("*.appex")), "Archived sharing extension must not ship"
    assert not list(app.rglob("exclusions.json")), "User data must not ship"
    resources = app / "Contents/Resources"
    expected = {"AppIcon.icns", "en.lproj/InfoPlist.strings", "fr.lproj/InfoPlist.strings",
                "MenuBarIcons/music.hand7.pdf", "MenuBarIcons/exclude-song.pdf",
                "MenuBarIcons/exclude-artist.pdf"}
    actual = {path.relative_to(resources).as_posix() for path in resources.rglob("*") if path.is_file()}
    assert actual == expected, f"Unexpected or missing runtime resources: {actual ^ expected}"
    run("codesign", "--verify", "--deep", "--strict", str(app))
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = run("lipo", "-archs", str(binary), capture=True).stdout.decode().split()
    assert set(architectures) == {"arm64", "x86_64"}, architectures
    return info, architectures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--identity", required=True, help="Installed Apple Development identity")
    args = parser.parse_args()
    if not args.identity.startswith("Apple Development:"):
        parser.error("This script is beta-only; supply an Apple Development identity.")
    root = Path(__file__).resolve().parent.parent
    info, _ = validate(args.app.resolve())
    version = info["CFBundleShortVersionString"]
    args.output.mkdir(parents=True, exist_ok=True)
    disk = args.output.resolve() / f"Music-Filter-{version}-beta-unnotarized.dmg"
    evidence = disk.with_suffix(".json")
    checksum = disk.with_suffix(".sha256")
    for path in (disk, evidence, checksum):
        if path.exists():
            parser.error(f"Refusing to overwrite existing deliverable: {path}")

    with tempfile.TemporaryDirectory(prefix="music-filter-beta-package-") as temp:
        work = Path(temp)
        payload = work / "payload"
        payload.mkdir()
        app = payload / "Music Filter.app"
        run("ditto", "--norsrc", "--noextattr", str(args.app.resolve()), str(app))
        # Re-sign only the staged copy. Drop Xcode's development debug entitlement.
        run("codesign", "--force", "--sign", args.identity, "--options", "runtime",
            "--timestamp", "--entitlements", str(root / "Configuration/App.entitlements"), str(app))
        info, architectures = validate(app)
        entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", "-", "--xml", str(app), capture=True).stdout)
        assert not entitlements.get("com.apple.security.get-task-allow", False)
        assert entitlements.get("com.apple.security.automation.apple-events") is True
        signature = subprocess.run(["codesign", "-dvv", str(app)], check=True, capture_output=True).stderr.decode()
        assert "Apple Development:" in signature and "runtime" in signature
        assert "Timestamp=" in signature, "Secure timestamp missing"
        (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
        shutil.copyfile(root / "Docs/INSTALL.fr.txt", payload / "Installation - Francais.txt")
        shutil.copyfile(root / "Docs/INSTALL.en.txt", payload / "Installation - English.txt")
        shutil.copyfile(root / "LICENSE", payload / "LICENSE.txt")
        run("hdiutil", "create", "-quiet", "-volname", f"Music Filter {version} Beta",
            "-srcfolder", str(payload), "-format", "UDZO", "-fs", "HFS+", str(disk))
        run("hdiutil", "verify", "-quiet", str(disk))
        mount = work / "verify"
        mount.mkdir()
        run("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(disk))
        try:
            mounted_info, _ = validate(mount / "Music Filter.app")
            assert mounted_info == info
            assert (mount / "Applications").is_symlink()
            assert (mount / "Applications").readlink() == Path("/Applications")
            assert len(list(mount.glob("Installation*.txt"))) == 2
        finally:
            run("hdiutil", "detach", "-quiet", str(mount))

    digest = hashlib.sha256(disk.read_bytes()).hexdigest()
    checksum.write_text(f"{digest}  {disk.name}\n")
    evidence.write_text(json.dumps({
        "version": version, "build": info["CFBundleVersion"],
        "architectures": architectures, "minimum_macos": info["LSMinimumSystemVersion"],
        "signature": "Apple Development", "hardened_runtime": True,
        "debug_entitlement": False, "notarized": False,
        "public_release_ready": False, "fresh_mac_launch_tested": False,
        "disk_integrity_verified": True, "mounted_app_signature_verified": True,
        "sha256": digest,
    }, indent=2) + "\n")
    print(f"Created beta only, not notarized: {disk}")


if __name__ == "__main__":
    main()
