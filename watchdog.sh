#!/usr/bin/env bash
# Uptime watchdog.
#
# Three checks, each against a public address:
#   Website  - the site answers HTTP 200
#   Database - the public health function answers "ok ..."
#   Login    - the sign-in service's health address answers (anything but a 5xx)
#
# If any check fails, all three are run again after RETRY_WAIT seconds.
# Only a check that fails BOTH times counts as down.
#
# Memory between runs is ONE open GitHub issue in this repository:
#   no open "DOWN" issue  = everything was up last time
#   an open "DOWN" issue  = an outage alert was already sent
# So there is one alert per outage and one recovery message, never a repeat.
#
# Log rule: print only OK / FAILED, the technical reason, and times.
# Never print a response body, a URL with a secret in it, or a secret.

set -uo pipefail
export LC_ALL=C

SITE_URL="${SITE_URL:?SITE_URL is not set}"
API_URL="${API_URL:?API_URL is not set}"
API_KEY="${API_KEY:?API_KEY is not set}"
RETRY_WAIT="${RETRY_WAIT:-60}"
TIMEOUT="${TIMEOUT:-20}"
HEARTBEAT_CRON="${HEARTBEAT_CRON:-30 3 * * 1}"
EVENT_SCHEDULE="${EVENT_SCHEDULE:-}"
TEST_BREAK="${TEST_BREAK:-none}"
DRY_RUN="${DRY_RUN:-false}"
REPO="${REPO:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

[ -z "$TEST_BREAK" ] && TEST_BREAK=none
[ -z "$DRY_RUN" ] && DRY_RUN=false

# A deliberately wrong address, used only when a test asks for one.
BROKEN_URL="https://127.0.0.1:9/"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- helpers

say() { printf '%s\n' "$*"; }
fail_loudly() {
  # A problem with the watchdog itself (not with the site): make the run red.
  say "::error::$*"
  exit 1
}

# "03 Nov 2026, 10:15 AM" in Indian Standard Time.
ist_time() { TZ=Asia/Kolkata date -d "@${1:-$(date +%s)}" '+%d %b %Y, %I:%M %p'; }

reason_for_curl() {
  case "$1" in
    6)  say "DNS lookup failed" ;;
    7)  say "connection refused" ;;
    28) say "timeout" ;;
    35) say "TLS handshake failed" ;;
    52) say "empty reply" ;;
    55|56) say "connection reset" ;;
    60) say "certificate problem" ;;
    *)  say "network error (curl $1)" ;;
  esac
}

reason_for_http() {
  case "$1" in
    500) say "HTTP 500, server error" ;;
    502) say "HTTP 502, bad gateway" ;;
    503) say "HTTP 503, service unavailable" ;;
    504) say "HTTP 504, gateway timeout" ;;
    520) say "HTTP 520, unknown error" ;;
    521) say "HTTP 521, server down" ;;
    522) say "HTTP 522, connection timed out" ;;
    523) say "HTTP 523, origin unreachable" ;;
    524) say "HTTP 524, timeout" ;;
    525) say "HTTP 525, secure connection failed" ;;
    526) say "HTTP 526, invalid certificate" ;;
    *)   say "HTTP $1" ;;
  esac
}

# probe <body-file> <curl args...>   -> sets PROBE_EXIT and PROBE_CODE
# curl's own error text is discarded on purpose: it can contain addresses.
probe() {
  local body="$1"; shift
  PROBE_CODE="$(curl -sS -o "$body" -w '%{http_code}' \
    --connect-timeout 10 --max-time "$TIMEOUT" "$@" 2>/dev/null)"
  PROBE_EXIT=$?
}

# ---------------------------------------------------------------- the checks
# Each sets its result to "OK" or "FAILED (<reason>)".

