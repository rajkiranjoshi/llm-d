#!/usr/bin/env bash
# Build the libfabric-addon init container image.
#
# Reads configuration from build.env (copy build.env.example to get started).
# All paths in build.env are relative to this script's directory.
#
# Usage:
#   ./build.sh              # build using build.env
#   ./build.sh --push       # build and push to ADDON_PUSH_TARGET
#   ./build.sh --no-cache   # full rebuild without layer cache
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Load config ──────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/build.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: build.env not found." >&2
    echo "  cp build.env.example build.env   # then edit" >&2
    exit 1
fi

set -a
# shellcheck source=build.env.example
source "$ENV_FILE"
set +a

# ── Validate required variables ──────────────────────────────────────────
: "${BASE_IMAGE:?BASE_IMAGE is required in build.env}"
: "${ENTITLEMENT_DIR:?ENTITLEMENT_DIR is required in build.env}"
: "${RHSM_CA_DIR:?RHSM_CA_DIR is required in build.env}"
: "${ADDON_IMAGE_TAG:?ADDON_IMAGE_TAG is required in build.env}"

# Resolve relative paths against script dir
ENTITLEMENT_DIR="$(cd "$SCRIPT_DIR" && realpath "$ENTITLEMENT_DIR")"
RHSM_CA_DIR="$(cd "$SCRIPT_DIR" && realpath "$RHSM_CA_DIR")"

if [[ ! -d "$ENTITLEMENT_DIR" ]] || [[ -z "$(ls "$ENTITLEMENT_DIR"/*.pem 2>/dev/null)" ]]; then
    echo "Error: ENTITLEMENT_DIR ($ENTITLEMENT_DIR) missing or has no .pem files." >&2
    echo "  See rhel-subscription-setup.md for how to obtain RHEL certs." >&2
    exit 1
fi
if [[ ! -f "$RHSM_CA_DIR/redhat-uep.pem" ]]; then
    echo "Error: RHSM_CA_DIR ($RHSM_CA_DIR) missing redhat-uep.pem." >&2
    exit 1
fi

# ── Parse CLI flags ──────────────────────────────────────────────────────
PUSH=false
EXTRA_BUILD_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --push)     PUSH=true ;;
        --no-cache) EXTRA_BUILD_ARGS+=(--no-cache) ;;
        *)          echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

# ── Prepare build args ───────────────────────────────────────────────────
BUILD_ARGS=(
    --build-arg "BASE_IMAGE=${BASE_IMAGE}"
)
if [[ -n "${NIXL_VERSION:-}" ]]; then
    BUILD_ARGS+=(--build-arg "NIXL_VERSION=${NIXL_VERSION}")
fi
if [[ -n "${AWS_LIBFABRIC_VERSION:-}" ]]; then
    BUILD_ARGS+=(--build-arg "AWS_LIBFABRIC_VERSION=${AWS_LIBFABRIC_VERSION}")
fi

# Tags
TAGS=(-t "$ADDON_IMAGE_TAG")
if [[ -n "${ADDON_PUSH_TARGET:-}" ]]; then
    TAGS+=(-t "$ADDON_PUSH_TARGET")
fi

# ── Build ────────────────────────────────────────────────────────────────
echo "━━━ libfabric-addon build ━━━"
echo "  Base image:   $BASE_IMAGE"
echo "  Entitlements: $ENTITLEMENT_DIR"
echo "  RHSM CA:      $RHSM_CA_DIR"
echo "  Image tag:    $ADDON_IMAGE_TAG"
[[ -n "${ADDON_PUSH_TARGET:-}" ]] && echo "  Push target:  $ADDON_PUSH_TARGET"
[[ -n "${NIXL_VERSION:-}" ]]      && echo "  NIXL:         $NIXL_VERSION"
[[ -n "${AWS_LIBFABRIC_VERSION:-}" ]] && echo "  AWS libfabric: $AWS_LIBFABRIC_VERSION"
echo ""

podman build \
    "${BUILD_ARGS[@]}" \
    "${TAGS[@]}" \
    "${EXTRA_BUILD_ARGS[@]}" \
    -f Dockerfile \
    .

echo ""
echo "Build complete: $ADDON_IMAGE_TAG"

# ── Push (optional) ──────────────────────────────────────────────────────
if [[ "$PUSH" == "true" ]] && [[ -n "${ADDON_PUSH_TARGET:-}" ]]; then
    echo "Pushing $ADDON_PUSH_TARGET ..."
    podman push "$ADDON_PUSH_TARGET"
    echo "Pushed: $ADDON_PUSH_TARGET"
elif [[ "$PUSH" == "true" ]]; then
    echo "Warning: --push specified but ADDON_PUSH_TARGET is not set in build.env" >&2
fi
