#!/usr/bin/env bash
# shellcheck disable=SC2016  # the check() strings are evaluated later, on purpose
# Exercise checkout.sh against a running Weft, end to end, with a mirror the
# script creates itself from a local origin.
#
#   WEFT_API=http://127.0.0.1:8080 WEFT_TOKEN=... WEFT_ORG=acme test/local.sh
#
# The token needs repo:write on the org (it creates two mirrors). Every case
# below is a behaviour the README promises, and each ends by asserting the
# script's outputs, not just its exit code.
set -euo pipefail

: "${WEFT_API:?}"
: "${WEFT_TOKEN:?}"
: "${WEFT_ORG:?}"

here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stamp="$(date +%s)"
pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

api() {
  curl -sS -H "Authorization: Bearer $WEFT_TOKEN" -H "Content-Type: application/json" "$@"
}

# --- an origin with history, and two mirrors of it -------------------------

origin="$work/origin.git"
src="$work/src"
git init -q -b main "$src"
git -C "$src" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
old="$(git -C "$src" rev-parse HEAD)"
git -C "$src" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m two
tip="$(git -C "$src" rev-parse HEAD)"
git clone -q --bare "$src" "$origin"

private="co-private-$stamp"
public="co-public-$stamp"
mk() {
  local code
  code="$(api -o /dev/null -w '%{http_code}' -X POST "$WEFT_API/v1/orgs/$WEFT_ORG/mirrors" \
    -d "{\"name\":\"$1\",\"provider\":\"generic\",\"origin\":\"file://$origin\",\"public\":$2}")"
  [ "$code" = 202 ] || { echo "creating mirror $1 answered $code"; exit 1; }
}
mk "$private" false
mk "$public" true

for r in "$private" "$public"; do
  for _ in $(seq 1 60); do
    if api "$WEFT_API/v1/orgs/$WEFT_ORG/repos/$r/sync-status" | grep -q "\"last_synced_commit\":\"$tip\""; then
      break
    fi
    sleep 0.5
  done
done
echo "mirrors $WEFT_ORG/$private and $WEFT_ORG/$public at $tip"

# --- run the script the way action.yml does --------------------------------

run() {
  # run <name> <expected exit> [VAR=value ...]
  local name="$1" want="$2"; shift 2
  local ws="$work/ws-$name" outf="$work/out-$name" logf="$work/log-$name"
  rm -rf "$ws"; mkdir -p "$ws"; : >"$outf"
  local rc=0
  env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_WORKSPACE="$ws" GITHUB_OUTPUT="$outf" \
    WEFT_INPUT_API_URL="$WEFT_API" WEFT_INPUT_TOKEN="$WEFT_TOKEN" \
    WEFT_INPUT_REPOSITORY="$WEFT_ORG/$private" WEFT_INPUT_REF="$tip" \
    WEFT_GITHUB_REPOSITORY="acme/widget" WEFT_INPUT_TIMEOUT=5 \
    "$@" bash "$here/checkout.sh" >"$logf" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    bad "$name: exit $rc, wanted $want"; sed 's/^/       /' "$logf"; return 1
  fi
  local why; why="$(sed -n 's/^reason=//p' "$outf")"
  [ -z "$why" ] || echo "       reason: $why"
  return 0
}
outv() { sed -n "s/^$2=//p" "$work/out-$1"; }
ws() { echo "$work/ws-$1"; }

echo "tip, depth 1"
run tip 0 && {
  check "source=weft" '[ "$(outv tip source)" = weft ]'
  check "commit=tip" '[ "$(outv tip commit)" = "$tip" ]'
  check "HEAD=tip" '[ "$(git -C "$(ws tip)" rev-parse HEAD)" = "$tip" ]'
  check "shallow" '[ -f "$(ws tip)/.git/shallow" ]'
  check "fsck" 'git -C "$(ws tip)" fsck --full --strict >/dev/null 2>&1'
  check "no credential in config" '! grep -rq Authorization "$(ws tip)/.git/config"'
  check "origin remote is the forge" '[ "$(git -C "$(ws tip)" remote get-url origin)" = "https://github.com/acme/widget" ]'
  check "weft remote is the mirror" '[ "$(git -C "$(ws tip)" remote get-url weft)" = "$WEFT_API/$WEFT_ORG/$private.git" ]'
}