check_website() {
  local url="$SITE_URL"
  [ "$TEST_BREAK" = website ] && url="$BROKEN_URL"
  probe "$WORK/site" -L --max-redirs 5 "$url"
  if [ "$PROBE_EXIT" -ne 0 ]; then R_WEBSITE="FAILED ($(reason_for_curl "$PROBE_EXIT"))"
  elif [ "$PROBE_CODE" = 200 ]; then R_WEBSITE="OK"
  else R_WEBSITE="FAILED ($(reason_for_http "$PROBE_CODE"))"; fi
}

check_database() {
  local url="${API_URL}/rest/v1/rpc/health_ping"
  [ "$TEST_BREAK" = database ] && url="$BROKEN_URL"
  probe "$WORK/db" -X POST -H "apikey: ${API_KEY}" \
    -H 'Content-Type: application/json' --data '{}' "$url"
  if [ "$PROBE_EXIT" -ne 0 ]; then R_DATABASE="FAILED ($(reason_for_curl "$PROBE_EXIT"))"
  elif [ "$PROBE_CODE" != 200 ]; then R_DATABASE="FAILED ($(reason_for_http "$PROBE_CODE"))"
  elif jq -e 'type == "string" and startswith("ok")' "$WORK/db" >/dev/null 2>&1; then R_DATABASE="OK"
  else R_DATABASE="FAILED (unexpected answer)"; fi
}

check_login() {
  local url="${API_URL}/auth/v1/health"
  [ "$TEST_BREAK" = login ] && url="$BROKEN_URL"
  probe "$WORK/auth" -H "apikey: ${API_KEY}" "$url"
  if [ "$PROBE_EXIT" -ne 0 ]; then R_LOGIN="FAILED ($(reason_for_curl "$PROBE_EXIT"))"
  elif [ "$PROBE_CODE" -ge 500 ] 2>/dev/null || [ "$PROBE_CODE" = 000 ]; then
    R_LOGIN="FAILED ($(reason_for_http "$PROBE_CODE"))"
  else R_LOGIN="OK"; fi
}

run_checks() {
  check_website; check_database; check_login
  say "Attempt $1 at $(ist_time) IST: Website: ${R_WEBSITE} | Database: ${R_DATABASE} | Login: ${R_LOGIN}"
}

any_failed() { [ "$R_WEBSITE" != OK ] || [ "$R_DATABASE" != OK ] || [ "$R_LOGIN" != OK ]; }

# ---------------------------------------------------------------- Telegram

# tg <method> [curl data args...]  -> sets TG_CODE; the token never reaches
# the command line or the log (it is passed to curl on standard input).
tg() {
  local method="$1"; shift
  local attempt
  for attempt in 1 2 3; do
    probe "$WORK/tg" -K - "$@" <<EOF
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}"
EOF
    TG_EXIT=$PROBE_EXIT
    TG_CODE=$PROBE_CODE
    [ "$TG_EXIT" -eq 0 ] && [ "$TG_CODE" = 200 ] && return 0
    # 400/401/403: retrying will not help.
    case "$TG_CODE" in 400|401|403|404) return 1 ;; esac
    [ "$attempt" -lt 3 ] && sleep 10
  done
  return 1
}

tg_reason() {
  if [ "$TG_EXIT" -ne 0 ]; then reason_for_curl "$TG_EXIT"; return; fi
  case "$TG_CODE" in
    400) say "HTTP 400, chat id not accepted" ;;
    401) say "HTTP 401, bot token rejected" ;;
    403) say "HTTP 403, bot is not allowed in the chat" ;;
    404) say "HTTP 404, bot token rejected" ;;
    429) say "HTTP 429, too many messages" ;;
    *)   reason_for_http "$TG_CODE" ;;
  esac
}

