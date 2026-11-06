#!/bin/bash
# =============================================================================
# Tasqs.sh — unRAID notification agent for Tasqs (https://tasqs.com)
# -----------------------------------------------------------------------------
# Every unRAID notification becomes a task; the matching "returned to normal"
# completes it. Drop this file in
#
#     /boot/config/plugins/dynamix/notifications/agents/Tasqs.sh
#
# (the flash drive, so it survives reboots and upgrades) and tick the "Custom" column for the importance levels you want in
# Settings → Notifications. Full instructions: README.md in this repo.
#
# unRAID hands each notification over as environment variables:
#   EVENT        the notification's category ("Unraid Disk temperature")
#   SUBJECT      the headline ("Warning [TOWER] - Disk 3 is hot (41 C)")
#   DESCRIPTION  the detail line
#   IMPORTANCE   normal | warning | alert
#   TIMESTAMP    unix seconds (newer builds)
#   HOSTNAME, CONTENT, LINK   (newer builds; all optional here)
#
# This script never fails the notification: every path exits 0, and curl is
# given a timeout. Results go to the system log (`logger -t tasqs`), never the
# webhook URL.
# =============================================================================
VERSION='1.1.0'

# ── Configuration ────────────────────────────────────────────────────────────
# Your webhook URL from Profile → Webhooks (the only required setting).
HOOK='https://tasqs.com/hook/tqh_REPLACE_ME'

# Signing secret, if you turned on "Require a signature" for the webhook
# (optional; leave empty otherwise). A leaked URL alone then adds nothing.
SECRET=''

# Which importance levels to forward. unRAID's "Custom" column already filters
# at the source; this is a second gate for a script shared between servers.
# One or more of: normal warning alert
LEVELS='normal warning alert'

# How to decide that two notifications are "the same thing", so the webhook
# skips repeats and an all-clear can complete the task the warning opened:
#   stem   EVENT + the first two words of the subject   ("…|disk 3")   [default]
#   event  EVENT only — one open task per category ("Disk temperature")
#   full   the whole subject — every distinct wording is its own task
KEY_MODE='stem'

# Subjects/descriptions that mean "this is resolved" (case-insensitive regex).
RESOLVE_PATTERN='returned to normal|is back|back online|finished|completed|resolved|restored|has been fixed'

# Seconds to wait for Tasqs before giving up (then retry twice).
TIMEOUT=10
# ── End of configuration ─────────────────────────────────────────────────────

log() { command -v logger >/dev/null && logger -t tasqs -- "$*"; }

# ── Test mode: `Tasqs.sh --test` sends a sample warning + its all-clear ─────
if [[ "${1:-}" == "--test" ]]; then
  if [[ "$HOOK" == *REPLACE_ME* ]]; then echo "Set HOOK in $0 first." >&2; exit 1; fi
  export EVENT='Tasqs test' IMPORTANCE='warning' HOSTNAME="${HOSTNAME:-$(hostname)}" TIMESTAMP="$(date +%s)"
  export SUBJECT="Warning [$HOSTNAME] - Tasqs agent test" DESCRIPTION="If you can read this as a task, the agent works. The next call completes it."
  bash "$0"; sleep 2          # bash, not "$0": /boot is mounted noexec on unRAID
  export IMPORTANCE='normal' SUBJECT="Notice [$HOSTNAME] - Tasqs agent returned to normal" DESCRIPTION="Resolving the test task."
  bash "$0"
  echo "Sent a warning and its all-clear. Check the dashboard (and Profile → Webhooks → Recent deliveries)."
  exit 0
fi
if [[ "${1:-}" == "--version" ]]; then echo "Tasqs.sh $VERSION"; exit 0; fi

