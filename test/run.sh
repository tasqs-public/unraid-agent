#!/usr/bin/env bash
# test/run.sh — exercise Tasqs.sh without unRAID or the network.
# A fake `curl` on PATH records the request it was given (headers + body) and
# answers 201, so the assertions check what the agent SENDS: key derivation in
# each mode, prefix stripping, resolve detection, level filtering, encoding of
# awkward characters, idempotency stability, the https-only link rule, signed
# headers that verify, and that every path exits 0.
#   bash test/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got: $1 | want: $2)"; fi; }

# ── A script copy with a test HOOK/SECRET, and a fake curl + logger ─────────
mkdir -p "$TMP/bin"
sed -e "s#^HOOK=.*#HOOK='https://tasqs.example/hook/tqh_0123456789abcdef0123456789abcdef01234567'#" "$ROOT/Tasqs.sh" > "$TMP/Tasqs.sh"
chmod +x "$TMP/Tasqs.sh"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# records: URL, headers (one per line), body; answers 201 created
out="${FAKE_CURL_OUT:?}"; : > "$out"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H) echo "H:$2" >> "$out"; shift 2 ;;
    --data-binary) echo "B:$2" >> "$out"; shift 2 ;;
    -X|-m|-w) shift 2 ;;
    http*|https*) echo "U:$1" >> "$out"; shift ;;
    *) shift ;;
  esac
done
printf '{"status":"created","task":{"id":"a"}}\n201'
EOF
cat > "$TMP/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_LOG:-/dev/null}"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/logger"
export PATH="$TMP/bin:$PATH" FAKE_CURL_OUT="$TMP/req" FAKE_LOG="$TMP/log"

run() { # env assignments… → runs the agent; body decoded into $F (assoc array)
  : > "$FAKE_CURL_OUT"
  env -i PATH="$PATH" HOME="$HOME" FAKE_CURL_OUT="$FAKE_CURL_OUT" FAKE_LOG="$FAKE_LOG" "$@" bash "$TMP/Tasqs.sh"; RC=$?
  BODY=$(sed -n 's/^B://p' "$FAKE_CURL_OUT")
  declare -gA F=()
  if [[ -n "$BODY" ]]; then
    while IFS='=' read -r k v; do F["$k"]=$(printf '%b' "${v//%/\\x}"); done < <(tr '&' '\n' <<<"$BODY")
  fi
}

# ── Basic warning ───────────────────────────────────────────────────────────
run EVENT='Unraid Disk temperature' SUBJECT='Warning [TOWER] - Disk 3 is hot (41 C)' DESCRIPTION='Temperature exceeded 40 C' IMPORTANCE=warning HOSTNAME=TOWER TIMESTAMP=1762300000
check "$RC" "0" "exit 0 on a normal delivery"
check "${F[title]}" "Disk 3 is hot (41 C)" "title: unRAID prefix stripped"
check "${F[body]}" "Temperature exceeded 40 C" "body passed through"
check "${F[level]}" "warning" "level = IMPORTANCE"
check "${F[key]}" "Unraid Disk temperature|disk 3" "key (stem mode) = EVENT|first two words, lower-cased"
check "${F[source]}" "TOWER" "source = HOSTNAME"
check "${F[timestamp]}" "1762300000" "timestamp passed through"
check "${F[resolve]}" "false" "resolve false for a warning"
check "${#F[idempotency_key]}" "32" "idempotency key present (32 hex)"
IDEM1="${F[idempotency_key]}"
check "$(sed -n 's/^U://p' "$FAKE_CURL_OUT")" "https://tasqs.example/hook/tqh_0123456789abcdef0123456789abcdef01234567" "posts to HOOK"
grep -q '^H:Content-Type: application/x-www-form-urlencoded$' "$FAKE_CURL_OUT" && ok "form content-type" || bad "form content-type"
grep -q '^H:X-Tasqs-Signature' "$FAKE_CURL_OUT" && bad "no signature when SECRET empty" || ok "no signature when SECRET empty"

# ── Same input again → same idempotency key; resolve wording → resolve=true ─
run EVENT='Unraid Disk temperature' SUBJECT='Warning [TOWER] - Disk 3 is hot (41 C)' DESCRIPTION='x' IMPORTANCE=warning HOSTNAME=TOWER TIMESTAMP=1762300000
check "${F[idempotency_key]}" "$IDEM1" "idempotency key is stable for the same notification"
run EVENT='Unraid Disk temperature' SUBJECT='Notice [TOWER] - Disk 3 returned to normal temperature' DESCRIPTION='' IMPORTANCE=normal HOSTNAME=TOWER
check "${F[resolve]}" "true" "resolve true on 'returned to normal'"
check "${F[key]}" "Unraid Disk temperature|disk 3" "all-clear derives the SAME key as the warning"
check "${F[level]}" "normal" "all-clear level normal"

