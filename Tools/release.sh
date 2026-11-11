#!/usr/bin/env bash
# Releases: one git tag `v<major>.<minor>.<build>` names the commit that iPhone, Mac and Windows are built from, and
# every release build takes its version from that tag. The project files keep placeholders (0.0.0), so a build made
# any other way shows "dev" in About. <build> grows by one with every tag and never resets; it is also the iPhone and
# Mac build number. See DEVELOPMENT.md «Версии и выпуски».
#
#   Tools/release.sh tag 1.6                     tag HEAD as the next release v1.6.<build> (local; push it yourself)
#   Tools/release.sh build v1.6.10 [ios] [mac]   archive iPhone and Mac from a clean copy of the tag
#                                                → DerivedData/Release/v1.6.10/ (archives, manifest.txt)
#   Tools/release.sh export v1.6.10 [ios] [mac]  sign those archives for App Store Connect and check the result
#                                                → DerivedData/Release/v1.6.10/export-ios/Waiting Paws.ipa and
#                                                  export-mac/Waiting Paws.pkg
#   Tools/release.sh direct v1.6.10              the Mac app for GitHub: Developer ID, notarized, with Sparkle updates
#                                                → DerivedData/Release/v1.6.10/github/ (zip, appcast.xml, deltas)
#   WP_NO_XIAOMI=1 Tools/release.sh build|export …  no Xiaomi sign-in → DerivedData/Release/v1.6.10-no-xiaomi/
#
# Uploading is a separate step by hand (Transporter or xcrun altool): DEVELOPMENT.md «В App Store».
# Windows is built by GitHub Actions (.github/workflows/windows.yml) when the tag is pushed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The build number of the last release before the tags carried it (ios-v1.5 and mac-v1.5 were build 9).
LAST_OLD_BUILD=9
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "release: $*" >&2; exit 1; }

# WP_NO_XIAOMI=1: the app without the Xiaomi sign-in (Swift condition WP_NO_XIAOMI), built and exported in its own
# folder DerivedData/Release/<tag>-no-xiaomi/, so it never mixes with the standard build of the same tag.
case "${WP_NO_XIAOMI:-}" in
  "" | 0) VARIANT="" VARIANT_NAME="standard" RUN="Tools/release.sh" ;;
  1) VARIANT="-no-xiaomi" VARIANT_NAME="no Xiaomi sign-in (WP_NO_XIAOMI)" RUN="WP_NO_XIAOMI=1 Tools/release.sh" ;;
  *) die "WP_NO_XIAOMI=$WP_NO_XIAOMI: set it to 1 or leave it out" ;;
esac

# The clean copy of the tag that `build` works in and the unpacked exports that `export` checks, removed on exit.
COPY=""
SCRATCH=""
cleanup() {
  [ -z "$COPY" ] || git -C "$ROOT" worktree remove --force "$COPY" 2> /dev/null || true
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Release tags, oldest first (by build number).
release_tags() { git tag -l 'v*' | grep -E "$TAG_RE" | sort -t. -k3,3n || true; }

# The git tree of GoMobile/ as it is on disk, uncommitted changes included (the same as GoMobile/build.sh records).
gomobile_on_disk() {
  local dir; dir="$(mktemp -d)"
  GIT_INDEX_FILE="$dir/index" git read-tree HEAD
  GIT_INDEX_FILE="$dir/index" git add -A GoMobile
  GIT_INDEX_FILE="$dir/index" git write-tree --prefix=GoMobile/
  rm -rf "$dir"
}

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || echo "?"; }

