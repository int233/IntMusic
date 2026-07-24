#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/apps/client-flutter"

BUILD_ANDROID=1
BUILD_ANDROID_AAB=1
BUILD_CORE=1
BUNDLE_FFMPEG=1
HOST_OS="$(uname -s)"
BUILD_LINUX=0
BUILD_MACOS=0
if [[ "$HOST_OS" == "Darwin" ]]; then
  BUILD_MACOS=1
elif [[ "$HOST_OS" == "Linux" ]]; then
  BUILD_LINUX=1
fi
SIGN_MACOS_IDENTITY="${MACOS_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${APPLE_NOTARY_KEYCHAIN_PROFILE:-}"
NOTARIZE_MACOS=0
OUTPUT_ROOT=""
RELEASE_ID=""

usage() {
  cat <<'EOF'
Usage: scripts/build-release-artifacts.sh [options]

Build release artifacts that can be produced on this host, then collect them
under one release directory.

Options:
  --output DIR               Release output directory. Defaults to packaging/dist/releases/<release-id>.
  --release-id NAME          Release directory name when --output is not set.
  --skip-android             Do not build Android artifacts.
  --skip-android-aab         Build Android APK only.
  --skip-core                Do not build the host Core CLI binary.
  --skip-bundled-ffmpeg      Package Core without the bundled FFmpeg tools.
  --skip-linux               Do not build the Linux Flutter app.
  --skip-macos               Do not build the macOS Flutter app.
  --sign-macos IDENTITY      Re-sign IntMusic.app with a Developer ID Application identity.
  --notary-profile PROFILE   notarytool keychain profile name.
  --notarize-macos           Submit the signed macOS app zip to Apple notary service and staple the ticket.
  -h, --help                 Show this help.

Environment:
  MACOS_CODESIGN_IDENTITY          Default value for --sign-macos.
  APPLE_NOTARY_KEYCHAIN_PROFILE    Default value for --notary-profile.
  INTMUSIC_FFMPEG_DIR              Reuse a prepared FFmpeg bundle instead of building it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_ROOT="${2:?--output requires a directory}"
      shift 2
      ;;
    --release-id)
      RELEASE_ID="${2:?--release-id requires a name}"
      shift 2
      ;;
    --skip-android)
      BUILD_ANDROID=0
      shift
      ;;
    --skip-android-aab)
      BUILD_ANDROID_AAB=0
      shift
      ;;
    --skip-core)
      BUILD_CORE=0
      shift
      ;;
    --skip-bundled-ffmpeg)
      BUNDLE_FFMPEG=0
      shift
      ;;
    --skip-linux)
      BUILD_LINUX=0
      shift
      ;;
    --skip-macos)
      BUILD_MACOS=0
      shift
      ;;
    --sign-macos)
      SIGN_MACOS_IDENTITY="${2:?--sign-macos requires a signing identity}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:?--notary-profile requires a keychain profile name}"
      shift 2
      ;;
    --notarize-macos)
      NOTARIZE_MACOS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$BUILD_MACOS" -eq 1 && "$(uname -s)" != "Darwin" ]]; then
  echo "macOS artifacts can only be built on macOS. Use --skip-macos on this host." >&2
  exit 1
fi

if [[ "$BUILD_LINUX" -eq 1 && "$(uname -s)" != "Linux" ]]; then
  echo "Linux artifacts can only be built on Linux. Use --skip-linux on this host." >&2
  exit 1
fi

if [[ "$NOTARIZE_MACOS" -eq 1 && -z "$SIGN_MACOS_IDENTITY" ]]; then
  echo "--notarize-macos requires --sign-macos or MACOS_CODESIGN_IDENTITY." >&2
  exit 1
fi

if [[ "$NOTARIZE_MACOS" -eq 1 && -z "$NOTARY_PROFILE" ]]; then
  echo "--notarize-macos requires --notary-profile or APPLE_NOTARY_KEYCHAIN_PROFILE." >&2
  exit 1
fi

version="$(awk '/^version:/ { print $2; exit }' "$CLIENT_DIR/pubspec.yaml")"
version_safe="${version//+/-}"
git_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
timestamp="$(date +%Y%m%d-%H%M%S)"

if [[ -z "$RELEASE_ID" ]]; then
  RELEASE_ID="IntMusic-${version_safe}-${git_sha}-${timestamp}"
fi

if [[ -z "$OUTPUT_ROOT" ]]; then
  OUTPUT_ROOT="$REPO_ROOT/packaging/dist/releases/$RELEASE_ID"