send_telegram() {
  if tg sendMessage --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
       --data-urlencode "text=$1" --data-urlencode "disable_web_page_preview=true"; then
    # Telegram echoes the delivered message. Compare it with what was sent and
    # print only the result of the comparison and the message number - never
    # the reply itself (it also names the chat).
    local id same=no
    id="$(jq -r '.result.message_id // "?"' "$WORK/tg" 2>/dev/null)"
    [ "$(jq -r '.result.text // ""' "$WORK/tg" 2>/dev/null)" = "$1" ] && same=yes
    say "Telegram: message sent. Delivery confirmed by Telegram (message #${id}); delivered text matches what was sent: ${same}."
    say "Sent:"
    printf '%s\n' "$1" | sed 's/^/  | /'
    return 0
  fi
  fail_loudly "Telegram: FAILED ($(tg_reason)). The message was NOT delivered."
}

# ---------------------------------------------------------------- state (GitHub issue)

find_open_incident() {
  # Only issues opened by this workflow itself count. In a public repository
  # anyone can open an issue, so a look-alike from a stranger is ignored.
  local out
  out="$(gh api "repos/${REPO}/issues?state=open&per_page=100" \
    --jq '[.[] | select(.pull_request == null) | select(.user.login == "github-actions[bot]") | select(.title | startswith("DOWN since"))] | sort_by(.number) | .[0] | if . == null then "" else "\(.number) \(.body)" end' 2>/dev/null)" \
    || fail_loudly "GitHub: FAILED (could not read the outage record)"
  INCIDENT_NO="$(printf '%s' "$out" | head -n1 | awk '{print $1}')"
  INCIDENT_SINCE="$(printf '%s' "$out" | grep -o 'since=[0-9]*' | head -n1 | cut -d= -f2)"
}

open_incident() { # title body
  gh api "repos/${REPO}/issues" -f title="$1" -f body="$2" --jq '.number' >"$WORK/issue" 2>/dev/null \
    || fail_loudly "GitHub: FAILED (could not save the outage record; the next run may alert again)"
  say "Outage record #$(cat "$WORK/issue") opened."
}

close_incident() { # number comment
  gh api "repos/${REPO}/issues/$1/comments" -f body="$2" >/dev/null 2>&1 \
    && gh api -X PATCH "repos/${REPO}/issues/$1" -f state=closed -f state_reason=completed >/dev/null 2>&1 \
    || fail_loudly "GitHub: FAILED (could not close outage record #$1; the next run will send the recovery message again)"
  say "Outage record #$1 closed."
}

duration_text() { # seconds
  local mins=$(( ($1 + 30) / 60 ))
  [ "$mins" -lt 1 ] && mins=1
  if [ "$mins" -lt 60 ]; then
    [ "$mins" -eq 1 ] && say "about 1 minute" || say "about ${mins} minutes"
    return
  fi
  local h=$(( mins / 60 )) m=$(( mins % 60 )) hs="hours"
  [ "$h" -eq 1 ] && hs="hour"
  if [ "$m" -eq 0 ]; then say "about ${h} ${hs}"
  elif [ "$m" -eq 1 ]; then say "about ${h} ${hs} 1 minute"
  else say "about ${h} ${hs} ${m} minutes"; fi
}

# ---------------------------------------------------------------- main

if [ "${GITHUB_ACTIONS:-}" = true ]; then
  [ -n "$TELEGRAM_BOT_TOKEN" ] && say "::add-mask::${TELEGRAM_BOT_TOKEN}"
  [ -n "$TELEGRAM_CHAT_ID" ] && say "::add-mask::${TELEGRAM_CHAT_ID}"
fi

[ -n "$TELEGRAM_BOT_TOKEN" ] || fail_loudly "Secret TELEGRAM_BOT_TOKEN: MISSING"
[ -n "$TELEGRAM_CHAT_ID" ]   || fail_loudly "Secret TELEGRAM_CHAT_ID: MISSING"
say "Secrets TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID: present (values hidden)."

case "$TEST_BREAK" in
  none) ;;
  website|database|login) say "TEST RUN: the ${TEST_BREAK} check is pointed at a deliberately wrong address." ;;
  *) fail_loudly "Unknown test setting." ;;
