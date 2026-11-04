#!/usr/bin/env bash
# Offline tests for watchdog.sh. Usage: tests/run_tests.sh <folder holding watchdog.sh>
# Offline tests for watchdog.sh: fake network, fake GitHub issues, fake clock. Nothing real is sent.
S="$(cd "$(dirname "$0")" && pwd)"; W="$1"
export PATH="$S/bin:$PATH" SITE_URL=https://crm.example/ API_URL=https://api.example API_KEY=k RETRY_WAIT=0 \
       TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c REPO=o/r GH_TOKEN=x
pass=0; fail=0
fresh() { export FAKE_DIR="$(mktemp -d)"; }
setnet() { echo "$2" > "$FAKE_DIR/$1"; }   # site|db|login  ok|down|522
run() { # hhmm test_break [schedule]
  : > "$FAKE_DIR/sent.new"; [ -f "$FAKE_DIR/sent" ] && cp "$FAKE_DIR/sent" "$FAKE_DIR/sent.before" || : > "$FAKE_DIR/sent.before"
  FAKE_HHMM="$1" TEST_BREAK="$2" EVENT_SCHEDULE="${3:-*/5}" DRY_RUN="${4:-false}" bash "$W/watchdog.sh" > "$FAKE_DIR/log" 2>&1; RC=$?
  [ -f "$FAKE_DIR/sent" ] || : > "$FAKE_DIR/sent"
  diff <(cat "$FAKE_DIR/sent.before") "$FAKE_DIR/sent" | sed -n 's/^> //p' > "$FAKE_DIR/sent.new"
  NMSG=$(grep -c '^=====MSG' "$FAKE_DIR/sent.new"); MSG="$(grep -v '^=====MSG' "$FAKE_DIR/sent.new")"
  OPEN=$(jq '[.[]|select(.state=="open")]|length' "$FAKE_DIR/issues.json" 2>/dev/null || echo 0)
  OPEN_TEST=$(jq '[.[]|select(.state=="open" and (.body|contains("test=1")))]|length' "$FAKE_DIR/issues.json" 2>/dev/null || echo 0)
}
ok() { if eval "$2"; then pass=$((pass+1)); echo "  PASS  $1"; else fail=$((fail+1)); echo "  FAIL  $1"; echo "        rc=$RC nmsg=$NMSG open=$OPEN open_test=$OPEN_TEST"; echo "$MSG" | sed 's/^/        | /'; tail -5 "$FAKE_DIR/log" | sed 's/^/        log: /'; fi; }
L='🧪 TEST — not a real outage'
first() { printf '%s\n' "$MSG" | head -1; }

echo "A · real outages, unchanged behaviour"
fresh; run 0900 none;                                   ok "all up: no message, no record" '[ $RC = 0 ] && [ $NMSG = 0 ] && [ $OPEN = 0 ]'
setnet db down; run 0905 none;                          ok "real outage: one 🔴, NOT labelled, real record" '[ $NMSG = 1 ] && [ "$(first)" = "🔴 CRM DOWN" ] && [ $OPEN = 1 ] && [ $OPEN_TEST = 0 ]'
run 0910 none;                                          ok "still down: no repeat" '[ $NMSG = 0 ] && [ $OPEN = 1 ]'
setnet db ok; run 0915 none;                            ok "recovery: one 🟢, NOT labelled, record closed" '[ $NMSG = 1 ] && [ "$(first)" = "🟢 CRM BACK UP" ] && [ $OPEN = 0 ]'
fresh; setnet site 522; run 0230 none;                  ok "real outage at night: still alerts, unlabelled" '[ $NMSG = 1 ] && [ "$(first)" = "🔴 CRM DOWN" ]'

echo "B · a drill: TEST label on both the 🔴 and the 🟢"
fresh; run 0900 database;                               ok "drill: one 🔴 whose first line is the TEST label" '[ $NMSG = 1 ] && [ "$(first)" = "$L" ] && printf "%s" "$MSG" | sed -n 2p | grep -qx "🔴 CRM DOWN"'
ok "drill: the broken check says so" 'printf "%s" "$MSG" | grep -q "Database: FAILED (connection refused) — broken on purpose for a test"'
ok "drill: the outage record is marked TEST" '[ $OPEN_TEST = 1 ] && jq -e "[.[]|select(.state==\"open\")][0].title|endswith(\"(TEST)\")" "$FAKE_DIR/issues.json" >/dev/null'
run 0905 database;                                      ok "drill again: no repeat" '[ $NMSG = 0 ] && [ $OPEN_TEST = 1 ]'
run 0910 none;                                          ok "next normal run: one 🟢 with the TEST label, record closed" '[ $NMSG = 1 ] && [ "$(first)" = "$L" ] && printf "%s" "$MSG" | sed -n 2p | grep -qx "🟢 CRM BACK UP" && [ $OPEN = 0 ]'

