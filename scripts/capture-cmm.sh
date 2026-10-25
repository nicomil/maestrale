#!/bin/zsh
# Records the file paths that CleanMyMac reads while it scans.
# Run it, start a scan in CleanMyMac (never clean), then press Ctrl+C.
set -eu
cd "$(dirname "$0")/.."
mkdir -p re-notes/dynamic
out="re-notes/dynamic/fs_usage-$(date +%Y%m%d-%H%M%S).log"
echo "Writing to $out — press Ctrl+C when the scans are done."
sudo fs_usage -w -f pathname CleanMyMac_5 com.macpaw.CleanMyMac5.Agent CleanMyMac_5_HealthMonitor > "$out" || true
echo "Saved $out"