# ── Guards and defaults (the built-in agents' conventions) ─────────────────
[[ "$HOOK" == *REPLACE_ME* || -z "$HOOK" ]] && { log "HOOK not set; edit $0"; exit 0; }
IMP="${IMPORTANCE:-normal}"
case " $LEVELS " in *" $IMP "*) ;; *) exit 0 ;; esac          # level not forwarded
EVENT="${EVENT:-Unraid Status}"
SUBJ="${SUBJECT:-Notification}"                                # what the Agents-tab Test button sends: no env at all
DESCRIPTION="${DESCRIPTION:-}"
[[ "$DESCRIPTION" == 'No description' ]] && DESCRIPTION=''
# unRAID passes literal \n sequences in reports; make them real line breaks.
DESCRIPTION=${DESCRIPTION//\\r\\n/$'\n'}; DESCRIPTION=${DESCRIPTION//\\n/$'\n'}; DESCRIPTION=${DESCRIPTION//\\r/$'\n'}
[[ -n "${CONTENT:-}" ]] && DESCRIPTION="${DESCRIPTION:+$DESCRIPTION$'\n\n'}${CONTENT//\\n/$'\n'}"

# ── Key: what makes this notification "the same thing" next time ────────────
# Strip unRAID's "Warning [TOWER] - " prefix when present, then take the stem.
BARE=$(sed -E 's/^(Notice|Warning|Alert|Normal|Info)[[:space:]]*\[[^]]*\][[:space:]]*-[[:space:]]*//I' <<<"$SUBJ")
case "$KEY_MODE" in
  event) KEY="${EVENT:-unraid}" ;;
  full)  KEY="${EVENT:-unraid}|$(tr '[:upper:]' '[:lower:]' <<<"$BARE")" ;;
  *)     KEY="${EVENT:-unraid}|$(awk '{k=$1; if ($2!="") k=k" "$2; print tolower(k)}' <<<"$BARE")" ;;
esac
# Lower-case "normal" wording so "Disk 3 is hot" and "Disk 3 returned to normal" share a stem.

# ── Resolve? ────────────────────────────────────────────────────────────────
RESOLVE=false
grep -qiE "$RESOLVE_PATTERN" <<<"$SUBJ $DESCRIPTION" && RESOLVE=true

# ── Build the request (form-encoded; one code path, signed or not) ─────────
HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo unraid)}"
TS="${TIMESTAMP:-$(date +%s)}"
# Idempotency: a retry after a timeout must never make a second task.
IDEM=$(printf '%s|%s|%s' "$TS" "${EVENT:-}" "$SUBJ" | md5sum | cut -c1-32)

# Percent-encode (RFC 3986 unreserved set kept; UTF-8 bytes encoded).
urlenc() {
  local LC_ALL=C s="$1" out='' i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v c '%%%02X' "'$c"; out+="$c" ;; esac
  done
  printf '%s' "$out"
}
field() { printf '%s=%s' "$1" "$(urlenc "$2")"; }

BODY="$(field title "$BARE")&$(field body "$DESCRIPTION")&$(field level "$IMP")&$(field key "$KEY")"
BODY+="&$(field source "$HOST")&$(field timestamp "$TS")&$(field resolve "$RESOLVE")&$(field idempotency_key "$IDEM")"
[[ -n "${LINK:-}" && "$LINK" == https://* ]] && BODY+="&$(field url "$LINK")"

HDRS=(-H 'Content-Type: application/x-www-form-urlencoded')
if [[ -n "$SECRET" ]]; then
  # Signed mode: v1=HMAC-SHA256(secret, "<ts>.<raw body>") over the exact bytes sent.
  NOW=$(date +%s)
  SIG=$(printf '%s.%s' "$NOW" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
  HDRS+=(-H "X-Tasqs-Timestamp: $NOW" -H "X-Tasqs-Signature: v1=$SIG")
fi

RESP=$(curl -sS -m "$TIMEOUT" --retry 2 --retry-connrefused -X POST "$HOOK" "${HDRS[@]}" --data-binary "$BODY" -w '\n%{http_code}' 2>&1)

CODE="${RESP##*$'\n'}"
BODY_OUT="${RESP%$'\n'*}"
STATUS=$(sed -n 's/.*"status":"\([a-z_]*\)".*/\1/p' <<<"$BODY_OUT")
case "$CODE" in
  201|200) log "$IMP → ${STATUS:-ok} (${KEY})" ;;
  404)     log "webhook not found or paused (404) — check HOOK and the card at tasqs.com/profile.php#webhooks" ;;
  401)     log "bad signature (401) — SECRET does not match the webhook" ;;
  429)     log "over the hourly limit (429); unRAID is probably looping" ;;
  *)       log "delivery failed ($CODE): ${BODY_OUT:0:160}" ;;
esac
exit 0