echo "C · a real outage starting during an open drill still alerts, unlabelled"
fresh; run 0900 database;                               ok "drill opened (labelled 🔴)" '[ $NMSG = 1 ] && [ "$(first)" = "$L" ] && [ $OPEN_TEST = 1 ]'
setnet login down; run 0905 none;                       ok "normal run sees a real failure: one 🔴, NOT labelled" '[ $NMSG = 1 ] && [ "$(first)" = "🔴 CRM DOWN" ] && ! printf "%s" "$MSG" | grep -q "TEST"'
ok "the test record is closed and a real record is open" '[ $OPEN = 1 ] && [ $OPEN_TEST = 0 ]'
run 0910 none;                                          ok "still down: no repeat" '[ $NMSG = 0 ] && [ $OPEN = 1 ]'
setnet login ok; run 0915 none;                         ok "recovery: one 🟢, NOT labelled" '[ $NMSG = 1 ] && [ "$(first)" = "🟢 CRM BACK UP" ] && [ $OPEN = 0 ]'
fresh; run 0900 database; setnet login down; run 0905 database
ok "a real failure found DURING a drill run: one 🔴, NOT labelled" '[ $NMSG = 1 ] && [ "$(first)" = "🔴 CRM DOWN" ] && [ $OPEN = 1 ] && [ $OPEN_TEST = 0 ]'
ok "  …and the deliberately broken check is marked as such in it" 'printf "%s" "$MSG" | grep -q "broken on purpose for a test"'
fresh; setnet login down; run 0900 database;            ok "drill while something is really down: one 🔴, NOT labelled, real record" '[ $NMSG = 1 ] && [ "$(first)" = "🔴 CRM DOWN" ] && [ $OPEN_TEST = 0 ] && [ $OPEN = 1 ]'
fresh; setnet db down; run 0900 none; run 0905 database; ok "real record open, drill run: no message, record stays real" '[ $NMSG = 0 ] && [ $OPEN = 1 ] && [ $OPEN_TEST = 0 ]'

echo "D · no test alerts at night"
fresh; run 2145 database;                               ok "drill asked at 21:45: runs as a normal check, nothing sent" '[ $NMSG = 0 ] && [ $OPEN = 0 ] && grep -q "TEST RUN refused" "$FAKE_DIR/log"'
fresh; run 0230 database;                               ok "drill asked at 02:30: nothing sent" '[ $NMSG = 0 ] && [ $OPEN = 0 ]'
fresh; run 0659 website;                                ok "drill asked at 06:59: nothing sent" '[ $NMSG = 0 ] && [ $OPEN = 0 ]'
fresh; run 2129 login;                                  ok "drill at 21:29: allowed, labelled" '[ $NMSG = 1 ] && [ "$(first)" = "$L" ]'
run 2205 none;                                          ok "its record still open at 22:05: closed quietly, no message" '[ $NMSG = 0 ] && [ $OPEN = 0 ]'
fresh; run 0700 website;                                ok "drill at 07:00: allowed, labelled" '[ $NMSG = 1 ] && [ "$(first)" = "$L" ]'
fresh; setnet db down; run 0230 database;               ok "night drill request while the database is really down: real 🔴, unlabelled" '[ $NMSG = 1 ] && [ "$(first)" = "🔴 CRM DOWN" ] && ! printf "%s" "$MSG" | grep -q "broken on purpose"'

echo "E · unchanged: dry run, weekly heartbeat"
fresh; run 0900 database '*/5' true;                    ok "dry run: nothing sent, no record" '[ $NMSG = 0 ] && [ $OPEN = 0 ]'
fresh; run 0900 none '30 3 * * 1';                      ok "Monday heartbeat: one ✅" '[ $NMSG = 1 ] && [ "$(first)" = "✅ Watchdog alive. All checks passing." ]'
echo "RESULT: $pass passed, $fail failed"
[ $fail = 0 ]
