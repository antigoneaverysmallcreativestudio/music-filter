#!/usr/bin/env python3
"""Prepare a verified local Music Filter release; never publish it.

Use --notarized-app for an already stapled app exported by Xcode (ZIP output).
Otherwise, credentials must already be stored in a notarytool Keychain profile
(DMG output). A private work directory retains submission IDs and logs, so
--resume never resubmits a completed upload. The source and installed apps are
never modified.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


RESOURCES = {
    "AppIcon.icns", "en.lproj/InfoPlist.strings", "fr.lproj/InfoPlist.strings",
    "MenuBarIcons/music.hand7.pdf", "MenuBarIcons/exclude-song.pdf",
    "MenuBarIcons/exclude-artist.pdf",
}
MACHO_MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca",
)}
INSTALL = {
    "English": """Music Filter

Drag Music Filter into Applications, then open it from Applications.
Music Filter appears in the menu bar. French is used when your primary system
language is French; every other primary language uses English.

Allow control of Music when macOS requests it. The optional experimental queue
filter also needs Accessibility permission. Your exclusions remain on this Mac.
Open the bottom-left … menu in Manage exclusions to export or import a local
JSON backup. Delete all exclusions clears only this filter’s list after
confirmation; it does not delete songs from Music.

This application is signed with Developer ID and notarized by Apple.
Notarization is a security check, not an App Store review or an Apple endorsement.
""",
    "Francais": """Music Filter

Glissez Music Filter dans Applications, puis ouvrez-la depuis Applications.
Music Filter apparaît dans la barre des menus. L'interface est en français si
votre langue principale est le français, et en anglais pour toute autre langue.

Autorisez le contrôle de Musique lorsque macOS le demande. Le filtrage anticipé
expérimental nécessite aussi l'autorisation Accessibilité. Vos exclusions restent
sur ce Mac. Le menu … en bas à gauche de Gérer les exclusions permet
d’exporter ou d’importer une sauvegarde JSON locale. Supprimer toutes les
exclusions efface uniquement la liste du filtre, après confirmation ; aucun
morceau n’est supprimé dans Musique.

