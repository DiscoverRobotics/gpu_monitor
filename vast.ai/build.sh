#!/usr/bin/env bash
# Build the vast.ai exporter Docker image.
#
# Default tag matches the one install.sh expects:
#   gpu-monitor-vastai-exporter:latest
#
# Usage:
#   ./build.sh                                  # build with default tag
#   ./build.sh --IMAGE myrepo/vastai:1.0        # custom tag
#   ./build.sh --PUSH                           # also docker push
#   ./build.sh --PLATFORM linux/amd64,linux/arm64 --PUSH  # multi-arch via buildx
#
# Sources (Dockerfile, exporter.py, requirements.txt) are expected next to
# this script, or in $(pwd)/vast.ai/, or in $(pwd). If none of those work,
# pass --SOURCE_DIR explicitly.
set -euo pipefail

IMAGE="${IMAGE:-${VASTAI_EXPORTER_IMAGE:-gpu-monitor-vastai-exporter:latest}}"
SOURCE_DIR="${SOURCE_DIR:-}"
PLATFORM="${PLATFORM:-}"
PUSH="${PUSH:-0}"
NO_CACHE="${NO_CACHE:-0}"
EXTRA_TAGS=()

usage() {
  cat <<EOF
Usage: build.sh [options]

Options:
  --IMAGE       <tag>         Image tag to build (default: ${IMAGE})
  --TAG         <tag>         Additional tag to attach (repeatable)
  --SOURCE_DIR  <dir>         Directory containing Dockerfile + exporter.py + requirements.txt
                              (default: autodetect from this script's dir, \$(pwd)/vast.ai, or \$(pwd))
  --PLATFORM    <list>        Target platform(s), e.g. linux/amd64 or linux/amd64,linux/arm64
                              (uses 'docker buildx' when set)
  --PUSH                      docker push after a successful build
                              (multi-platform builds REQUIRE --PUSH or --load via buildx)
  --NO_CACHE                  Pass --no-cache to docker build
  -h, --help                  Show this help

Environment variables of the same name are honoured as fallbacks; CLI flags win.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --IMAGE)        IMAGE="$2"; shift 2 ;;
    --IMAGE=*)      IMAGE="${1#*=}"; shift ;;
    --TAG)          EXTRA_TAGS+=("$2"); shift 2 ;;
    --TAG=*)        EXTRA_TAGS+=("${1#*=}"); shift ;;
    --SOURCE_DIR)   SOURCE_DIR="$2"; shift 2 ;;
    --SOURCE_DIR=*) SOURCE_DIR="${1#*=}"; shift ;;
    --PLATFORM)     PLATFORM="$2"; shift 2 ;;
    --PLATFORM=*)   PLATFORM="${1#*=}"; shift ;;
    --PUSH)         PUSH=1; shift ;;
    --NO_CACHE)     NO_CACHE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

say()   { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 \
  || fail "docker not found — install it first (or run vast.ai/install.sh which auto-installs it)."

autodetect_source_dir() {
  local script_dir=""
  case "${BASH_SOURCE[0]:-}" in
    /*) script_dir="$(dirname "${BASH_SOURCE[0]}")" ;;
    ./*|*/*) script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
    *) script_dir="" ;;
  esac
  local candidates=()
  [ -n "${script_dir}" ] && candidates+=("${script_dir}")
  candidates+=("$(pwd)/vast.ai" "$(pwd)")
  for c in "${candidates[@]}"; do
    if [ -f "${c}/Dockerfile" ] && [ -f "${c}/exporter.py" ] && [ -f "${c}/requirements.txt" ]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  return 1
}

if [ -z "${SOURCE_DIR}" ]; then
  SOURCE_DIR="$(autodetect_source_dir || true)"
fi
[ -n "${SOURCE_DIR}" ] \
  || fail "could not locate Dockerfile/exporter.py/requirements.txt — pass --SOURCE_DIR <dir>."
[ -f "${SOURCE_DIR}/Dockerfile" ]       || fail "missing ${SOURCE_DIR}/Dockerfile"
[ -f "${SOURCE_DIR}/exporter.py" ]      || fail "missing ${SOURCE_DIR}/exporter.py"
[ -f "${SOURCE_DIR}/requirements.txt" ] || fail "missing ${SOURCE_DIR}/requirements.txt"

say "source dir : ${SOURCE_DIR}"
say "image      : ${IMAGE}"
[ ${#EXTRA_TAGS[@]} -gt 0 ] && say "extra tags : ${EXTRA_TAGS[*]}"
[ -n "${PLATFORM}" ]        && say "platform   : ${PLATFORM}"
[ "${PUSH}" = "1" ]         && say "push       : yes"

tag_args=( -t "${IMAGE}" )
for t in "${EXTRA_TAGS[@]}"; do
  tag_args+=( -t "${t}" )
done

build_args=()
[ "${NO_CACHE}" = "1" ] && build_args+=( --no-cache )

if [ -n "${PLATFORM}" ]; then
  docker buildx version >/dev/null 2>&1 \
    || fail "--PLATFORM requires 'docker buildx' — install/enable buildx and retry."
  # Need a builder that can target multiple arches.
  if ! docker buildx inspect vastai-exporter-builder >/dev/null 2>&1; then
    say "creating buildx builder 'vastai-exporter-builder' ..."
    docker buildx create --name vastai-exporter-builder --use >/dev/null
  else
    docker buildx use vastai-exporter-builder >/dev/null
  fi
  output_flag=()
  if [ "${PUSH}" = "1" ]; then
    output_flag=( --push )
  else
    case "${PLATFORM}" in
      *,*) fail "multi-platform builds must be pushed or use --load (single platform) — pass --PUSH or drop one platform." ;;
      *)   output_flag=( --load ) ;;
    esac
  fi
  say "running: docker buildx build --platform ${PLATFORM} ${tag_args[*]} ${build_args[*]:-} ${output_flag[*]} ${SOURCE_DIR}"
  docker buildx build --platform "${PLATFORM}" "${tag_args[@]}" "${build_args[@]}" "${output_flag[@]}" "${SOURCE_DIR}"
else
  say "running: docker build ${tag_args[*]} ${build_args[*]:-} ${SOURCE_DIR}"
  docker build "${tag_args[@]}" "${build_args[@]}" "${SOURCE_DIR}"
  if [ "${PUSH}" = "1" ]; then
    say "pushing ${IMAGE} ..."
    docker push "${IMAGE}"
    for t in "${EXTRA_TAGS[@]}"; do
      say "pushing ${t} ..."
      docker push "${t}"
    done
  fi
fi

say "done."
if [ "${PUSH}" = "0" ] && [ -z "${PLATFORM}" ]; then
  say "image is now available locally:"
  docker image inspect "${IMAGE}" --format '  {{.Id}}  ({{.Size}} bytes)' || true
  say "next: deploy with vast.ai/install.sh (uses ${IMAGE} by default)."
fi
