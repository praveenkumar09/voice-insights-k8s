#!/usr/bin/env bash
# Build both images for AKS (linux/amd64, even from an Apple-silicon Mac) and push them to Docker Hub.
#
#   docker login -u <your-dockerhub-user>          # once, in your own terminal
#   ./scripts/push-images.sh <your-dockerhub-user> [tag]      # tag defaults to 1.0.0
#
# The UI is built with an EMPTY API address so it calls the API on its own host (see ingress.yaml). To run the UI against another
# address instead, set VITE_VOICE_API_BASE_URL before running, for example VITE_VOICE_API_BASE_URL=https://api.example.com
set -euo pipefail

USER_NAME="${1:?Usage: $0 <dockerhub-user> [tag]}"
TAG="${2:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API_IMAGE="$USER_NAME/voice-insights-api:$TAG"
UI_IMAGE="$USER_NAME/voice-insights-ui:$TAG"

echo "==> Building and pushing $API_IMAGE"
docker buildx build --platform linux/amd64 -t "$API_IMAGE" --push "$ROOT/voice-insights-azureapi"

echo "==> Building and pushing $UI_IMAGE"
docker buildx build --platform linux/amd64 --build-arg "VITE_VOICE_API_BASE_URL=${VITE_VOICE_API_BASE_URL:-}" -t "$UI_IMAGE" --push "$ROOT/voice-insights-ui"

echo
echo "Pushed:"
echo "  $API_IMAGE"
echo "  $UI_IMAGE"
echo "Put these in kustomization.yaml: newName: $USER_NAME/voice-insights-api (and -ui), newTag: \"$TAG\""