Cette application est signée avec Developer ID et notarisée par Apple.
La notarisation est un contrôle de sécurité, pas un examen App Store ni une
recommandation d'Apple.
""",
}


def run(*arguments, capture=False):
    return subprocess.run(arguments, check=True, capture_output=capture)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def bundle_digest(app):
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix().encode()
        if path.is_symlink():
            digest.update(b"L" + relative + b"\0" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(b"F" + relative + b"\0" + path.read_bytes())
    return digest.hexdigest()


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as file:
        return file.read(4) in MACHO_MAGIC


def strip_forbidden_attributes(app):
    """Remove only signing-forbidden Finder metadata from a private staged copy.

    Keep all other attributes and the notarization ticket. FileProvider folders
    can add FinderInfo to an app root, so staging also lives outside Documents.
    """
    for path in (app, *app.rglob("*")):
        if path.is_symlink():
            continue
        # Apple's system Python does not expose os.listxattr/removexattr.
        present = run("xattr", str(path), capture=True).stdout.decode().splitlines()
        for attribute in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
            if attribute in present:
                run("xattr", "-d", attribute, str(path))


def copy_new_file(source, destination):
    """Copy only bytes, without overwriting or carrying filesystem metadata."""
    with destination.open("xb") as target:
        with source.open("rb") as original:
            shutil.copyfileobj(original, target)


def validate_app(app, distribution=False):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "dev.julienmerault.FiltreMusique", "Wrong application bundle.")
    require("CFBundleURLTypes" not in info, "Sharing URL handlers must not ship.")
    require(not list(app.rglob("*.appex")), "The retired sharing extension must not ship.")
    require(not list(app.rglob("exclusions.json")), "User exclusions must not ship.")
    resources = app / "Contents/Resources"
    actual = {p.relative_to(resources).as_posix() for p in resources.rglob("*") if p.is_file()}
    require(actual == RESOURCES, f"Unexpected or missing runtime resources: {sorted(actual ^ RESOURCES)}")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    binaries = [p for p in app.rglob("*") if is_macho(p)]
    require(bool(binaries), "The application contains no executable.")
    for binary in binaries:
        architectures = run("lipo", "-archs", str(binary), capture=True).stdout.decode().split()
        require(set(architectures) == {"arm64", "x86_64"}, f"Not universal: {binary.name}")
        if distribution:
            validate_signature(binary, runtime=True)
    if distribution:
        validate_signature(app, runtime=True)
        entitlements = read_entitlements(app)
        require(entitlements.get("com.apple.security.automation.apple-events") is True,
                "Apple Events entitlement missing.")
    return info


def read_entitlements(path):
    data = run("codesign", "-d", "--entitlements", "-", "--xml", str(path), capture=True).stdout
    return plistlib.loads(data) if data.strip() else {}


def validate_signature(path, runtime=False):
    signature = run("codesign", "-dvv", str(path), capture=True).stderr.decode()
    require("Authority=Developer ID Application:" in signature, "Developer ID signature missing.")
    require("Timestamp=" in signature, "Secure timestamp missing.")
    if runtime:
        require("runtime" in signature, "Hardened runtime missing.")
        entitlements = read_entitlements(path)
        require(not entitlements.get("com.apple.security.get-task-allow", False),
                "Debug entitlement must not ship.")


def sign_app(app, identity, work, root):
    # Sign nested binaries and bundles inside-out, without codesign --deep.
    nested = [p for p in app.rglob("*") if is_macho(p)
              or (p.is_dir() and not p.is_symlink() and p.suffix in {".app", ".xpc", ".framework"})]
    main = app / "Contents/MacOS" / plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    for index, path in enumerate(sorted((p for p in nested if p != main), key=lambda p: len(p.parts), reverse=True)):
        entitlements = read_entitlements(path)
        entitlements.pop("com.apple.security.get-task-allow", None)
        entitlement_path = work / f"nested-entitlements-{index}.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        run("codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
            "--entitlements", str(entitlement_path), str(path))
    run("codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
        "--entitlements", str(root / "Configuration/App.entitlements"), str(app))


def notarize(path, stage, args, work, state):
    record = state.setdefault(stage, {})
    credentials = ("--keychain-profile", args.keychain_profile)
    if "id" not in record:
        print(f"Uploading {stage} to Apple…", flush=True)
        result = run("xcrun", "notarytool", "submit", str(path), *credentials,
                     "--no-wait", "--output-format", "json", capture=True)
        submission = json.loads(result.stdout)
        require(bool(submission.get("id")), "Apple did not return a submission ID.")
        record["id"] = submission["id"]
        write_json(work / "state.json", state)
    identifier = record["id"]
    deadline = time.monotonic() + args.wait_minutes * 60
    while True:
        status = json.loads(run("xcrun", "notarytool", "info", identifier, *credentials,
                                "--output-format", "json", capture=True).stdout)
        record["status"] = status["status"]
        write_json(work / "state.json", state)
        print(f"Apple {stage}: {status['status']} ({identifier})", flush=True)
        if status["status"] != "In Progress":
            log = work / f"{stage}-notarization-log.json"
            if not log.exists():
                run("xcrun", "notarytool", "log", identifier, *credentials, str(log))
            require(status["status"] == "Accepted", f"Apple rejected {stage}; inspect {log}.")
            issues = json.loads(log.read_text()).get("issues") or []
            print(f"Apple {stage}: {len(issues)} log issue(s); log saved to {log}.", flush=True)
            return identifier
        require(time.monotonic() < deadline,
                "Apple is still processing. Run the same command with --resume to continue without uploading again.")
        # The service's wait command handles polling. Limit each wait to 50 seconds
        # so the caller receives regular status updates; a timeout is not a failure.
        wait = subprocess.run(("xcrun", "notarytool", "wait", identifier, *credentials,
                               "--timeout", "50s", "--output-format", "json"), capture_output=True)
        diagnostic = (wait.stdout + wait.stderr).lower()
        if wait.returncode and not any(message in diagnostic for message in (b"timeout", b"timed out")):
            raise RuntimeError("Apple's wait request failed. Submission ID is saved; use --resume to retry.")


def package_notarized_app(args, root, source, info):
    """Package an Xcode-notarized app without changing its signature or ticket.

    ZIP files cannot carry a staple themselves. The contained app retains its
    ticket, and is verified again after a normal archive extraction.
    """
    validate_app(source, distribution=True)
    run("xcrun", "stapler", "validate", str(source))
    run("spctl", "--assess", "--type", "execute", "--verbose=2", str(source))
    version = info["CFBundleShortVersionString"]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stem = f"Music-Filter-{version}"
    destination = output / f"{stem}.zip"
    evidence = output / f"{stem}.json"
    checksum = output / f"{stem}.sha256"
    for path in (destination, evidence, checksum):
        require(not path.exists(), f"Refusing to overwrite deliverable: {path}")
    with tempfile.TemporaryDirectory(prefix="music-filter-release-zip-", dir="/private/tmp") as temporary:
        work = Path(temporary)
        payload = work / f"Music Filter {version}"
        payload.mkdir()
        staged = payload / "Music Filter.app"
        # Preserve the notarization ticket and metadata from Xcode's exported app.
        run("ditto", str(source), str(staged))
        strip_forbidden_attributes(staged)
        require(validate_app(staged, distribution=True) == info, "Staged app metadata differs.")
        run("xcrun", "stapler", "validate", str(staged))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(staged))
        for language, content in INSTALL.items():
            (payload / f"Installation - {language}.txt").write_text(content)
        shutil.copyfile(root / "LICENSE", payload / "LICENSE.txt")
        archive = work / destination.name
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(archive))
        extracted = work / "verify-extracted"
        run("ditto", "-x", "-k", str(archive), str(extracted))
        extracted_payload = extracted / payload.name
        extracted_app = extracted_payload / "Music Filter.app"
        require(validate_app(extracted_app, distribution=True) == info, "Extracted app metadata differs.")
        run("xcrun", "stapler", "validate", str(extracted_app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(extracted_app))
        for language, content in INSTALL.items():
            require((extracted_payload / f"Installation - {language}.txt").read_text() == content,
                    "Extracted installation instructions differ.")
        require((extracted_payload / "LICENSE.txt").read_bytes() == (root / "LICENSE").read_bytes(),
                "Extracted license differs.")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        copy_new_file(archive, destination)
        require(hashlib.sha256(destination.read_bytes()).hexdigest() == digest, "Final ZIP differs from verified archive.")
        with checksum.open("x") as file:
            file.write(f"{digest}  {destination.name}\n")
        with evidence.open("x") as file:
            json.dump({"version": version, "build": info["CFBundleVersion"], "container": "zip",
                       "architectures": ["arm64", "x86_64"], "minimum_macos": info["LSMinimumSystemVersion"],
                       "signature": "Developer ID Application", "hardened_runtime": True,
                       "debug_entitlement": False, "app_notarized": True, "app_ticket_stapled": True,
                       "signature_preserved": True, "gatekeeper_accepted": True,
                       "extracted_app_signature_verified": True, "fresh_mac_launch_tested": False,
                       "published": False, "sha256": digest}, file, indent=2)
            file.write("\n")
    print(f"Verified ZIP containing the notarized, stapled app: {destination}", flush=True)
    print("ZIP containers are not stapled; the app's ticket is retained. No public publication was performed.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--identity", help="Installed Developer ID Application identity (DMG workflow only)")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--keychain-profile", help="Existing notarytool Keychain profile; sign/notarize a DMG; never a password")
    mode.add_argument("--notarized-app", action="store_true", help="Package an already signed/stapled app as ZIP; no re-signing or credentials")
    parser.add_argument("--wait-minutes", type=int, default=60, help="Maximum wait per submission (default: 60)")
    parser.add_argument("--resume", action="store_true", help="Continue the exact same staged release and saved submission IDs")
    args = parser.parse_args()
    if not args.notarized_app and not (args.identity or "").startswith("Developer ID Application:"):
        parser.error("Supply a Developer ID Application identity; development or ad hoc signatures cannot release.")
    if args.notarized_app and (args.identity or args.resume):
        parser.error("--notarized-app does not use --identity or --resume.")
    if args.wait_minutes < 1:
        parser.error("--wait-minutes must be positive.")
    root = Path(__file__).resolve().parent.parent
    source = args.app.resolve()
    info = validate_app(source)
    version = info["CFBundleShortVersionString"]
    require(re.fullmatch(r"[A-Za-z0-9._-]+", version), "Unsafe version string.")
    if args.notarized_app:
        package_notarized_app(args, root, source, info)
        return
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stem = f"Music-Filter-{version}"
    destination = output / f"{stem}.dmg"
    evidence = output / f"{stem}.json"
    checksum = output / f"{stem}.sha256"
    for path in (destination, evidence, checksum):
        require(not path.exists(), f"Refusing to overwrite deliverable: {path}")
    work = output / f".{stem}-notarization-work"
    manifest = {"source_digest": bundle_digest(source), "identity": args.identity,
                "version": version, "build": info["CFBundleVersion"]}
    if args.resume:
        state = json.loads((work / "state.json").read_text())
        require(state["input"] == manifest, "Source app or signing identity changed; use a new output directory.")
    else:
        work.mkdir(mode=0o700)
        state = {"input": manifest}
        write_json(work / "state.json", state)
    payload = work / "payload"
    app = payload / "Music Filter.app"
    if not state.get("signed"):
        require(not state.get("app", {}).get("id"), "Cannot re-sign an app already uploaded.")
        if payload.exists():
            shutil.rmtree(payload)
        payload.mkdir()
        run("ditto", "--norsrc", "--noextattr", str(source), str(app))
        print("Signing staged application…", flush=True)
        sign_app(app, args.identity, work, root)
        validate_app(app, distribution=True)
        state["signed"] = True
        write_json(work / "state.json", state)
    archive = work / "Music Filter.zip"
    if not archive.exists():
        run("ditto", "-c", "-k", "--keepParent", str(app), str(archive))
    app_id = notarize(archive, "app", args, work, state)
    run("xcrun", "stapler", "staple", str(app))
    run("xcrun", "stapler", "validate", str(app))
    validate_app(app, distribution=True)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    disk = work / f"{stem}.dmg"
    if not state.get("disk_created"):
        require(not state.get("disk", {}).get("id"), "Cannot rebuild a disk already uploaded.")
        applications = payload / "Applications"
        if not applications.is_symlink():
            applications.symlink_to("/Applications", target_is_directory=True)
        for language, content in INSTALL.items():
            (payload / f"Installation - {language}.txt").write_text(content)
        shutil.copyfile(root / "LICENSE", payload / "LICENSE.txt")
        if disk.exists():
            disk.unlink()  # Only an incomplete, private staged disk can be replaced.
        run("hdiutil", "create", "-quiet", "-volname", f"Music Filter {version}", "-srcfolder",
            str(payload), "-format", "UDZO", "-fs", "HFS+", str(disk))
        run("codesign", "--sign", args.identity, "--timestamp", str(disk))
        state["disk_created"] = True
        write_json(work / "state.json", state)
    run("hdiutil", "verify", "-quiet", str(disk))
    disk_id = notarize(disk, "disk", args, work, state)
    run("xcrun", "stapler", "staple", str(disk))
    run("xcrun", "stapler", "validate", str(disk))
    run("codesign", "--verify", "--strict", str(disk))
    validate_signature(disk)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
        "--verbose=2", str(disk))
    mount = work / "verify-mount"
    mount.mkdir(exist_ok=True)
    run("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(disk))
    try:
        mounted_app = mount / "Music Filter.app"
        require(validate_app(mounted_app, distribution=True) == info, "Mounted app metadata differs.")
        run("xcrun", "stapler", "validate", str(mounted_app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(mounted_app))
        require((mount / "Applications").is_symlink() and (mount / "Applications").readlink() == Path("/Applications"),
                "Applications shortcut missing.")
        for language, content in INSTALL.items():
            require((mount / f"Installation - {language}.txt").read_text() == content, "Installation instructions differ.")
    finally:
        run("hdiutil", "detach", "-quiet", str(mount))
    digest = hashlib.sha256(disk.read_bytes()).hexdigest()
    # Atomic, no-overwrite publication into the local deliverable directory.
    os.link(disk, destination)
    with checksum.open("x") as file:
        file.write(f"{digest}  {destination.name}\n")
    with evidence.open("x") as file:
        json.dump({"version": version, "build": info["CFBundleVersion"],
                   "architectures": ["arm64", "x86_64"], "minimum_macos": info["LSMinimumSystemVersion"],
                   "signature": "Developer ID Application", "hardened_runtime": True,
                   "debug_entitlement": False, "notarized": True,
                   "app_submission_id": app_id, "disk_submission_id": disk_id,
                   "app_ticket_stapled": True, "disk_ticket_stapled": True,
                   "gatekeeper_accepted": True, "disk_integrity_verified": True,
                   "mounted_app_signature_verified": True, "fresh_mac_launch_tested": False,
                   "published": False, "sha256": digest}, file, indent=2)
        file.write("\n")
    print(f"Verified notarized local release: {destination}", flush=True)
    print("No upload to a public download service was performed. Fresh-Mac launch remains untested.", flush=True)


if __name__ == "__main__":
    main()
