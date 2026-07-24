#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FFMPEG_VERSION="8.1.2"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
OUTPUT_DIR=""
SOURCE_ARCHIVE=""

usage() {
  cat <<'EOF'
Usage: scripts/build-bundled-ffmpeg.sh --output DIR [--source-archive FILE]

Build the LGPL-only FFmpeg and ffprobe executables used by IntMusic Core.
The resulting directory is ready to copy to core/tools/ffmpeg.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:?--output requires a directory}"
      shift 2
      ;;
    --source-archive)
      SOURCE_ARCHIVE="${2:?--source-archive requires a file}"
      shift 2
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

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "--output is required" >&2
  exit 2
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
fi

CACHE_DIR="${INTMUSIC_FFMPEG_SOURCE_CACHE:-$REPO_ROOT/.cache/ffmpeg}"
mkdir -p "$CACHE_DIR"
if [[ -z "$SOURCE_ARCHIVE" ]]; then
  SOURCE_ARCHIVE="$CACHE_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
fi
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl --fail --location --retry 3 --output "$SOURCE_ARCHIVE" "$FFMPEG_URL"
fi

if command -v shasum >/dev/null 2>&1; then
  actual_sha="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual_sha="$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')"
else
  echo "A SHA-256 utility is required." >&2
  exit 1
fi
if [[ "$actual_sha" != "$FFMPEG_SHA256" ]]; then
  echo "FFmpeg source checksum mismatch." >&2
  echo "Expected: $FFMPEG_SHA256" >&2
  echo "Actual:   $actual_sha" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/intmusic-ffmpeg.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_DIR:-}" && "$WORK_DIR" == *"/intmusic-ffmpeg."* ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

tar -xf "$SOURCE_ARCHIVE" -C "$WORK_DIR"
SOURCE_DIR="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"
INSTALL_DIR="$WORK_DIR/install"

CONFIGURE_FLAGS=(
  "--prefix=$INSTALL_DIR"
  "--disable-debug"
  "--disable-doc"
  "--disable-ffplay"
  "--disable-avdevice"
  "--disable-network"
  "--disable-autodetect"
  "--disable-gpl"
  "--disable-nonfree"
  "--disable-shared"
  "--enable-static"
  "--enable-ffmpeg"
  "--enable-ffprobe"
  "--enable-protocol=file,pipe"
)

HOST_SYSTEM="$(uname -s)"
IS_WINDOWS_BUILD=false
case "$HOST_SYSTEM" in
  MINGW*|MSYS*|CYGWIN*)
    IS_WINDOWS_BUILD=true
    # --enable-static controls FFmpeg's own libraries, but MinGW can still
    # dynamically link its GCC and pthread runtimes. The bundle must also run
    # from a plain PowerShell process where the MSYS2 bin directory is absent.
    CONFIGURE_FLAGS+=(
      "--disable-pthreads"
      "--enable-w32threads"
      "--extra-ldflags=-static -static-libgcc"
    )
    ;;
esac

pushd "$SOURCE_DIR" >/dev/null
./configure "${CONFIGURE_FLAGS[@]}"
if command -v nproc >/dev/null 2>&1; then
  JOBS="$(nproc)"
else
  JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"
fi
make -j "$JOBS"
make install
popd >/dev/null

mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/source"
if [[ -f "$INSTALL_DIR/bin/ffmpeg.exe" ]]; then
  cp -f "$INSTALL_DIR/bin/ffmpeg.exe" "$OUTPUT_DIR/bin/ffmpeg.exe"
  cp -f "$INSTALL_DIR/bin/ffprobe.exe" "$OUTPUT_DIR/bin/ffprobe.exe"
else
  cp -f "$INSTALL_DIR/bin/ffmpeg" "$OUTPUT_DIR/bin/ffmpeg"
  cp -f "$INSTALL_DIR/bin/ffprobe" "$OUTPUT_DIR/bin/ffprobe"
  chmod 755 "$OUTPUT_DIR/bin/ffmpeg" "$OUTPUT_DIR/bin/ffprobe"
fi
cp -f "$SOURCE_DIR/COPYING.LGPLv2.1" "$OUTPUT_DIR/LICENSE.LGPLv2.1.txt"
cp -f "$SOURCE_ARCHIVE" "$OUTPUT_DIR/source/ffmpeg-${FFMPEG_VERSION}.tar.xz"

if [[ "$IS_WINDOWS_BUILD" == true ]]; then
  if ! command -v objdump >/dev/null 2>&1; then
    echo "objdump is required to audit the Windows FFmpeg bundle." >&2
    exit 1
  fi

  DEPENDENCY_REPORT="$OUTPUT_DIR/DEPENDENCIES.txt"
  : > "$DEPENDENCY_REPORT"
  for tool in ffmpeg.exe ffprobe.exe; do
    tool_path="$OUTPUT_DIR/bin/$tool"
    "$tool_path" -hide_banner -version >/dev/null

    {
      echo "$tool"
      objdump -p "$tool_path" |
        awk '$1 == "DLL" && $2 == "Name:" { print "  " $3 }'
      echo
    } >> "$DEPENDENCY_REPORT"

    while IFS= read -r dependency; do
      dependency_lower="$(printf '%s' "$dependency" | tr '[:upper:]' '[:lower:]')"
      case "$dependency_lower" in
        cyg*.dll|msys-*.dll|libgcc_s_*.dll|libstdc++-6.dll|libwinpthread-1.dll|libssp-0.dll|libiconv-2.dll|libintl-8.dll)
          echo "$tool unexpectedly depends on the non-system runtime $dependency." >&2
          echo "Windows FFmpeg must run without an MSYS2 installation." >&2
          exit 1
          ;;
      esac
    done < <(
      objdump -p "$tool_path" |
        awk '$1 == "DLL" && $2 == "Name:" { print $3 }'
    )
  done
fi

{
  echo "FFmpeg ${FFMPEG_VERSION}"
  echo "Source: ${FFMPEG_URL}"
  echo "SHA-256: ${FFMPEG_SHA256}"
  echo
  echo "Configure flags:"
  printf '  %s\n' "${CONFIGURE_FLAGS[@]}"
} > "$OUTPUT_DIR/BUILD-CONFIG.txt"

{
  echo "IntMusic invokes the separately distributed FFmpeg and ffprobe programs."
  echo "This bundle was compiled without --enable-gpl and without --enable-nonfree."
  echo "The exact corresponding source archive is included in the source directory."
  echo "FFmpeg project: https://ffmpeg.org/"
} > "$OUTPUT_DIR/NOTICE.txt"

echo "Bundled FFmpeg:"
echo "  $OUTPUT_DIR"
