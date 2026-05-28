#!/bin/sh
set -euo pipefail

if [ "${CONFIGURATION:-}" != "Simulator" ]; then
  exit 0
fi

PODS_DIR="${PROJECT_DIR}/Pods/Target Support Files/Pods-GlacierPods-Glacier"
SRC_IN="${PODS_DIR}/Pods-GlacierPods-Glacier-frameworks-Debug-input-files.xcfilelist"
SRC_OUT="${PODS_DIR}/Pods-GlacierPods-Glacier-frameworks-Debug-output-files.xcfilelist"
DST_IN="${PODS_DIR}/Pods-GlacierPods-Glacier-frameworks-Simulator-input-files.xcfilelist"
DST_OUT="${PODS_DIR}/Pods-GlacierPods-Glacier-frameworks-Simulator-output-files.xcfilelist"

if [ -f "${SRC_IN}" ] && [ ! -f "${DST_IN}" ]; then
  cp "${SRC_IN}" "${DST_IN}"
fi

if [ -f "${SRC_OUT}" ] && [ ! -f "${DST_OUT}" ]; then
  cp "${SRC_OUT}" "${DST_OUT}"
fi