echo "tip, depth 0"
run full 0 WEFT_INPUT_FETCH_DEPTH=0 && {
  check "source=weft" '[ "$(outv full source)" = weft ]'
  check "HEAD=tip" '[ "$(git -C "$(ws full)" rev-parse HEAD)" = "$tip" ]'
  check "not shallow" '[ ! -f "$(ws full)/.git/shallow" ]'
}

# A superseded commit is refused by the mirror today ("want beyond
# advertised tips not served yet" on a flat-refs layout; the freshness gate
# reports it as not found after syncing the origin). The action must take
# the fallback and carry the mirror's own sentence, never a stale tree.
echo "superseded commit, depth 0 → fallback with the mirror's sentence"
run old 0 WEFT_INPUT_REF="$old" WEFT_INPUT_FETCH_DEPTH=0 && {
  check "source=fallback" '[ "$(outv old source)" = fallback ]'
  check "reason is the mirror's" 'outv old reason | grep -q "commit not found on this mirror"'
  check "workspace left empty" '[ -z "$(ls -A "$(ws old)")" ]'
}

echo "superseded commit, depth 1 → fallback with the mirror's sentence"
run oldshallow 0 WEFT_INPUT_REF="$old" && {
  check "source=fallback" '[ "$(outv oldshallow source)" = fallback ]'
  check "reason is the mirror's" 'outv oldshallow reason | grep -q "commit not found on this mirror"'
  check "workspace left empty" '[ -z "$(ls -A "$(ws oldshallow)")" ]'
}

echo "commit nowhere upstream, fallback off → the mirror's sentence"
run bogus 1 WEFT_INPUT_REF=0000000000000000000000000000000000000001 WEFT_INPUT_FALLBACK=false && {
  check "source=failed" '[ "$(outv bogus source)" = failed ]'
  check "reason says a sync ran" 'outv bogus reason | grep -q "did not surface it"'
}

echo "commit pushed after the sync → fetched fresh through the freshness contract"
git -C "$src" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m three
git -C "$src" push -q "$origin" main
fresh="$(git -C "$src" rev-parse HEAD)"
run fresh 0 WEFT_INPUT_REF="$fresh" && {
  check "source=weft" '[ "$(outv fresh source)" = weft ]'
  check "HEAD=fresh" '[ "$(git -C "$(ws fresh)" rev-parse HEAD)" = "$fresh" ]'
}

echo "private mirror, no token → fallback, named"
run notoken 0 WEFT_INPUT_TOKEN= WEFT_INPUT_REF="$fresh" && {
  check "source=fallback" '[ "$(outv notoken source)" = fallback ]'
  check "reason" 'outv notoken reason | grep -q "needs a token"'
}

echo "public mirror, no token → served"
run public 0 WEFT_INPUT_TOKEN= WEFT_INPUT_REPOSITORY="$WEFT_ORG/$public" WEFT_INPUT_REF="$fresh" && {
  check "source=weft" '[ "$(outv public source)" = weft ]'
}

echo "repository derived from org + GitHub name"
run derived 0 WEFT_INPUT_REPOSITORY= WEFT_INPUT_ORG="$WEFT_ORG" WEFT_GITHUB_REPOSITORY="acme/$public" WEFT_INPUT_REF="$fresh" && {
  check "source=weft" '[ "$(outv derived source)" = weft ]'
}

echo "path input"
run path 0 WEFT_INPUT_PATH=sub/dir WEFT_INPUT_REF="$fresh" && {
  check "checked out under path" '[ "$(git -C "$(ws path)/sub/dir" rev-parse HEAD)" = "$fresh" ]'
}

echo "path traversal → fallback"
run traverse 0 WEFT_INPUT_PATH=../x && check "source=fallback" '[ "$(outv traverse source)" = fallback ]'

echo "unreachable api-url → fallback within the timeout"
run dead 0 WEFT_INPUT_API_URL=http://127.0.0.1:9 && {
  check "source=fallback" '[ "$(outv dead source)" = fallback ]'
  check "reason" 'outv dead reason | grep -q "did not answer"'
}

echo "fetch-depth 5 → fallback"
run depth5 0 WEFT_INPUT_FETCH_DEPTH=5 && check "source=fallback" '[ "$(outv depth5 source)" = fallback ]'

echo "branch name as ref → fallback"
run branch 0 WEFT_INPUT_REF=main && check "source=fallback" '[ "$(outv branch source)" = fallback ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