elif [[ "$OUTPUT_ROOT" != /* ]]; then
  OUTPUT_ROOT="$REPO_ROOT/$OUTPUT_ROOT"
fi

mkdir -p "$OUTPUT_ROOT/android" "$OUTPUT_ROOT/linux" "$OUTPUT_ROOT/macos"

artifact_paths=()
artifact_kinds=()
artifact_targets=()

record_artifact() {
  local path="$1"
  local kind="$2"
  local target="$3"

  artifact_paths+=("$path")
  artifact_kinds+=("$kind")
  artifact_targets+=("$target")
}

copy_artifact() {
  local source="$1"
  local destination="$2"
  local kind="$3"
  local target="$4"

  if [[ ! -e "$source" ]]; then
    echo "Expected artifact was not found: $source" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  cp -f "$source" "$destination"
  record_artifact "$destination" "$kind" "$target"
}

zip_directory_contents() {
  local source_dir="$1"
  local destination="$2"
  local kind="$3"
  local target="$4"

  if [[ ! -d "$source_dir" ]]; then
    echo "Expected directory was not found: $source_dir" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  (cd "$source_dir" && zip -qry "$destination" .)
  record_artifact "$destination" "$kind" "$target"
}

zip_keep_parent() {
  local source="$1"
  local destination="$2"
  local kind="$3"
  local target="$4"

  if [[ ! -e "$source" ]]; then
    echo "Expected bundle was not found: $source" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  ditto -c -k --keepParent "$source" "$destination"
  record_artifact "$destination" "$kind" "$target"
}

write_checksums() {
  local checksum_file="$OUTPUT_ROOT/SHA256SUMS.txt"
  : > "$checksum_file"
  if [[ "${#artifact_paths[@]}" -eq 0 ]]; then
    return
  fi

  for path in "${artifact_paths[@]}"; do
    local rel_path="${path#$OUTPUT_ROOT/}"
    local hash
    hash="$(shasum -a 256 "$path" | awk '{ print $1 }')"
    printf '%s  %s\n' "$hash" "$rel_path" >> "$checksum_file"
  done
}

write_manifest() {
  local manifest_file="$OUTPUT_ROOT/manifest.json"
  {
    printf '{\n'
    printf '  "app": "IntMusic",\n'
    printf '  "version": "%s",\n' "$version"
    printf '  "git_sha": "%s",\n' "$git_sha"
    printf '  "built_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "host": "%s",\n' "$(uname -s)"
    printf '  "artifacts": [\n'
    if [[ "${#artifact_paths[@]}" -gt 0 ]]; then
      for index in "${!artifact_paths[@]}"; do
        local path="${artifact_paths[$index]}"
        local rel_path="${path#$OUTPUT_ROOT/}"
        local hash
        hash="$(shasum -a 256 "$path" | awk '{ print $1 }')"
        printf '    {\n'
        printf '      "path": "%s",\n' "$rel_path"
        printf '      "kind": "%s",\n' "${artifact_kinds[$index]}"
        printf '      "target": "%s",\n' "${artifact_targets[$index]}"
        printf '      "sha256": "%s"\n' "$hash"
        if [[ "$index" -eq $((${#artifact_paths[@]} - 1)) ]]; then
          printf '    }\n'
        else
          printf '    },\n'
        fi
      done
    fi
    printf '  ]\n'
    printf '}\n'
  } > "$manifest_file"
}

echo "Release output:"
echo "  $OUTPUT_ROOT"

pushd "$REPO_ROOT" >/dev/null
if [[ "$BUILD_CORE" -eq 1 ]]; then
  cargo build --release -p core-cli
  if [[ "$HOST_OS" == "Darwin" ]]; then
    core_target="macos-$(uname -m)"
    core_dir="macos"
  elif [[ "$HOST_OS" == "Linux" ]]; then
    core_target="linux-$(uname -m)"
    core_dir="linux"
  else
    core_target="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
    core_dir="$core_target"
    mkdir -p "$OUTPUT_ROOT/$core_dir"
  fi
  core_stage="$(mktemp -d "${TMPDIR:-/tmp}/intmusic-core-stage.XXXXXX")"
  mkdir -p "$core_stage/core"
  cp -f "$REPO_ROOT/target/release/local-music-core" "$core_stage/core/local-music-core"
  chmod 755 "$core_stage/core/local-music-core"
  if [[ "$BUNDLE_FFMPEG" -eq 1 ]]; then
    ffmpeg_bundle="${INTMUSIC_FFMPEG_DIR:-$REPO_ROOT/packaging/ffmpeg/$core_target}"
    if [[ ! -x "$ffmpeg_bundle/bin/ffmpeg" || ! -x "$ffmpeg_bundle/bin/ffprobe" ]]; then
      "$REPO_ROOT/scripts/build-bundled-ffmpeg.sh" --output "$ffmpeg_bundle"
    fi
    mkdir -p "$core_stage/core/tools/ffmpeg"
    cp -R "$ffmpeg_bundle/." "$core_stage/core/tools/ffmpeg/"
    "$core_stage/core/tools/ffmpeg/bin/ffmpeg" -hide_banner -version | sed -n '1p'
    "$core_stage/core/tools/ffmpeg/bin/ffprobe" -hide_banner -version | sed -n '1p'
  fi
  if [[ "$HOST_OS" == "Darwin" && -n "$SIGN_MACOS_IDENTITY" ]]; then
    if [[ "$BUNDLE_FFMPEG" -eq 1 ]]; then
      codesign --force --timestamp --options runtime \
        --sign "$SIGN_MACOS_IDENTITY" \
        "$core_stage/core/tools/ffmpeg/bin/ffmpeg"
      codesign --force --timestamp --options runtime \
        --sign "$SIGN_MACOS_IDENTITY" \
        "$core_stage/core/tools/ffmpeg/bin/ffprobe"
    fi
    codesign --force --timestamp --options runtime \
      --sign "$SIGN_MACOS_IDENTITY" \
      "$core_stage/core/local-music-core"
  fi
  core_zip="$OUTPUT_ROOT/$core_dir/IntMusic-Core-${version_safe}-${core_target}.zip"
  zip_directory_contents \
    "$core_stage/core" \
    "$core_zip" \
    "core-bundle-zip" \
    "$core_target"
  rm -rf -- "$core_stage"
  if [[ "$NOTARIZE_MACOS" -eq 1 && "$HOST_OS" == "Darwin" ]]; then
    xcrun notarytool submit "$core_zip" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
fi

if [[ "$BUILD_ANDROID" -eq 1 ]]; then
  pushd "$CLIENT_DIR" >/dev/null
  flutter build apk --release
  if [[ "$BUILD_ANDROID_AAB" -eq 1 ]]; then
    flutter build appbundle --release
  fi
  popd >/dev/null

  copy_artifact \
    "$CLIENT_DIR/build/app/outputs/flutter-apk/app-release.apk" \
    "$OUTPUT_ROOT/android/IntMusic-Android-${version_safe}.apk" \
    "flutter-apk" \
    "android"

  if [[ "$BUILD_ANDROID_AAB" -eq 1 ]]; then
    copy_artifact \
      "$CLIENT_DIR/build/app/outputs/bundle/release/app-release.aab" \
      "$OUTPUT_ROOT/android/IntMusic-Android-${version_safe}.aab" \
      "flutter-aab" \
      "android"
  fi
fi

if [[ "$BUILD_LINUX" -eq 1 ]]; then
  pushd "$CLIENT_DIR" >/dev/null
  flutter config --enable-linux-desktop
  flutter build linux --release
  popd >/dev/null

  zip_directory_contents \
    "$CLIENT_DIR/build/linux/x64/release/bundle" \
    "$OUTPUT_ROOT/linux/IntMusic-Linux-${version_safe}-x64.zip" \
    "flutter-linux-client-zip" \
    "linux-x64"
fi

if [[ "$BUILD_MACOS" -eq 1 ]]; then
  pushd "$CLIENT_DIR" >/dev/null
  flutter build macos --release
  popd >/dev/null

  macos_app="$CLIENT_DIR/build/macos/Build/Products/Release/IntMusic.app"
  macos_zip="$OUTPUT_ROOT/macos/IntMusic-macOS-${version_safe}-universal.zip"

  if [[ -n "$SIGN_MACOS_IDENTITY" ]]; then
    codesign --force --deep --timestamp --options runtime \
      --entitlements "$CLIENT_DIR/macos/Runner/Release.entitlements" \
      --sign "$SIGN_MACOS_IDENTITY" \
      "$macos_app"
    codesign --verify --deep --strict --verbose=2 "$macos_app"
  fi

  zip_keep_parent "$macos_app" "$macos_zip" "flutter-macos-app-zip" "macos-universal"

  if [[ "$NOTARIZE_MACOS" -eq 1 ]]; then
    xcrun notarytool submit "$macos_zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$macos_app"
    xcrun stapler validate "$macos_app"
    rm -f "$macos_zip"
    artifact_paths=("${artifact_paths[@]:0:$((${#artifact_paths[@]} - 1))}")
    artifact_kinds=("${artifact_kinds[@]:0:$((${#artifact_kinds[@]} - 1))}")
    artifact_targets=("${artifact_targets[@]:0:$((${#artifact_targets[@]} - 1))}")
    zip_keep_parent "$macos_app" "$macos_zip" "flutter-macos-app-zip-notarized" "macos-universal"
  fi
fi
popd >/dev/null

write_checksums
write_manifest

echo "Artifacts:"
if [[ "${#artifact_paths[@]}" -eq 0 ]]; then
  echo "  (none)"
else
  for path in "${artifact_paths[@]}"; do
    echo "  ${path#$OUTPUT_ROOT/}"
  done
fi
echo
echo "Manifest:"
echo "  $OUTPUT_ROOT/manifest.json"
