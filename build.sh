#!/usr/bin/env bash
#
# Build the langid.c command-line executable with CMake.
#
# Usage: ./build.sh [options]
#
#   --debug           Debug build with liblangid debug output (-DDEBUG)
#   --regen-model     Regenerate model.c/model.h from the langid.py model with
#                     Python 3 (requires the `langid` and `numpy` packages)
#   --model FILE      langid.py model to compile in (implies --regen-model)
#   --python          Also build the _langid Python 3 extension module
#   --clean           Remove the build directory before building
#   --build-dir DIR   Build directory (default: ./build)
#   -h, --help        Show this help
#
# The resulting executable is copied to ./langid.
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SRC_DIR/build"
BUILD_TYPE="MinSizeRel"
DEBUG=OFF
REGEN=OFF
PYTHON_EXT=OFF
MODEL="$SRC_DIR/ldpy.model"
CLEAN=0

usage() { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)       BUILD_TYPE="Debug"; DEBUG=ON ;;
    --regen-model) REGEN=ON ;;
    --model)       [[ $# -ge 2 && -f "$2" ]] || { echo "error: --model needs an existing file" >&2; exit 2; }
                   REGEN=ON
                   MODEL="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
                   shift ;;
    --python)      PYTHON_EXT=ON ;;
    --clean)       CLEAN=1 ;;
    --build-dir)   [[ $# -ge 2 ]] || { echo "error: --build-dir needs a directory" >&2; exit 2; }
                   BUILD_DIR="$2"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for tool in cmake pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found in PATH" >&2
    exit 1
  fi
done
if ! command -v protoc-c >/dev/null 2>&1 && ! command -v protoc-gen-c >/dev/null 2>&1; then
  echo "error: protobuf-c compiler not found (macOS: brew install protobuf-c;" \
       "Debian/Ubuntu: apt install protobuf-c-compiler libprotobuf-c-dev)" >&2
  exit 1
fi

if [[ $CLEAN -eq 1 ]]; then
  rm -rf "$BUILD_DIR"
fi

# Use Ninja when available, otherwise CMake's default generator. The generator
# is only chosen on the first configure of a build directory.
GENERATOR_ARGS=()
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]] && command -v ninja >/dev/null 2>&1; then
  GENERATOR_ARGS=(-G Ninja)
fi

if command -v nproc >/dev/null 2>&1; then
  JOBS="$(nproc)"
else
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
fi

cmake -S "$SRC_DIR" -B "$BUILD_DIR" ${GENERATOR_ARGS[@]+"${GENERATOR_ARGS[@]}"} \
      -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
      -DLANGID_DEBUG="$DEBUG" \
      -DLANGID_REGENERATE_MODEL="$REGEN" \
      -DLANGID_MODEL="$MODEL" \
      -DLANGID_BUILD_PYTHON="$PYTHON_EXT"
cmake --build "$BUILD_DIR" --parallel "$JOBS"

cp "$BUILD_DIR/langid" "$SRC_DIR/langid"
echo
echo "Built: $SRC_DIR/langid"
