#!/usr/bin/env python3
"""Prepare a source-only Music Filter archive. Does not publish or sign anything."""
import argparse
import hashlib
import plistlib
import stat
import zipfile
from pathlib import Path


ROOT_FILES = (
    ".gitignore", "LICENSE", "Package.swift", "README.md", "README.fr.md",
    "CONTRIBUTING.md", "TESTING.md", "THIRD_PARTY_NOTICES.md",
)
DIRECTORIES = ("Configuration", "Docs", "FiltreMusique.xcodeproj",
               "Scripts", "Sources", "Tests")
RESOURCE_FILES = (
    "Resources/AppIcon.icns",
    "Resources/en.lproj/InfoPlist.strings", "Resources/fr.lproj/InfoPlist.strings",
    "Resources/MenuBarIcons/music.hand7.pdf",
    "Resources/MenuBarIcons/exclude-song.pdf", "Resources/MenuBarIcons/exclude-artist.pdf",
    "Artwork/README.md", "Artwork/AppIcon/music.hand4.svg", "Artwork/AppIcon/music.hand4.pdf",
    "Artwork/MenuIcons/music.hand7.svg",
    "Artwork/MenuIcons/exclude-song.svg", "Artwork/MenuIcons/exclude-artist.svg",
)
EXCLUDED_PARTS = {".git", ".build", "build", "DerivedData", "Deliverables",
                  "xcuserdata", "__pycache__"}
PRIVATE_SUFFIXES = {".p12", ".p8", ".key", ".mobileprovision", ".provisionprofile"}


def source_files(root):
    candidates = [root / name for name in (*ROOT_FILES, *RESOURCE_FILES)]
    for name in DIRECTORIES:
        directory = root / name
        if not directory.is_dir():
            raise ValueError(f"Missing source directory: {name}")
        candidates.extend(directory.rglob("*"))
    result = []
    for path in candidates:
        relative = path.relative_to(root)
        if any(part in EXCLUDED_PARTS for part in relative.parts):
            continue
        if path.name == ".DS_Store" or path.suffix in {".xcuserstate", ".pyc"}:
            continue
        if path.is_symlink():
            raise ValueError(f"Unexpected symlink in sources: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError(f"Missing source file: {relative}")
        if path.suffix in PRIVATE_SUFFIXES or path.name in {".env", "exclusions.json"}:
            raise ValueError(f"Private data must not ship: {relative}")
        result.append(path)
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    info = plistlib.loads((root / "Configuration/App-Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    files = source_files(root)
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / f"Music-Filter-{version}-sources.zip"
    checksum = destination.with_suffix(".sha256")
    if destination.exists() or checksum.exists():
        parser.error("Refusing to overwrite an existing source deliverable.")
    prefix = f"Music-Filter-{version}"
    with zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            relative = path.relative_to(root)
            member = zipfile.ZipInfo(f"{prefix}/{relative.as_posix()}")
            member.create_system = 3
            member.compress_type = zipfile.ZIP_DEFLATED
            # Preserve directly runnable scripts after a normal unzip. Swift
            # checker files without a shebang are compiled explicitly instead.
            data = path.read_bytes()
            mode = 0o755 if data.startswith(b"#!") else 0o644
            member.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(member, data)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("Source archive integrity check failed.")
        for path in files:
            name = f"{prefix}/{path.relative_to(root).as_posix()}"
            if archive.read(name) != path.read_bytes():
                raise RuntimeError(f"Source changed during packaging: {name}")
        build_mode = archive.getinfo(f"{prefix}/Scripts/build.sh").external_attr >> 16
        if not build_mode & stat.S_IXUSR:
            raise RuntimeError("The build script is not executable in the archive.")
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    checksum.write_text(f"{digest}  {destination.name}\n")
    print(f"Verified {len(files)} source files: {destination}")


if __name__ == "__main__":
    main()
