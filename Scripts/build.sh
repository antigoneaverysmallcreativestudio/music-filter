#!/bin/bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
signing_arguments=("CODE_SIGN_IDENTITY=${MUSIC_FILTER_SIGNING_IDENTITY:--}")
if [[ -n "${MUSIC_FILTER_DEVELOPMENT_TEAM:-}" ]]; then
    signing_arguments+=("DEVELOPMENT_TEAM=${MUSIC_FILTER_DEVELOPMENT_TEAM}")
fi

xcodebuild \
    -project "$project_root/FiltreMusique.xcodeproj" \
    -scheme FiltreMusique \
    -configuration Release \
    -derivedDataPath "$project_root/build" \
    "${signing_arguments[@]}" \
    build
