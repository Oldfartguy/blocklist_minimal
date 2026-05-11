#!/bin/bash

BLOCK_OUT="blocklists.txt"
BLOCK_TMP="blocklists.tmp"
BLOCK_VALID="blocklists_valid.tmp"

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
echo "Validating domains via Google DNS API..."

touch "$BLOCK_VALID"

cat "$BLOCK_TMP" | xargs -n 50 -P 50 bash -c '
  for domain in "$@"; do
    if nslookup -timeout=1 -retry=1 "$domain" 8.8.8.8 > /dev/null 2>&1; then
      echo "V $domain"
    else
      echo "I $domain"
    fi
  done
' -- | awk -v total="$TOTAL" -v out="$BLOCK_VALID" '
  BEGIN { start = systime() }
  /^V / { print $2 > out }
  { 
    count++; 
    if (count % 50 == 0 || count == total) {
      elapsed = systime() - start
      speed = (elapsed > 0) ? count / elapsed : count
      printf "\rProgress: %d/%d (%.1f%%) | Speed: %.0f dom/s  ", count, total, (count*100/total), speed
      fflush()
    } 
  }
  END { print "" }
'

VALID_COUNT=$(wc -l < "$BLOCK_VALID")
echo "Validation complete. Valid domains: $VALID_COUNT (Removed $((TOTAL - VALID_COUNT)) dead domains)"

mv "$BLOCK_VALID" "$BLOCK_OUT"
echo "Done. File saved to $BLOCK_OUT"
