#!/usr/bin/env bash
set -euo pipefail

# Optional: build the wwebjs-api image from the local checkout and push it to a
# registry of your choice (e.g. GHCR), so you can pin your own version instead of
# the public avoylenko/wwebjs-api image.
#
#   build-whatsapp-image.sh <image-ref> [context-dir]
#   e.g. build-whatsapp-image.sh ghcr.io/uni-devs/kutab-wwebjs-api:1.0.0

IMAGE="${1:-}"
[[ -n "$IMAGE" ]] || { echo "Usage: $0 <image-ref> [context-dir]" >&2; exit 64; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts -> swarm -> providers -> deployment -> repo root -> old/wwebjs-api
DEFAULT_CONTEXT="$(cd "$SCRIPT_DIR/../../../.." && pwd)/old/wwebjs-api"
CONTEXT="${2:-$DEFAULT_CONTEXT}"

[[ -f "$CONTEXT/Dockerfile" ]] || { echo "No Dockerfile at $CONTEXT" >&2; exit 1; }

echo "[INFO] Building $IMAGE from $CONTEXT"
docker build -t "$IMAGE" "$CONTEXT"
echo "[INFO] Pushing $IMAGE"
docker push "$IMAGE"
echo "[INFO] Done. Deploy with: WHATSAPP_IMAGE=$IMAGE deploy-whatsapp.sh"
