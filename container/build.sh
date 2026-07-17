#!/bin/bash
# Build the NanoClaw agent container image.
#
# Reads one optional build flag from ../.env:
#   INSTALL_CJK_FONTS=true   — add Chinese/Japanese/Korean fonts (~200MB)
# setup/container.ts reads the same file, so both build paths stay in sync.
# Callers can also override by exporting INSTALL_CJK_FONTS directly.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Build context is the project root so we can COPY both container/ and shared/
# into the image. The Dockerfile path is passed explicitly via -f.
cd "$PROJECT_ROOT"

# Derive the image name from the project root so two NanoClaw installs on the
# same host don't overwrite each other's `nanoclaw-agent:latest` tag. Matches
# setup/lib/install-slug.sh + src/install-slug.ts.
# shellcheck source=../setup/lib/install-slug.sh
source "$PROJECT_ROOT/setup/lib/install-slug.sh"
IMAGE_NAME="$(container_image_base)"
TAG="${1:-latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

# Caller's env takes precedence; fall back to .env. Absolute path — this used
# to be `../.env`, which broke silently when the build context moved to the
# project root and left the relative path pointing at the checkout's parent.
if [ -z "${INSTALL_CJK_FONTS:-}" ] && [ -f "$PROJECT_ROOT/.env" ]; then
    INSTALL_CJK_FONTS="$(grep '^INSTALL_CJK_FONTS=' "$PROJECT_ROOT/.env" | tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
fi

BUILD_ARGS=()
if [ "${INSTALL_CJK_FONTS:-false}" = "true" ]; then
    echo "CJK fonts: enabled (adds ~200MB)"
    BUILD_ARGS+=(--build-arg INSTALL_CJK_FONTS=true)
fi

echo "Building NanoClaw agent container image..."
echo "Image: ${IMAGE_NAME}:${TAG}"

${CONTAINER_RUNTIME} build "${BUILD_ARGS[@]}" -f "$SCRIPT_DIR/Dockerfile" -t "${IMAGE_NAME}:${TAG}" .

echo ""
echo "Build complete!"
echo "Image: ${IMAGE_NAME}:${TAG}"
echo ""
echo "Test with:"
echo "  echo '{\"prompt\":\"What is 2+2?\",\"groupFolder\":\"test\",\"chatJid\":\"test@g.us\",\"isMain\":false}' | ${CONTAINER_RUNTIME} run -i ${IMAGE_NAME}:${TAG}"