esac

if [ "$DRY_RUN" = true ]; then
  say "DRY RUN: checking only. No message is sent and no outage record is changed."
  if tg getMe; then say "Telegram bot token: OK"; else fail_loudly "Telegram bot token: FAILED ($(tg_reason))"; fi
  if tg getChat --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"; then say "Telegram chat: OK"
  else fail_loudly "Telegram chat: FAILED ($(tg_reason))"; fi
  run_checks 1
  exit 0
fi

find_open_incident
if [ -n "$INCIDENT_NO" ]; then
  say "State: DOWN (outage record #${INCIDENT_NO}, alert already sent)."
else
  say "State: UP (no open outage record)."
fi

FIRST_TRY_AT="$(date +%s)"
run_checks 1
DOWN=false
if any_failed; then
  W1="$R_WEBSITE"; D1="$R_DATABASE"; L1="$R_LOGIN"
  say "A check failed. Waiting ${RETRY_WAIT} seconds, then checking again."
  sleep "$RETRY_WAIT"
  run_checks 2
  { [ "$W1" != OK ] && [ "$R_WEBSITE" != OK ]; } && DOWN=true
  { [ "$D1" != OK ] && [ "$R_DATABASE" != OK ]; } && DOWN=true
  { [ "$L1" != OK ] && [ "$R_LOGIN" != OK ]; } && DOWN=true
fi

NOW="$(date +%s)"

if [ "$DOWN" = true ]; then
  if [ -n "$INCIDENT_NO" ]; then
    say "Result: still DOWN. Alert was already sent; no repeat."
    exit 0
  fi
  say "Result: DOWN confirmed (failed twice, ${RETRY_WAIT} seconds apart)."
  MSG="🔴 CRM DOWN
Time: $(ist_time "$NOW")
Website: ${R_WEBSITE}
Database: ${R_DATABASE}
Login: ${R_LOGIN}
Checked twice, ${RETRY_WAIT} seconds apart."
  send_telegram "$MSG"
  open_incident "DOWN since $(ist_time "$FIRST_TRY_AT") IST" "Down confirmed: $(ist_time "$NOW") IST
Website: ${R_WEBSITE}
Database: ${R_DATABASE}
Login: ${R_LOGIN}
Checked twice, ${RETRY_WAIT} seconds apart.

<!-- since=${FIRST_TRY_AT} -->"
  exit 0
fi

if any_failed; then
  # Not down (no check failed twice), but not all passing on the last try either.
  if [ -n "$INCIDENT_NO" ]; then
    say "Result: not yet recovered (mixed results). No message; checking again next run."
    exit 0
  fi
  say "Result: UP (each failure passed on the other try)."
else
  say "Result: UP (all three checks passing)."
fi

if [ -n "$INCIDENT_NO" ]; then
  SINCE="${INCIDENT_SINCE:-$NOW}"
  DUR="$(duration_text $(( NOW - SINCE )))"
  MSG="🟢 CRM BACK UP
Time: $(ist_time "$NOW")
Down for ${DUR}.
All three checks passing."
  send_telegram "$MSG"
  close_incident "$INCIDENT_NO" "Back up: $(ist_time "$NOW") IST. Down for ${DUR}. All three checks passing."
fi

if [ "$EVENT_SCHEDULE" = "$HEARTBEAT_CRON" ]; then
  if any_failed; then
    say "Weekly heartbeat skipped: a check failed once this run."
  else
    send_telegram "✅ Watchdog alive. All checks passing."
  fi
  # Keep the schedule switched on: GitHub pauses schedules in public
  # repositories after 60 days without activity.
  gh api -X PUT "repos/${REPO}/actions/workflows/watchdog.yml/enable" >/dev/null 2>&1 \
    && say "Schedule keep-alive: OK" \
    || say "::warning::Schedule keep-alive: FAILED"
fi
exit 0
