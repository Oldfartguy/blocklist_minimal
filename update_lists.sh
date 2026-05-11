#!/bin/bash

# File output
BLOCK_OUT="blocklists.txt"
BLOCK_TMP="blocklists.tmp"
BLOCK_VALID="blocklists_valid.tmp"

# Cleanup
trap "rm -f $BLOCK_TMP $BLOCK_VALID; exit" INT TERM EXIT

extract_domains() {
  awk '{
    if (/^[[:space:]]*$/ || /^[!#]/) next
    line = tolower($0)
    sub(/^@@\|\|?/, "", line)
    sub(/^\|\|?/, "", line)
    sub(/\^.*/, "", line)
    sub(/[#!].*/, "", line)
    sub(/\/.*/, "", line)
    sub(/:.*/, "", line)
    sub(/^[0-9.]+[[:space:]]+/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/ && !seen[line]++) print line
  }'
}

echo "Downloading and processing blocklists..."
curl -fsSL --max-time 60 \
  https://adguardteam.github.io/HostlistsRegistry/assets/filter_16.txt \
  https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt \
  https://raw.githubusercontent.com/bibicadotnet/AdGuard-Home-blocklists/refs/heads/main/byme.txt \
  https://raw.githubusercontent.com/VeleSila/yhosts/master/hosts \
  https://badmojr.github.io/1Hosts/Lite/adblock.txt \
| extract_domains > "$BLOCK_TMP"

TOTAL=$(wc -l < "$BLOCK_TMP")
echo "Total domains collected: $TOTAL"
echo "Validating domains via Google DNS API (this may take a while)..."

# Parallel check using Google DNS JSON API
# Using -P 50 to balance speed and potential rate limiting
cat "$BLOCK_TMP" | xargs -n 1 -P 50 bash -c '
  domain="$0"
  if curl -s --max-time 2 "https://dns.google/resolve?name=${domain}&type=A" | grep -q "\"Status\": 0"; then
    echo "${domain}"
  fi
' > "$BLOCK_VALID"

VALID_COUNT=$(wc -l < "$BLOCK_VALID")
echo "Validation complete. Valid domains: $VALID_COUNT (Removed $((TOTAL - VALID_COUNT)) dead domains)"

# Save to final destination
mv "$BLOCK_VALID" "$BLOCK_OUT"

echo "Done. File saved to $BLOCK_OUT"
