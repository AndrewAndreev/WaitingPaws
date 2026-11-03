#!/usr/bin/env bash
# Releases: one git tag `v<major>.<minor>.<build>` names the commit that iPhone, Mac and Windows are built from, and
# every release build takes its version from that tag. The project files keep placeholders (0.0.0), so a build made
# any other way shows "dev" in About. <build> grows by one with every tag and never resets; it is also the iPhone and
# Mac build number. See DEVELOPMENT.md «Версии и выпуски».
#
#   Tools/release.sh tag 1.6                     tag HEAD as the next release v1.6.<build> (local; push it yourself)
#   Tools/release.sh build v1.6.10 [ios] [mac]   archive iPhone and Mac from a clean copy of the tag
#                                                → DerivedData/Release/v1.6.10/ (archives, Mac zip, manifest.txt)
#
# Windows is built by GitHub Actions (.github/workflows/windows.yml) when the tag is pushed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The build number of the last release before the tags carried it (ios-v1.5 and mac-v1.5 were build 9).
LAST_OLD_BUILD=9
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "release: $*" >&2; exit 1; }

# The clean copy of the tag that `build` works in, removed on exit.
COPY=""
cleanup() { [ -z "$COPY" ] || git -C "$ROOT" worktree remove --force "$COPY" 2> /dev/null || true; }
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
  local out="$ROOT/DerivedData/Release/$tag"

  # go2rtc for iPhone and Mac is a prebuilt framework outside git: it has to come from the tag's GoMobile/ exactly.
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

  # A clean copy of the tag: uncommitted and untracked files of this checkout stay out of the build.
  local copy="/tmp/wp-release-$tag"
  git worktree remove --force "$copy" 2> /dev/null || rm -rf "$copy"
  git worktree add --detach "$copy" "$tag" > /dev/null
  COPY="$copy"
  mkdir -p "$copy/Frameworks" "$out"
  cp -R "$framework" "$stamp" "$copy/Frameworks/"

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
    echo "Archiving $scheme $version ($commit)…"
    xcodebuild archive -project "$copy/WaitingPaws.xcodeproj" -scheme "$scheme" -configuration Release \
      -destination "$destination" -derivedDataPath "$ROOT/DerivedData/Release/build" -archivePath "$archive" \
      -allowProvisioningUpdates -quiet \
      MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" WP_GIT_COMMIT="$commit"

    local got
    got="$(plist "$info" CFBundleShortVersionString) $(plist "$info" CFBundleVersion) $(plist "$info" WPGitCommit)"
    [ "$got" = "$version $build $commit" ] || die "$scheme came out as \"$got\", not \"$version $build $commit\""
    if [ "$platform" = mac ]; then
      rm -f "$out/WaitingPaws-$version-mac.zip"
      ditto -c -k --keepParent "$archive/Products/Applications/WaitingPaws.app" "$out/WaitingPaws-$version-mac.zip"
    fi
  done

  # What is in the folder (from this run or an earlier one for the same tag), read back from the built apps.
  {
    echo "Waiting Paws $version"
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
    if [ -f "$out/WaitingPaws-$version-mac.zip" ]; then
      echo "mac zip   sha256 $(shasum -a 256 "$out/WaitingPaws-$version-mac.zip" | cut -d' ' -f1)"
    fi
    echo "windows   GitHub Actions on \`git push origin $tag\`"
  } > "$out/manifest.txt"
  echo
  cat "$out/manifest.txt"
  echo
  echo "In $out"
}

case "${1:-}" in
  tag) shift; cmd_tag "$@" ;;
  build) shift; cmd_build "$@" ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
