#!/usr/bin/env bash
#
# Build a fully static x86_64 Linux langid executable for a Synology NAS
# (e.g. DS1019+, apollolake) using Docker and Alpine (musl).
#
# Usage: ./build_nas.sh
#
# The result is written to ./dist/langid. It has no runtime dependencies, so
# it can be copied to the NAS as-is:
#   scp dist/langid admin@<nas-ip>:~/bin/
#
# Alpine ships no static libprotobuf-c.a, so the protobuf-c runtime (a single
# C file) is compiled straight into the executable. Its version must match the
# protoc-c from Alpine's protobuf-c-compiler package.
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SRC_DIR}/dist"
ALPINE_IMAGE="alpine:3.20"
PROTOBUF_C_VERSION="1.5.0"

for f in model.c model.h; do
  if [[ ! -f "${SRC_DIR}/${f}" ]]; then
    echo "error: ${f} is missing; generate it first (e.g. ./build.sh --regen-model)" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker daemon is not running (macOS: open -a Docker)" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

# Sources are copied into /tmp/b inside the container so that any stale
# langid.pb-c.h in the source tree cannot shadow the freshly generated one.
docker run --rm --platform linux/amd64 \
  -e PROTOBUF_C_VERSION="${PROTOBUF_C_VERSION}" \
  -v "${SRC_DIR}":/src:ro -v "${OUT_DIR}":/out "${ALPINE_IMAGE}" sh -euc '
  apk add --no-cache build-base protobuf-c-compiler >/dev/null
  mkdir -p /tmp/b && cd /tmp/b
  wget -q "https://github.com/protobuf-c/protobuf-c/releases/download/v${PROTOBUF_C_VERSION}/protobuf-c-${PROTOBUF_C_VERSION}.tar.gz"
  tar xzf "protobuf-c-${PROTOBUF_C_VERSION}.tar.gz"
  cp /src/langid.c /src/liblangid.c /src/liblangid.h /src/sparseset.c /src/sparseset.h \
     /src/model.c /src/model.h /src/langid.proto .
  protoc-c --c_out=. langid.proto
  gcc -Os -Wall -static -I. -I"protobuf-c-${PROTOBUF_C_VERSION}" -o langid \
      langid.c liblangid.c sparseset.c model.c langid.pb-c.c \
      "protobuf-c-${PROTOBUF_C_VERSION}/protobuf-c/protobuf-c.c"
  strip langid
  cp langid /out/langid
  echo "Le chat est sur la table." | /out/langid'

echo
echo "Built: ${OUT_DIR}/langid"
