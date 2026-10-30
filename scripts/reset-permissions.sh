#!/usr/bin/env bash
# Clears SignType's Accessibility and Camera grants so macOS prompts again.
# Needed once after the app's code signature changes (e.g. switching from ad-hoc
# signing to a certificate): the old grant stays listed but no longer matches.
set -euo pipefail
BUNDLE_ID="dev.loran.signtype"
for service in Accessibility Camera; do
  echo "▸ tccutil reset $service $BUNDLE_ID"
  tccutil reset "$service" "$BUNDLE_ID" || true
done
echo "Done. Relaunch SignType and grant both permissions when prompted."