cmd_tag() {
  local minor="${1:-}"
  [[ "$minor" =~ ^[0-9]+\.[0-9]+$ ]] || die "usage: Tools/release.sh tag <major>.<minor>, e.g. 1.6"
  [ -z "$(git status --porcelain --untracked-files=no)" ] ||
    die "uncommitted changes: commit them first, the tag has to name exactly the code that is built"

  local last build
  last="$(release_tags | tail -1)"
  if [ -n "$last" ]; then
    build=$(( ${last##*.} + 1 ))
    # Versions only grow: 1.6 after 1.7 would look older than what people already have.
    local last_minor="${last#v}"
    last_minor="${last_minor%.*}"
    [ "$(printf '%s\n%s\n' "$last_minor" "$minor" | sort -t. -k1,1n -k2,2n | tail -1)" = "$minor" ] ||
      die "$minor is below the last release $last"
  else
    build=$(( LAST_OLD_BUILD + 1 ))
  fi

  local tag="v$minor.$build" same
  same="$(git tag --points-at HEAD | grep -E "$TAG_RE" || true)"
  git tag -a "$tag" -m "Waiting Paws $minor.$build" HEAD
  echo "Tagged $(git rev-parse --short=7 HEAD) as $tag."
  [ -z "$same" ] || echo "It is also $same: a second tag only for rebuilding the same code (a new build number)."
  cat <<EOF

Next:
  Tools/release.sh build $tag     iPhone and Mac
  git push origin $tag            Windows: GitHub Actions builds it into a draft release
EOF
}

# go2rtc for iPhone and Mac is a prebuilt framework outside git: it has to come from the tag's GoMobile/ exactly.
# Then a clean copy of the tag in COPY: uncommitted and untracked files of this checkout stay out of the build.
copy_tag() {
  local tag="$1"
  local framework="$ROOT/Frameworks/Go2RTC.xcframework" stamp="$ROOT/Frameworks/Go2RTC.source" wanted
  wanted="$(git rev-parse "$tag:GoMobile")"
  [ -d "$framework" ] || die "no Frameworks/Go2RTC.xcframework: run GoMobile/build.sh"
  if [ "$(cat "$stamp" 2> /dev/null)" != "$wanted" ]; then
    if [ "$(gomobile_on_disk)" = "$wanted" ]; then
      die "Frameworks/Go2RTC.xcframework was not built from $tag's GoMobile/: run GoMobile/build.sh, then build again"
    fi
    die "Frameworks/Go2RTC.xcframework was not built from $tag's GoMobile/, and GoMobile/ here differs from it too" \
      "(git diff $tag -- GoMobile): rebuild the framework from the tag's GoMobile/"
  fi
  local copy="/tmp/wp-release-$tag$VARIANT"
  git worktree remove --force "$copy" 2> /dev/null || rm -rf "$copy"
  git worktree add --detach "$copy" "$tag" > /dev/null
  COPY="$copy"
  mkdir -p "$copy/Frameworks"
  cp -R "$framework" "$stamp" "$copy/Frameworks/"
}

cmd_build() {
  local tag="${1:-}"
  [[ "$tag" =~ $TAG_RE ]] || die "usage: Tools/release.sh build v<major>.<minor>.<build> [ios] [mac]"
  shift
  git rev-parse -q --verify "refs/tags/$tag" > /dev/null || die "no tag $tag (Tools/release.sh tag <major>.<minor>)"
  local platforms="${*:-ios mac}" platform
  for platform in $platforms; do
    [ "$platform" = ios ] || [ "$platform" = mac ] || die "unknown platform $platform (ios, mac)"
  done

  local version="${tag#v}" build="${tag##*.}" commit
  commit="$(git rev-parse --short=7 "$tag^{commit}")"
  local out="$ROOT/DerivedData/Release/$tag$VARIANT" conditions=()
  [ -z "$VARIANT" ] || conditions=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) WP_NO_XIAOMI')
  local wanted; wanted="$(git rev-parse "$tag:GoMobile")"
  copy_tag "$tag"
  local copy="$COPY"
  mkdir -p "$out"

  local scheme destination archive info
  for platform in $platforms; do
    archive="$out/WaitingPaws-$version-$platform.xcarchive"
    if [ "$platform" = ios ]; then
      scheme=WaitingPaws-iOS destination='generic/platform=iOS'
      info="$archive/Products/Applications/WaitingPaws.app/Info.plist"
    else
      scheme=WaitingPaws-macOS destination='generic/platform=macOS'
      info="$archive/Products/Applications/WaitingPaws.app/Contents/Info.plist"
    fi
    rm -rf "$archive"
    echo "Archiving $scheme $version ($commit), $VARIANT_NAME…"
    xcodebuild archive -project "$copy/WaitingPaws.xcodeproj" -scheme "$scheme" -configuration Release \
      -destination "$destination" -derivedDataPath "$ROOT/DerivedData/Release/build$VARIANT" -archivePath "$archive" \
      -allowProvisioningUpdates -quiet \
      MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" WP_GIT_COMMIT="$commit" \
      ${conditions[@]+"${conditions[@]}"}

    local got
    got="$(plist "$info" CFBundleShortVersionString) $(plist "$info" CFBundleVersion) $(plist "$info" WPGitCommit)"
    [ "$got" = "$version $build $commit" ] || die "$scheme came out as \"$got\", not \"$version $build $commit\""
  done

  # What is in the folder (from this run or an earlier one for the same tag), read back from the built apps.
  {
    echo "Waiting Paws $version"
    echo "variant   $VARIANT_NAME"
    echo "commit    $(git rev-parse "$tag^{commit}")"
    echo "GoMobile  $wanted"
    for platform in ios mac; do
      archive="$out/WaitingPaws-$version-$platform.xcarchive"
      info="$archive/Products/Applications/WaitingPaws.app/Info.plist"
      [ "$platform" = mac ] && info="$archive/Products/Applications/WaitingPaws.app/Contents/Info.plist"
      [ -f "$info" ] || continue
      echo "$platform       $(plist "$info" CFBundleShortVersionString) ($(plist "$info" CFBundleVersion))" \
        "$(plist "$info" WPGitCommit)  $(basename "$archive")"
    done
    local zip="$out/github/WaitingPaws-$version-mac.zip"
    if [ -f "$zip" ]; then
      echo "github    sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)  $(basename "$zip") (Developer ID, notarized)"
    fi
    echo "windows   GitHub Actions on \`git push origin $tag\`"
  } > "$out/manifest.txt"
  echo
  cat "$out/manifest.txt"
  echo
  echo "In $out"
}

EXPORT_OPTIONS="$ROOT/Tools/ExportOptions-AppStore.plist"
FAILED=0

# One check of an exported app: prints it and remembers a mismatch (the export is not uploaded then).
expect() {
  if [ "$2" = "$3" ]; then
    echo "  ok    $1: $2"
  else
    echo "  FAIL  $1: \"$2\", has to be \"$3\"" >&2
    FAILED=1
  fi
}

# What App Store Connect needs from every signed bundle of an export (the app, the iPhone widget): Apple Distribution,
# an App Store profile (no device list), no debugger entitlement, the team's app id, the tag's version.
# $1 bundle, $2 ios|mac, $3 team, $4 version, $5 build.
check_bundle() {
  local bundle="$1" platform="$2" team="$3" version="$4" build="$5"
  local info profile app_id_key debug_key ent prof authority got
  if [ "$platform" = ios ]; then
    info="$bundle/Info.plist" profile="$bundle/embedded.mobileprovision"
    app_id_key=application-identifier debug_key=get-task-allow
  else
    info="$bundle/Contents/Info.plist" profile="$bundle/Contents/embedded.provisionprofile"
    app_id_key=com.apple.application-identifier debug_key=com.apple.security.get-task-allow
  fi
  ent="$SCRATCH/entitlements.plist" prof="$SCRATCH/profile.plist"
  echo "$(basename "$bundle") ($(plist "$info" CFBundleIdentifier))"

  if codesign --verify --strict --deep "$bundle" 2> /dev/null; then got=valid; else got=invalid; fi
  expect "signature" "$got" valid
  authority="$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
  expect "signed by" "${authority%%:*}" "Apple Distribution"
  expect "signing team" "$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)" "$team"
  expect "version" "$(plist "$info" CFBundleShortVersionString) ($(plist "$info" CFBundleVersion))" "$version ($build)"

  if [ -f "$profile" ] && security cms -D -i "$profile" > "$prof" 2> /dev/null; then
    echo "        profile «$(plist "$prof" Name)»"
    if [ "$(plist "$prof" ProvisionedDevices)" = "?" ]; then got=none; else got=listed; fi
    expect "devices in the profile (App Store: none)" "$got" none
    got="$(plist "$prof" ProvisionsAllDevices)"
    expect "profile for all devices (Developer ID / Enterprise)" "${got/\?/false}" false
    expect "profile team" "$(plist "$prof" TeamIdentifier:0)" "$team"
  else
    expect "embedded profile" "missing" "$(basename "$profile")"
  fi

  # No entitlements (unsigned): an empty dictionary, so that every key below reads as missing.
  codesign -d --entitlements - --xml "$bundle" > "$ent" 2> /dev/null || true
  [ -s "$ent" ] || echo '<plist version="1.0"><dict/></plist>' > "$ent"
  expect "$app_id_key" "$(plist "$ent" "$app_id_key")" "$team.$(plist "$info" CFBundleIdentifier)"
  expect "com.apple.developer.team-identifier" "$(plist "$ent" com.apple.developer.team-identifier)" "$team"
  got="$(plist "$ent" "$debug_key")"
  expect "$debug_key" "${got/\?/false}" false
  [ "$platform" = ios ] || expect "com.apple.security.app-sandbox" "$(plist "$ent" com.apple.security.app-sandbox)" true
}

# The one file of an export with this extension ($1 folder, $2 extension).
exported_file() {
  local files; files="$(find "$1" -maxdepth 1 -name "*.$2")"
  [ -n "$files" ] && [ "$(echo "$files" | wc -l)" -eq 1 ] || die "not one .$2 in $1"
  echo "$files"
}

cmd_export() {
  local tag="${1:-}"
  [[ "$tag" =~ $TAG_RE ]] || die "usage: Tools/release.sh export v<major>.<minor>.<build> [ios] [mac]"
  shift
  git rev-parse -q --verify "refs/tags/$tag" > /dev/null || die "no tag $tag (Tools/release.sh tag <major>.<minor>)"
  local platforms="${*:-ios mac}" platform
  for platform in $platforms; do
    [ "$platform" = ios ] || [ "$platform" = mac ] || die "unknown platform $platform (ios, mac)"
  done
  plutil -lint -s "$EXPORT_OPTIONS" || die "Tools/ExportOptions-AppStore.plist is broken"

  local version="${tag#v}" build="${tag##*.}" commit team
  commit="$(git rev-parse --short=7 "$tag^{commit}")"
  team="$(plist "$EXPORT_OPTIONS" teamID)"
  local out="$ROOT/DerivedData/Release/$tag$VARIANT"

  # Before anything is signed: every archive is there and is this tag's build.
  local archive info got
  for platform in $platforms; do
    archive="$out/WaitingPaws-$version-$platform.xcarchive"
    [ -d "$archive" ] || die "no $archive: $RUN build $tag $platform"
    info="$archive/Products/Applications/WaitingPaws.app/Info.plist"
    [ "$platform" = mac ] && info="$archive/Products/Applications/WaitingPaws.app/Contents/Info.plist"
    got="$(plist "$info" CFBundleShortVersionString) $(plist "$info" CFBundleVersion) $(plist "$info" WPGitCommit)"
    [ "$got" = "$version $build $commit" ] ||
      die "$(basename "$archive") is \"$got\", not \"$version $build $commit\": $RUN build $tag $platform"
  done

  local exported="" dir file app appex leaf
  for platform in $platforms; do
    archive="$out/WaitingPaws-$version-$platform.xcarchive"
    dir="$out/export-$platform"
    rm -rf "$dir"
    echo "Exporting $platform $version, $VARIANT_NAME, for App Store Connect…"
    # -allowProvisioningUpdates: Xcode makes the App Store profiles and signs with the team's cloud-managed distribution
    # certificates (they are not in the keychain; only with the owner's consent: DEVELOPMENT.md «В App Store»).
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$dir" \
      -allowProvisioningUpdates

    echo
    echo "Checking the $platform export:"
    FAILED=0
    rm -rf "$SCRATCH"
    SCRATCH="$(mktemp -d)"
    if [ "$platform" = ios ]; then
      file="$(exported_file "$dir" ipa)"
      ditto -x -k "$file" "$SCRATCH/ipa"
      app="$SCRATCH/ipa/Payload/WaitingPaws.app"
      [ -d "$app" ] || die "no Payload/WaitingPaws.app in $file"
      check_bundle "$app" ios "$team" "$version" "$build"
      expect "commit" "$(plist "$app/Info.plist" WPGitCommit)" "$commit"
      for appex in "$app"/PlugIns/*.appex; do
        [ -d "$appex" ] || continue
        check_bundle "$appex" ios "$team" "$version" "$build"
      done
    else
      # The Mac App Store takes an installer package signed by «3rd Party Mac Developer Installer» (the certificate
      # type the developer site calls Mac Installer Distribution), with the app signed by Apple Distribution inside.
      file="$(exported_file "$dir" pkg)"
      echo "$(basename "$file")"
      leaf="$(pkgutil --check-signature "$file" 2>&1 | sed -n 's/^ *1\. //p' | head -1 || true)"
      got="${leaf%%:*}"
      [ "$got" != "Mac Installer Distribution" ] || got="3rd Party Mac Developer Installer"
      expect "installer signed by" "${got:-nobody}" "3rd Party Mac Developer Installer"
      expect "installer team" "$(echo "$leaf" | sed -n 's/.*(\(.*\))$/\1/p')" "$team"
      pkgutil --expand-full "$file" "$SCRATCH/pkg" > /dev/null
      app="$(find "$SCRATCH/pkg" -maxdepth 3 -type d -name WaitingPaws.app | head -1 || true)"
      [ -n "$app" ] || die "no WaitingPaws.app in $file"
      check_bundle "$app" mac "$team" "$version" "$build"
      expect "commit" "$(plist "$app/Contents/Info.plist" WPGitCommit)" "$commit"
    fi
    [ "$FAILED" = 0 ] || die "the $platform export does not pass the checks above: do not upload \"$file\""
    exported="$exported  \"$file\""$'\n'
    echo
  done

  cat <<EOF
Checked, ready for App Store Connect:
$exported
Validate and upload each file yourself (DEVELOPMENT.md «В App Store»): Transporter (Verify, then Deliver), or
  xcrun altool --validate-app "<file>" --api-key <KEY_ID> --api-issuer <ISSUER_ID>
  xcrun altool --upload-package "<file>" --api-key <KEY_ID> --api-issuer <ISSUER_ID>
with the key in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8, never in the repository.
EOF
}

# The Mac app for GitHub (target WaitingPaws-macOS-Direct): Developer ID, notarized, updates itself through Sparkle.
DIRECT_EXPORT_OPTIONS="$ROOT/Tools/ExportOptions-DeveloperID.plist"
NOTARY_PROFILE="${WP_NOTARY_PROFILE:-WaitingPaws}"
# The Sparkle EdDSA key in the login keychain (generate_keys --account waitingpaws); its public half is in project.yml.
SPARKLE_ACCOUNT=waitingpaws
REPO_URL=https://github.com/AndrewAndreev/WaitingPaws
# Every GitHub build's zip with the appcast that grows with them: generate_appcast adds the new version to it and makes
# deltas from the previous zips here. Local only; lost, it starts again from the next version.
UPDATES="$ROOT/DerivedData/Updates"

cmd_direct() {
  local tag="${1:-}"
  [[ "$tag" =~ $TAG_RE ]] || die "usage: Tools/release.sh direct v<major>.<minor>.<build>"
  [ -z "$VARIANT" ] || die "the GitHub Mac app is the standard build only (leave WP_NO_XIAOMI out)"
  git rev-parse -q --verify "refs/tags/$tag" > /dev/null || die "no tag $tag (Tools/release.sh tag <major>.<minor>)"
  plutil -lint -s "$DIRECT_EXPORT_OPTIONS" || die "Tools/ExportOptions-DeveloperID.plist is broken"
  local team; team="$(plist "$DIRECT_EXPORT_OPTIONS" teamID)"
  security find-identity -v -p codesigning | grep -q "\"Developer ID Application: .*($team)\"" ||
    die "no Developer ID Application certificate of team $team in the keychain (DEVELOPMENT.md «С GitHub»)"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 ||
    die "notarytool has no working profile $NOTARY_PROFILE (DEVELOPMENT.md «С GitHub»)"

  local version="${tag#v}" build="${tag##*.}" commit
  commit="$(git rev-parse --short=7 "$tag^{commit}")"
  local out="$ROOT/DerivedData/Release/$tag" derived="$ROOT/DerivedData/Release/build"
  local archive="$out/WaitingPaws-$version-mac-direct.xcarchive" export="$out/export-direct" github="$out/github"
  copy_tag "$tag"
  mkdir -p "$out"

  echo "Archiving WaitingPaws-macOS-Direct $version ($commit)…"
  rm -rf "$archive"
  xcodebuild archive -project "$COPY/WaitingPaws.xcodeproj" -scheme WaitingPaws-macOS-Direct -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$archive" \
    -allowProvisioningUpdates -quiet \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" WP_GIT_COMMIT="$commit"
  local info="$archive/Products/Applications/WaitingPaws.app/Contents/Info.plist" got
  got="$(plist "$info" CFBundleShortVersionString) $(plist "$info" CFBundleVersion) $(plist "$info" WPGitCommit)"
  [ "$got" = "$version $build $commit" ] || die "the archive came out as \"$got\", not \"$version $build $commit\""

  echo "Exporting with Developer ID…"
  rm -rf "$export"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$DIRECT_EXPORT_OPTIONS" -exportPath "$export"
  local app="$export/WaitingPaws.app"
  [ -d "$app" ] || die "no WaitingPaws.app in $export"

  echo
  echo "Checking the export:"
  FAILED=0
  rm -rf "$SCRATCH"
  SCRATCH="$(mktemp -d)"
  local ent="$SCRATCH/entitlements.plist" authority code flags
  if codesign --verify --strict --deep "$app" 2> /dev/null; then got=valid; else got=invalid; fi
  expect "signature" "$got" valid
  authority="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
  expect "signed by" "${authority%%:*}" "Developer ID Application"
  expect "signing team" "$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)" "$team"
  expect "version" "$(plist "$app/Contents/Info.plist" CFBundleShortVersionString) ($(plist "$app/Contents/Info.plist" CFBundleVersion))" "$version ($build)"
  expect "commit" "$(plist "$app/Contents/Info.plist" WPGitCommit)" "$commit"
  expect "update feed" "$(plist "$app/Contents/Info.plist" SUFeedURL)" "$REPO_URL/releases/latest/download/appcast.xml"
  got="$(plist "$app/Contents/Info.plist" SUPublicEDKey)"
  expect "update key" "${got:+set}" set
  codesign -d --entitlements - --xml "$app" > "$ent" 2> /dev/null || true
  [ -s "$ent" ] || echo '<plist version="1.0"><dict/></plist>' > "$ent"
  expect "com.apple.security.app-sandbox" "$(plist "$ent" com.apple.security.app-sandbox)" true
  got="$(plist "$ent" com.apple.security.get-task-allow)"
  expect "com.apple.security.get-task-allow" "${got/\?/false}" false
  expect "Sparkle's XPC names" "$(plist "$ent" com.apple.security.temporary-exception.mach-lookup.global-name:0)" \
    "$(plist "$app/Contents/Info.plist" CFBundleIdentifier)-spks"
  # Notarization wants the hardened runtime on every executable: the app, Sparkle's Updater, XPC services, Autoupdate.
  while IFS= read -r code; do
    flags="$(codesign -dv "$code" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\([^)]*\)).*/\2/p')"
    [[ "$flags" == *runtime* ]] || { echo "  FAIL  hardened runtime: ${code#"$export/"} ($flags)" >&2; FAILED=1; }
  done < <(echo "$app"; find "$app/Contents" \( -name '*.app' -o -name '*.xpc' \) -type d;
           find "$app/Contents/Frameworks" -type f -perm +111 -name Autoupdate)
  [ "$FAILED" = 0 ] && echo "  ok    hardened runtime on the app and Sparkle's helpers"
  [ "$FAILED" = 0 ] || die "the export does not pass the checks above"

  echo
  echo "Notarizing (a few minutes)…"
  ditto -c -k --keepParent "$app" "$SCRATCH/notarize.zip"
  xcrun notarytool submit "$SCRATCH/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist \
    > "$SCRATCH/notary.plist" || true
  local status id
  status="$(plist "$SCRATCH/notary.plist" status)" id="$(plist "$SCRATCH/notary.plist" id)"
  if [ "$status" != Accepted ]; then
    [ "$id" = "?" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization: \"$status\" (submission $id)"
  fi
  echo "  ok    notarized (submission $id)"
  xcrun stapler staple -q "$app" || die "stapler could not attach the notarization ticket"
  xcrun stapler validate -q "$app" || die "the stapled ticket does not validate"
  got="$(spctl -a -t exec -vv "$app" 2>&1 | sed -n 's/^source=//p')"
  [ "$got" = "Notarized Developer ID" ] || die "Gatekeeper says \"$got\", not \"Notarized Developer ID\""
  echo "  ok    stapled, Gatekeeper: $got"

  local zip="WaitingPaws-$version-mac.zip" notes="$ROOT/Tools/release-notes/$version.md"
  mkdir -p "$UPDATES"
  rm -f "$UPDATES/$zip"
  ditto -c -k --keepParent "$app" "$UPDATES/$zip"
  # What is new, in the appcast (the toolbar's «Обновление» shows its first lines): Tools/release-notes/<version>.md.
  if [ -f "$notes" ]; then cp "$notes" "$UPDATES/${zip%.zip}.md"; else echo "  note  no $notes: the update has no description"; fi
  local generate="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
  [ -x "$generate" ] || die "no Sparkle's generate_appcast in $derived/SourcePackages"
  echo "Writing the appcast…"
  "$generate" --account "$SPARKLE_ACCOUNT" --download-url-prefix "$REPO_URL/releases/download/$tag/" \
    --full-release-notes-url "$REPO_URL/releases" --link "$REPO_URL" --embed-release-notes --maximum-versions 3 \
    "$UPDATES"

  # For the release: the zip, the appcast, and the deltas to this version.
  rm -rf "$github"
  mkdir -p "$github"
  cp "$UPDATES/$zip" "$UPDATES/appcast.xml" "$github/"
  find "$UPDATES" -maxdepth 1 -name "*$build-*.delta" -exec cp {} "$github/" \;
  grep -q "<sparkle:version>$build</sparkle:version>" "$github/appcast.xml" || die "the appcast has no build $build"
  {
    echo "github    $version ($build) $commit, Developer ID, notarized ($id)"
    echo "          sha256 $(shasum -a 256 "$github/$zip" | cut -d' ' -f1)  $zip"
  } >> "$out/manifest.txt"

  echo
  ls -l "$github"
  cat <<EOF

Ready in $github. The appcast reaches the apps when its release is published as Latest:
  1. git push origin $tag                       Windows: GitHub Actions makes the draft release with its files
  2. gh release upload $tag $github/* --clobber   after that draft exists (otherwise Actions keeps its files out)
  3. gh release edit $tag --draft=false --latest
Every release published as Latest needs this appcast.xml too: the Mac apps read the Latest release's.
EOF
}

case "${1:-}" in
  tag) shift; cmd_tag "$@" ;;
  build) shift; cmd_build "$@" ;;
  export) shift; cmd_export "$@" ;;
  direct) shift; cmd_direct "$@" ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
