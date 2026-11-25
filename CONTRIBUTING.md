# Contributing

Thank you for helping improve Music Filter.

## Report a problem

Use the project's issue tracker once its repository is published. Include the app version, macOS version, Mac architecture, primary system language, Music language and short steps to reproduce the problem. Say whether normal filtering or experimental queue filtering is involved.

Share the smallest example needed. Remove personal listening history, exclusion lists, account information and unrelated windows from screenshots or logs. Never include signing certificates, private keys, access tokens or passwords.

## Make a change

1. Build with Xcode 27 or later using `./Scripts/build.sh`, or open the `FiltreMusique` scheme in Xcode. The default build uses local ad hoc signing.
2. Keep changes focused and preserve existing exclusions and preferences. Avoid changing Music playback or its queue as part of an unattended test.
3. Provide both English and French copy. French is selected only when the primary system language is French; all other primary languages use English. French interface instructions address the user as **vous**.
4. Run the checks relevant to the change and explain what you tested. The core suite uses `swift test`; see [TESTING.md](TESTING.md) for app-level checks and their limits.
5. Submit a pull request explaining the problem, resulting behavior and validation. Include screenshots for visual changes when helpful.

Keep generated applications, build folders, private test records, user data and signing credentials out of source changes. Distribution signing and notarization use the maintainer's own credentials; contributors do not need them to build locally.

Contributed code is included under the project's [MIT license](LICENSE). For an image, icon or other third-party resource, document its origin and applicable terms; do not describe it as MIT solely because it is used by the application.

## Français

Vous pouvez proposer un signalement ou une contribution en français. Indiquez la version de l'application, celle de macOS, la langue principale du système et celle de Musique, puis les étapes permettant de reproduire le problème. Retirez les informations privées des captures et journaux. Préservez les exclusions et préférences existantes et fournissez les textes d'interface en français et en anglais.
