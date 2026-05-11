#!/bin/bash

# ─────────────────────────────────────────────
# Blocklist Validator – High Performance Edition
# ─────────────────────────────────────────────

BLOCK_OUT="blocklists.txt"
BLOCK_TMP="blocklists.tmp"
BLOCK_VALID="blocklists_valid.tmp"
RESOLVERS_FILE="resolvers.tmp"

# Parallel workers – tăng nếu RAM/CPU còn dư, giảm nếu bị throttle
PARALLEL=${PARALLEL:-3000}

trap "rm -f '$BLOCK_TMP' '$BLOCK_VALID' '$RESOLVERS_FILE'; exit" INT TERM EXIT

# ── Pool DNS resolver (xoay vòng để tránh rate-limit) ──────────────────────
cat > "$RESOLVERS_FILE" << 'EOF'
1.1.1.1
1.0.0.1
8.8.8.8
8.8.4.4
9.9.9.9
149.112.112.112
208.67.222.222
208.67.220.220
94.140.14.14
94.140.15.15
76.76.2.0
76.76.10.0
64.6.64.6
64.6.65.6
EOF

# ── Trích xuất domain từ nhiều định dạng blocklist ─────────────────────────
extract_domains() {
  awk '{
    if (/^[[:space:]]*$/ || /^[!#;]/) next
    line = tolower($0)
    sub(/^@@\|\|?/, "", line)
    sub(/^\|\|?/,   "", line)
    sub(/\^.*/,     "", line)
    sub(/[#!].*/,   "", line)
    sub(/\/.*/,     "", line)
    sub(/:.*/,      "", line)
    sub(/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line ~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/ \
        && !seen[line]++) print line
  }'
}

# ── Download + dedup ────────────────────────────────────────────────────────
echo "▶ Downloading blocklists..."
curl -fsSL --max-time 90 --parallel --parallel-immediate \
  https://adguardteam.github.io/HostlistsRegistry/assets/filter_16.txt \
  https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt \
  https://raw.githubusercontent.com/bibicadotnet/AdGuard-Home-blocklists/refs/heads/main/byme.txt \
  https://raw.githubusercontent.com/VeleSila/yhosts/master/hosts \
  https://badmojr.github.io/1Hosts/Lite/adblock.txt \
| extract_domains | sort -u > "$BLOCK_TMP"

TOTAL=$(wc -l < "$BLOCK_TMP")
echo "▶ Total unique domains: $TOTAL"

# ── Phương án A: massdns (nếu có – nhanh nhất, ~100k dom/s) ────────────────
if command -v massdns &>/dev/null; then
  echo "▶ Using massdns (fast path)..."
  massdns \
    -r "$RESOLVERS_FILE" \
    -t A \
    -o S \
    --retry 0 \
    --timeout 1000 \
    --hashmap-size 1000000 \
    -q \
    "$BLOCK_TMP" \
  | awk '{
      # dòng hợp lệ: "domain. A 1.2.3.4" hoặc "domain. AAAA ..."
      if ($2 ~ /^(A|AAAA)$/ && $3 !~ /^(0\.0\.0\.0|127\.)/) {
        sub(/\.$/, "", $1)
        if (!seen[$1]++) print $1
      }
    }' > "$BLOCK_VALID"

# ── Phương án B: dig song song (fallback) ───────────────────────────────────
else
  echo "▶ Using dig (parallel=${PARALLEL})..."
  echo "  (Install massdns for 10-100x faster validation)"

  touch "$BLOCK_VALID"
  RESOLVER_LIST=$(paste -sd' ' "$RESOLVERS_FILE")
  export RESOLVER_LIST

  # Pipe kết quả qua awk để vừa ghi file vừa hiển thị progress
  cat "$BLOCK_TMP" \
  | xargs -n 1 -P "$PARALLEL" bash -c '
      domain="$1"
      # Chọn resolver ngẫu nhiên từ pool
      read -ra R <<< "$RESOLVER_LIST"
      resolver="${R[$((RANDOM % ${#R[@]}))]}"

      # dig: hỏi A trước, nếu không có thì hỏi AAAA
      result=$(dig +short +timeout=1 +tries=1 +bufsize=512 "@${resolver}" "${domain}" A 2>/dev/null)
      [[ -z "$result" ]] && \
        result=$(dig +short +timeout=1 +tries=1 +bufsize=512 "@${resolver}" "${domain}" AAAA 2>/dev/null)

      # Loại bỏ NXDOMAIN / 0.0.0.0 / 127.x
      if [[ -n "$result" && "$result" != *"0.0.0.0"* && "$result" != *"127."* ]]; then
        printf "V %s\n" "$domain"
      else
        printf "I %s\n" "$domain"
      fi
    ' -- \
  | awk -v total="$TOTAL" -v out="$BLOCK_VALID" '
      BEGIN { start = systime(); valid = 0; count = 0 }
      /^V / { print $2 > out; valid++ }
      {
        count++
        if (count % 500 == 0 || count == total) {
          elapsed = systime() - start
          speed   = (elapsed > 0) ? count / elapsed : count
          pct     = count * 100 / total
          eta     = (speed > 0 && count < total) ? int((total - count) / speed) : 0
          printf "\r  Progress: %d/%d (%.1f%%) | Valid: %d | Speed: %.0f dom/s | ETA: %ds   ",
                 count, total, pct, valid, speed, eta
          fflush()
        }
      }
      END { print "" }
    '
fi

# ── Hasil akhir ─────────────────────────────────────────────────────────────
VALID_COUNT=$(wc -l < "$BLOCK_VALID")
echo "▶ Valid: $VALID_COUNT | Removed: $((TOTAL - VALID_COUNT)) dead domains"

sort -u "$BLOCK_VALID" > "$BLOCK_OUT"
echo "✓ Saved → $BLOCK_OUT"
