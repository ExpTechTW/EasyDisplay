#!/bin/zsh
# Builds, bundles and signs build/EasyDisplay.app.
#
#   scripts/build-app.sh              release build, signed with your Developer ID or Apple Development certificate
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY=- scripts/build-app.sh   ad-hoc signature
#   ARCHIVE=1 scripts/build-app.sh    also zip it as build/EasyDisplay-<label>.zip, the file a GitHub release carries
#   NOTARIZE=1 scripts/build-app.sh   also have Apple notarize it, so a download opens without Gatekeeper's warning.
#                                     Needs a Developer ID signature, APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD (made at
#                                     account.apple.com → Sign-In and Security → App-Specific Passwords); the team comes
#                                     from the signature unless APPLE_TEAM_ID says otherwise.
#
# The version comes from scripts/version.sh; EASYDISPLAY_LABEL/_TRAIN/_CODE/_DATE/_PRERELEASE override it (CI passes
# the values it has checked). Without git history the build is `dev`, build 0.
#
# Swift is the one mise.toml pins, never whatever `swift` is first on the PATH: a build off another compiler looks
# exactly like a build off the right one.
set -euo pipefail
cd "${0:A:h}/.."

if ! command -v mise >/dev/null 2>&1; then
    echo "error: the Swift toolchain is pinned in mise.toml; install mise (https://mise.jdx.dev), then run: mise install" >&2
    exit 1
fi
pinned() { mise exec -- "$@"; }

CONFIG=${CONFIG:-release}
BUNDLE_ID=${BUNDLE_ID:-io.github.yuyu1015.EasyDisplay}
# The GitHub repository (owner/name) releases are published to.
UPDATE_REPOSITORY=${UPDATE_REPOSITORY:-ExpTechTW/EasyDisplay}
# Apple silicon only: boost and the sensors are the Apple silicon display coprocessor's and SMC's.
ARCHS=(${=ARCHS:-arm64})
APP=build/EasyDisplay.app

if [[ -z ${EASYDISPLAY_CODE:-} ]] && git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    eval "$(scripts/version.sh)"
fi
LABEL=${EASYDISPLAY_LABEL:-dev}
TRAIN=${EASYDISPLAY_TRAIN:-0.0}
CODE=${EASYDISPLAY_CODE:-0}
DATE=${EASYDISPLAY_DATE:-}
PRERELEASE=${EASYDISPLAY_PRERELEASE:-true}
[[ $PRERELEASE == true ]] && PRERELEASE_TAG="<true/>" || PRERELEASE_TAG="<false/>"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
# "6.4 (swift-6.4-RELEASE)" from swift.org through mise; Xcode's own would say "(swiftlang-…)".
SWIFT_VERSION=$(pinned swift --version 2>/dev/null | sed -n 's/.*Swift version \(.*\)$/\1/p' | head -n 1)
pinned swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN=$(pinned swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/EasyDisplay" "$APP/Contents/MacOS/EasyDisplay"
cp -R "$BIN/EasyDisplay_EasyDisplay.bundle" "$APP/Contents/Resources/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>EasyDisplay</string>
    <key>CFBundleDisplayName</key><string>EasyDisplay</string>
    <key>CFBundleExecutable</key><string>EasyDisplay</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$TRAIN</string>
    <key>CFBundleVersion</key><string>$CODE</string>
    <key>EasyDisplayLabel</key><string>$LABEL</string>
    <key>EasyDisplayDate</key><string>$DATE</string>
    <key>EasyDisplayPrerelease</key>$PRERELEASE_TAG
    <key>EasyDisplayRepository</key><string>$UPDATE_REPOSITORY</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string><string>ja</string></array>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>EasyDisplay</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# Developer ID first: it's the one releases are signed with.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
IDENTITY=${SIGN_IDENTITY:-$(print -r -- "$IDENTITIES" | awk -F'"' '/"Developer ID Application: / { print $2; exit }')}
IDENTITY=${IDENTITY:-$(print -r -- "$IDENTITIES" | awk -F'"' '/"Apple Development: / { print $2; exit }')}
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=-
    echo "warning: no Developer ID or Apple Development certificate found; signing ad hoc" >&2
fi
# A Developer ID signature carries Apple's timestamp, so it stays valid after the certificate expires.
[[ $IDENTITY == "Developer ID Application: "* ]] && TIMESTAMP=--timestamp || TIMESTAMP=--timestamp=none
# The hardened runtime, which notarization requires, on every build, so a local build runs as a release does.
codesign --force --options runtime --sign "$IDENTITY" "$TIMESTAMP" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($LABEL, $TRAIN build $CODE, $CONFIG, ${ARCHS[*]}, Swift $SWIFT_VERSION, signed with: $IDENTITY)"

if [[ -n ${NOTARIZE:-} ]]; then
    if [[ $IDENTITY != "Developer ID Application: "* ]]; then
        echo "error: notarizing needs a Developer ID Application signature, not $IDENTITY" >&2
        exit 1
    fi
    : "${APPLE_ID:?set APPLE_ID to notarize}" "${APPLE_APP_SPECIFIC_PASSWORD:?set APPLE_APP_SPECIFIC_PASSWORD to notarize}"
    TEAM=${APPLE_TEAM_ID:-$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')}
    CREDENTIALS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$TEAM")
    SUBMISSION=build/EasyDisplay-notarization.zip
    rm -f "$SUBMISSION"
    ditto -c -k --keepParent "$APP" "$SUBMISSION"
    echo "Notarizing $APP (usually a few minutes)"
    # The verdict is read from the result rather than the exit status, so a rejection still prints Apple's reasons.
    RESULT=$(xcrun notarytool submit "$SUBMISSION" "${CREDENTIALS[@]}" --wait --timeout 30m --output-format json || true)
    rm -f "$SUBMISSION"
    field() { print -r -- "$RESULT" | python3 -c "import json, sys; print(json.load(sys.stdin).get('$1', ''))" 2>/dev/null; }
    if [[ $(field status) != Accepted ]]; then
        echo "error: notarization didn't pass: ${RESULT:-no answer from notarytool}" >&2
        [[ -n $(field id) ]] && xcrun notarytool log "$(field id)" "${CREDENTIALS[@]}" >&2 || true
        exit 1
    fi
    # The ticket goes into the app, so it opens without asking Apple, offline too.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "Notarized $APP ($(field id))"
fi

if [[ -n ${ARCHIVE:-} ]]; then
    ZIP=build/EasyDisplay-$LABEL.zip
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "Archived $ZIP"
fi