# ── Key modes ───────────────────────────────────────────────────────────────
sed -i "s/^KEY_MODE=.*/KEY_MODE='event'/" "$TMP/Tasqs.sh"
run EVENT='Unraid array errors' SUBJECT='Alert [TOWER] - Array has errors' IMPORTANCE=alert
check "${F[key]}" "Unraid array errors" "key (event mode) = EVENT only"
sed -i "s/^KEY_MODE=.*/KEY_MODE='full'/" "$TMP/Tasqs.sh"
run EVENT='E' SUBJECT='Warning [TOWER] - Cache Pool is 95% full' IMPORTANCE=warning
check "${F[key]}" "E|cache pool is 95% full" "key (full mode) = EVENT|whole subject lower-cased"
sed -i "s/^KEY_MODE=.*/KEY_MODE='stem'/" "$TMP/Tasqs.sh"

# ── Level filter ────────────────────────────────────────────────────────────
sed -i "s/^LEVELS=.*/LEVELS='warning alert'/" "$TMP/Tasqs.sh"
run EVENT='E' SUBJECT='Notice [TOWER] - Array started' IMPORTANCE=normal
check "$RC" "0" "filtered level still exits 0"
check "$(wc -c < "$FAKE_CURL_OUT" | tr -d ' ')" "0" "normal level not sent when LEVELS excludes it"
run EVENT='E' SUBJECT='Alert [TOWER] - Parity check failed' IMPORTANCE=alert
check "${F[level]}" "alert" "alert level sent"
sed -i "s/^LEVELS=.*/LEVELS='normal warning alert'/" "$TMP/Tasqs.sh"

# ── Encoding of awkward characters ──────────────────────────────────────────
run EVENT='E&F' SUBJECT='Warning [TOWER] - Share "media" 100% full & rising; café=ok+?' DESCRIPTION=$'line one\nline two' IMPORTANCE=warning
check "${F[title]}" 'Share "media" 100% full & rising; café=ok+?' "title survives quotes, %, &, ;, =, +, ?, UTF-8"
check "${F[body]}" $'line one\nline two' "body keeps its newline"
check "${F[key]}" 'E&F|share "media"' "key with & in EVENT"
grep -q '^B:' "$FAKE_CURL_OUT" && ! grep -q ' ' <(sed -n 's/^B://p' "$FAKE_CURL_OUT") && ok "body has no raw spaces (encoded)" || bad "body encoding"

# ── Link rule ───────────────────────────────────────────────────────────────
run EVENT='E' SUBJECT='Warning [TOWER] - x' IMPORTANCE=warning LINK='https://tower.local/Main'
check "${F[url]:-}" "https://tower.local/Main" "https LINK forwarded as url"
run EVENT='E' SUBJECT='Warning [TOWER] - x' IMPORTANCE=warning LINK='http://tower.local/Main'
check "${F[url]:-unset}" "unset" "http LINK dropped"

# ── No prefix, missing optional vars ────────────────────────────────────────
run EVENT='E' SUBJECT='Plain subject without prefix' IMPORTANCE=warning
check "${F[title]}" "Plain subject without prefix" "subject without a prefix kept whole"
check "${F[key]}" "E|plain subject" "stem from a prefix-less subject"
[[ -n "${F[source]}" ]] && ok "source falls back to hostname" || bad "source fallback"
[[ "${F[timestamp]}" =~ ^[0-9]{9,11}$ ]] && ok "timestamp falls back to now" || bad "timestamp fallback"

