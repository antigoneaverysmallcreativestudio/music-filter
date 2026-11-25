# Testing

Scope: Music Filter 1.0.0 (62), documentation reviewed on 2026-11-25. A successful build or isolated check is not a successful installation test on another Mac.

## Automated and isolated checks

Run the core suite from the project directory:

```sh
swift test
```

The suite covers exclusion matching, collaboration credits, persistence, skip guards, queue metadata and removal confirmation, playback-session transitions and interface-language selection. It does not control a real Music playback session.

`./Scripts/build.sh` compiles the app. The release target includes Intel and Apple Silicon architectures and targets macOS 14 or later. It requires Xcode 27 or later to build. Architecture and deployment-target settings do not establish live compatibility on every supported Mac.

The `Scripts/check-menu-behavior.swift`, `Scripts/check-status-presenter.swift` and `Scripts/check-status-session.swift` harnesses exercise app components in isolation. Their results supplement the core suite; they do not replace real pointer, accessibility or playback checks.

After building, verify the language selection and built app metadata without launching Music:

```sh
python3 Scripts/check-localization.py --app "build/Build/Products/Release/Music Filter.app"
```

## Current evidence and limits

Version **1.0.0 (62)** is the first production release. It places one round options button at the bottom left of the sidebar, containing Export, Import and a confirmed Delete all exclusions command for all categories. The recent-songs heading is aligned with the window controls and gains a subtitle counting the visible recent entries (up to three); the complete list retains its total. The options button has equal 16-point left and bottom margins, verified at three sidebar widths. The six runtime resources are unchanged. The checks below distinguish current 1.0.0 results from earlier observations. The core suite, universal archive, isolated exclusions-window checks, localization checks, local update and notarized ZIP checks have passed for 1.0.0. The remaining platform and installation limits are stated below.

- All **159 core tests** passed on 2026-11-25 against the 1.0.0 sources in an isolated fixture, with no failures or skipped tests. This includes seven interface-language tests, 18 backup/import tests and five tests for clearing all exclusions: every category is removed atomically, an empty list is a no-op, write failure preserves memory and disk, and an exported backup can restore the cleared list.
- A universal Release archive of **1.0.0 (62)** succeeded on 2026-11-25. The app was installed locally, its signature verified, and it was running after relaunch. The exclusions file was byte-identical before and after the update; parsed preferences were unchanged, including after restart.
- For the notarized **1.0.0 (62)** app, **22 isolated localization processes** checked built bundle metadata and production UI: French regional variants use French; English, Arabic, Hebrew, German, Japanese, Chinese and Spanish primaries use English even with secondary French; an empty preference list uses English. The app name is Music Filter in every case. Native layout remains left-to-right. These checks do not launch the production app or change system preferences.
- The **1.0.0** exclusions window was exercised through its native UI in an isolated fixture containing five songs, one album and one artist. It showed three recent songs, five total songs, the aligned heading and the single bottom-left options button. Return in the deletion confirmation selected the default Cancel and preserved all seven rules; explicit confirmation cleared the fixture. Native import restored all seven rules with zero duplicates, and the restored rules exactly matched the backup. Production exclusions and Music playback were not changed by this fixture. Earlier export checks had also verified all three rule types and cancellation.
- The updated album icon was rendered from the actual application helper and inspected on light, dark and selected backgrounds. The installed app was relaunched while preserving exclusions and preferences.
- The persistent menu-bar capsule was checked with real pointer input on macOS 27.2.1 / Apple Silicon. Earlier menu-session and settings harnesses covered both interface languages and deferred window actions.
- Live testing on Intel, the minimum macOS version, and a clean Mac or user account remains outstanding.
- Experimental queue filtering depends on Music's visible interface and supports French and English queue labels. It can encounter unavailable metadata or an unconfirmed removal. It does not guarantee silence before every excluded track.
- The **1.0.0** distribution app is Developer ID signed, notarized by Apple and stapled. Strict signature verification, ticket validation and Gatekeeper acceptance passed again after extraction of the final release ZIP. This is local artifact verification, not a public-download or fresh-Mac launch test. Notarization is not an App Store review.

## Before a public application release

Use an intentionally prepared test account or library. Do not modify another person's listening session to run these checks.

1. Install the downloaded package in Applications on a clean Mac or user account; verify the displayed app name and first launch.
2. Check French as the primary language, then English and a non-French/non-English primary language such as Arabic, including French as a secondary preference. Expected result: French only for a French primary language, English otherwise. Check permission descriptions as well as menus and windows.
3. Check Automation permission granted and denied, then recovery after granting it. Relaunch the app after changing a previously denied permission.
4. Add and remove test song, album and artist exclusions; verify normal skipping and collaboration scope without changing saved playlists.
5. Separately test optional Accessibility permission and experimental queue removal with Music in French and English. Check open/background, minimized and closed-window states; unconfirmed removal; previous-track navigation; and permission denial.
6. Check the menu capsule, long labels, search, independent About and exclusions windows, and bringing a window forward through its menu command. Include light/dark appearance and Reduce Motion.
7. Check Start with Music, quitting, reopening, login approval and login startup.
8. Export all exclusions while a search is active; import into an empty test list, then import again. Verify restoration, no duplicates, retained dates and existing entries, cancellation and invalid-file errors. Check neutral gray menu highlighting, with the deletion command remaining red. With a filtered view active, check Delete all exclusions: Cancel is the default, cancellation preserves the list, and confirmation clears every category. Restore the test backup afterward.
9. Replace an older app with the new version and verify that exclusions and preferences remain intact.
10. For public binary distribution, verify Developer ID signing, notarization, stapling and Gatekeeper acceptance on the downloaded artifact. See [distribution status](Docs/DISTRIBUTION.md).

Record the exact version, platform, language, result and any remaining limitation. Keep private listening details and account data out of public test reports.
