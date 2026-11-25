#!/usr/bin/env python3
"""Check built metadata and production UI in isolated FR/EN locale processes.

Usage: python3 Scripts/check-localization.py --app '/path/Music Filter.app'
No production app is launched, no system preference is written, and no network
or Music command is used. Native permission-dialog chrome remains owned by macOS;
this checks the app name and explanation supplied to that dialog by the bundle.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def strings(path):
    return plistlib.loads(run("plutil", "-convert", "xml1", "-o", "-", str(path)).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    root = args.source_root.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleDevelopmentRegion"] == "en"
    assert info["CFBundleIdentifier"] == "dev.julienmerault.FiltreMusique"
    localized = {lang: strings(app / "Contents/Resources" / (lang + ".lproj") / "InfoPlist.strings")
                 for lang in ("en", "fr")}
    assert localized["en"]["CFBundleDisplayName"] == "Music Filter"
    assert localized["fr"]["CFBundleDisplayName"] == "Music Filter"
    for values in localized.values():
        assert values["CFBundleName"] == values["CFBundleDisplayName"]
        assert values["NSAppleEventsUsageDescription"].strip()
    cases = [
        ("French France", ["fr-FR", "en-US"], "fr"),
        ("French Canada", ["fr-CA", "en-US"], "fr"),
        ("French Belgium", ["fr-BE", "en-US"], "fr"),
        ("English", ["en-US", "fr-FR"], "en"),
        ("Arabic with secondary French", ["ar-SA", "fr-FR", "en-US"], "en"),
        ("German with secondary French", ["de-DE", "fr-FR", "en-US"], "en"),
        ("Japanese with secondary French", ["ja-JP", "fr-FR", "en-US"], "en"),
        ("Chinese with secondary French", ["zh-Hans-CN", "fr-FR", "en-US"], "en"),
        ("Hebrew with secondary French", ["he-IL", "fr-FR", "en-US"], "en"),
        ("Spanish with secondary French", ["es-ES", "fr-FR", "en-US"], "en"),
        ("No preferred language", [], "en")
    ]
    reports = []
    with tempfile.TemporaryDirectory(prefix="music-filter-language-check-") as temp:
        fixture = Path(temp) / "Localization Check.app"
        executable = fixture / "Contents/MacOS/check"
        executable.parent.mkdir(parents=True)
        resources = fixture / "Contents/Resources"
        for lang in ("en", "fr"):
            shutil.copytree(app / "Contents/Resources" / (lang + ".lproj"), resources / (lang + ".lproj"))
        fixture_info = dict(info)
        fixture_info["CFBundleIdentifier"] = "test.music-filter.localization"
        fixture_info["CFBundleExecutable"] = "check"
        (fixture / "Contents/Info.plist").write_bytes(plistlib.dumps(fixture_info))
        sources = sorted((root / "Sources/FiltreCore").glob("*.swift")) + [
            root / "Sources/FiltreMusique/MainViewController.swift",
            root / "Sources/FiltreMusique/AboutPanel.swift",
            root / "Sources/FiltreMusique/ExclusionsWindowController.swift",
            Path(__file__).with_suffix(".swift")
        ]
        run("xcrun", "swiftc", "-swift-version", "5", *map(str, sources), "-o", str(executable))
        for name, preferences, language in cases:
            argument = "(" + ",".join('"' + value + '"' for value in preferences) + ")"
            expected = localized[language]
            for mode in ("external", "runtime"):
                env = dict(os.environ, MUSIC_FILTER_LANGUAGE_CHECK=mode)
                result = json.loads(run(str(executable), "-AppleLanguages", argument, env=env))
                assert result["requested"] == preferences, (name, mode, result)
                assert result["name"] == expected["CFBundleName"], (name, mode, result)
                assert result["displayName"] == expected["CFBundleDisplayName"], (name, mode, result)
                assert result["permission"] == expected["NSAppleEventsUsageDescription"], (name, mode, result)
                if mode == "runtime":
                    assert result["effective"] == [language], (name, result)
                    assert result["layoutDirection"] == "ltr", (name, result)
                    assert result["windowVisible"] is False, "A test window became visible"
                    expected_menu = (["Exclude song", "Exclude album", "Exclude artist", "Manage exclusions (0)",
                                      "Settings", "About Music Filter", "Quit Music Filter"] if language == "en" else
                                     ["Exclure le morceau", "Exclure l’album", "Exclure l’artiste", "Gérer les exclusions (0)",
                                      "Réglages", "À propos de Music Filter", "Quitter Music Filter"])
                    cleaned = [value.replace("\ufffc", "").strip() for value in result["mainMenu"]]
                    assert cleaned == expected_menu, (name, cleaned)
                    expected_settings = (["Automatic filtering", "Filter upcoming songs (experimental)",
                                          "Allow Accessibility…", "Start with Music", "Allow in System Settings…"] if language == "en" else
                                         ["Filtrage automatique", "Filtrage anticipé (expérimental)",
                                          "Autoriser l’accessibilité…", "Démarrer avec Musique", "Autoriser dans Réglages Système…"])
                    assert result["settings"] == expected_settings, (name, result["settings"])
                    required_window = (["Search", "Excluded artists", "Excluded albums", "Excluded songs", "Recently excluded songs", "Title", "Artist"] if language == "en" else
                                       ["Rechercher", "Artistes exclus", "Albums exclus", "Morceaux exclus", "Morceaux exclus récemment", "Titre", "Artiste"])
                    assert set(required_window) <= set(result["windowText"]), (name, result["windowText"])
                    assert result["error"] == ("Enter an artist name." if language == "en" else "Saisissez le nom d’un artiste."), (name, result)
                reports.append({"case": name, "mode": mode, "language": language, "observed": result})
    report = {"app_version": info["CFBundleShortVersionString"], "app_build": info["CFBundleVersion"],
              "passed_processes": len(reports), "production_app_launched": False,
              "system_preferences_changed": False, "results": reports}
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"PASS: {len(reports)} isolated language processes; bundle name, permission text, runtime UI and LTR layout.")


if __name__ == "__main__":
    main()