# ── Signed mode ─────────────────────────────────────────────────────────────
SECRET='tqhs_testsecret'
sed -i "s/^SECRET=.*/SECRET='$SECRET'/" "$TMP/Tasqs.sh"
run EVENT='E' SUBJECT='Warning [TOWER] - signed' IMPORTANCE=warning
TSH=$(sed -n 's/^H:X-Tasqs-Timestamp: //p' "$FAKE_CURL_OUT"); SIGH=$(sed -n 's/^H:X-Tasqs-Signature: v1=//p' "$FAKE_CURL_OUT")
[[ "$TSH" =~ ^[0-9]{9,11}$ ]] && ok "signed: timestamp header present" || bad "signed: timestamp header"
EXP=$(printf '%s.%s' "$TSH" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
check "$SIGH" "$EXP" "signed: v1 HMAC-SHA256(secret, ts.body) verifies over the exact body sent"
sed -i "s/^SECRET=.*/SECRET=''/" "$TMP/Tasqs.sh"

# ── Unconfigured HOOK: silent, exit 0, nothing sent ─────────────────────────
sed -i "s#^HOOK=.*#HOOK='https://tasqs.com/hook/tqh_REPLACE_ME'#" "$TMP/Tasqs.sh"
run EVENT='E' SUBJECT='x' IMPORTANCE=alert
check "$RC" "0" "unconfigured HOOK exits 0"
check "$(wc -c < "$FAKE_CURL_OUT" | tr -d ' ')" "0" "unconfigured HOOK sends nothing"
grep -q 'HOOK not set' "$FAKE_LOG" && ok "unconfigured HOOK logs a hint" || bad "unconfigured HOOK log"

# ── The generated Agents-tab template, with {0} substituted the way unRAID does ──
bash "$ROOT/build.sh" >/dev/null
python3 - "$ROOT/plugin/Tasqs.xml" "$TMP/Agent.sh" <<'PY'
import sys, xml.etree.ElementTree as ET
x = ET.parse(sys.argv[1]).getroot()
script = x.find('Script').text
vals = 'HOOK_URL="https://tasqs.example/hook/tqh_0123456789abcdef0123456789abcdef01234567"\nSIGNING_SECRET="none"\nKEY_MODE="stem"\nRESOLVE_PATTERN="returned to normal|is back"'
open(sys.argv[2], 'w').write(script.replace('{0}', vals).lstrip())
PY
runa() { : > "$FAKE_CURL_OUT"; env -i PATH="$PATH" HOME="$HOME" FAKE_CURL_OUT="$FAKE_CURL_OUT" FAKE_LOG="$FAKE_LOG" "$@" bash "$TMP/Agent.sh"; RC=$?
  BODY=$(sed -n 's/^B://p' "$FAKE_CURL_OUT"); declare -gA F=()
  [[ -n "$BODY" ]] && while IFS='=' read -r k v; do F["$k"]=$(printf '%b' "${v//%/\\x}"); done < <(tr '&' '\n' <<<"$BODY"); }
runa EVENT='Unraid Disk temperature' SUBJECT='Warning [TOWER] - Disk 3 is hot (41 C)' DESCRIPTION='x' IMPORTANCE=warning HOSTNAME=TOWER
check "$RC" "0" "template: exits 0"
check "${F[title]}" "Disk 3 is hot (41 C)" "template: same title handling as the script"
check "${F[key]}" "Unraid Disk temperature|disk 3" "template: KEY_MODE from the GUI field"
check "$(sed -n 's/^U://p' "$FAKE_CURL_OUT")" "https://tasqs.example/hook/tqh_0123456789abcdef0123456789abcdef01234567" "template: HOOK_URL from the GUI field"
runa
check "${F[title]}" "Notification" "template: Agents-tab Test button (no env) → 'Notification'"
check "${F[key]}" "Unraid Status|notification" "template: Test button key from the defaults"
runa SUBJECT='Notice [TOWER] - Disk 3 is back' IMPORTANCE=normal
check "${F[resolve]}" "true" "template: RESOLVE_PATTERN from the GUI field"
sed -i 's/^SIGNING_SECRET="none"/SIGNING_SECRET="tqhs_fromgui"/' "$TMP/Agent.sh"
runa SUBJECT='x' IMPORTANCE=alert
grep -q '^H:X-Tasqs-Signature: v1=' "$FAKE_CURL_OUT" && ok "template: SIGNING_SECRET from the GUI enables signing" || bad "template: signing from GUI"
sed -i 's#^HOOK_URL=.*#HOOK_URL="https://tasqs.com/hook/tqh_PASTE_YOUR_WEBHOOK_URL"#' "$TMP/Agent.sh"
runa SUBJECT='x' IMPORTANCE=alert
check "$(wc -c < "$FAKE_CURL_OUT" | tr -d ' ')" "0" "template: the placeholder URL sends nothing"
runa DESCRIPTION='line one\nline two' SUBJECT='x' IMPORTANCE=alert HOOK_URL=ignored
sed -i 's#^HOOK_URL=.*#HOOK_URL="https://tasqs.example/hook/tqh_0123456789abcdef0123456789abcdef01234567"#' "$TMP/Agent.sh"
runa DESCRIPTION='line one\nline two' SUBJECT='x' IMPORTANCE=alert
check "${F[body]}" $'line one\nline two' "template: literal \\n in DESCRIPTION becomes a line break (the built-in agents' convention)"

# ── Log never contains the token ────────────────────────────────────────────
grep -q 'tqh_0123456789' "$FAKE_LOG" && bad "token leaked into the log" || ok "token never logged"

echo; echo "passed $PASS, failed $FAIL"
exit $(( FAIL > 0 ))
