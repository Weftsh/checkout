#!/usr/bin/env bash
# Check out a commit from a Weft mirror.
#
# Reads WEFT_INPUT_* (set by action.yml from the action's inputs) and the two
# GitHub facts it needs, and writes `source`, `commit` and `reason` to
# $GITHUB_OUTPUT. Everything that can go wrong on the mirror side ends in one
# place, `fall_back`, which either records the reason for the composite's
# actions/checkout step or fails the step with it.
#
# The token reaches git as an `http.extraHeader` through GIT_CONFIG_*
# variables: never in the URL (git would write it into .git/config) and never
# in a file. This is the same shape Weft's own runner uses.
set -euo pipefail

: "${WEFT_INPUT_REPOSITORY:=}"
: "${WEFT_INPUT_ORG:=}"
: "${WEFT_INPUT_TOKEN:=}"
: "${WEFT_INPUT_REF:=}"
: "${WEFT_INPUT_FETCH_DEPTH:=1}"
: "${WEFT_INPUT_PATH:=}"
: "${WEFT_INPUT_API_URL:=https://api.weft.sh}"
: "${WEFT_INPUT_FALLBACK:=true}"
: "${WEFT_INPUT_TIMEOUT:=10}"
: "${WEFT_GITHUB_REPOSITORY:=}"
: "${WEFT_GITHUB_SERVER_URL:=https://github.com}"
: "${GITHUB_WORKSPACE:=$PWD}"
: "${GITHUB_OUTPUT:=/dev/null}"

out() { printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }

# Every mirror-side failure lands here. With fallback on, the composite's next
# step runs actions/checkout and the reason is on the job's summary line; with
# it off, the reason is the failure.
fall_back() {
  local reason="$1"
  if [ "$WEFT_INPUT_FALLBACK" = "true" ]; then
    echo "::notice title=Weft Checkout::falling back to actions/checkout: $reason"
    out source fallback
    out commit ""
    out reason "$reason"
    exit 0
  fi
  echo "::error title=Weft Checkout::$reason"
  out source failed
  out commit ""
  out reason "$reason"
  exit 1
}

# --- resolve the mirror --------------------------------------------------

api="${WEFT_INPUT_API_URL%/}"
case "$api" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*) ;;
  *) fall_back "api-url must be https (got $api)" ;;
esac

repo="$WEFT_INPUT_REPOSITORY"
if [ -z "$repo" ]; then
  name="${WEFT_GITHUB_REPOSITORY##*/}"
  if [ -z "$WEFT_INPUT_ORG" ] || [ -z "$name" ]; then
    fall_back "no repository given: set 'repository: org/repo' or 'org: <weft org>'"
  fi
  repo="$WEFT_INPUT_ORG/$name"
fi
case "$repo" in
  */*/*|*/|/*|"") fall_back "repository must be 'org/repo' (got '$repo')" ;;
esac
org="${repo%%/*}"
name="${repo#*/}"

ref="$WEFT_INPUT_REF"
if [ -z "$ref" ]; then
  fall_back "no ref to check out"
fi
case "$ref" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fall_back "ref must be a commit id on this action (got '$ref'); branch names are resolved by the fallback" ;;
esac

case "$WEFT_INPUT_FETCH_DEPTH" in
  0|1) ;;
  *) fall_back "fetch-depth ${WEFT_INPUT_FETCH_DEPTH} is served by the fallback; the mirror serves 0 (full) or 1 (tip)" ;;
esac

dest="$GITHUB_WORKSPACE"
if [ -n "$WEFT_INPUT_PATH" ]; then
  case "$WEFT_INPUT_PATH" in
    /*|*..*) fall_back "path must be relative and inside the workspace" ;;
  esac
  dest="$GITHUB_WORKSPACE/$WEFT_INPUT_PATH"
fi

# --- probe: is the mirror there, and can this credential read it? ---------

auth=()
if [ -n "$WEFT_INPUT_TOKEN" ]; then
  auth=(-H "Authorization: Bearer $WEFT_INPUT_TOKEN")
fi
probe_url="$api/v1/orgs/$org/repos/$name"
status="$(curl -sS -o /tmp/weft-probe.json -w '%{http_code}' --max-time "$WEFT_INPUT_TIMEOUT" ${auth[@]+"${auth[@]}"} "$probe_url" 2>/tmp/weft-probe.err || true)"
case "$status" in
  200) ;;
  000) fall_back "the mirror at $api did not answer within ${WEFT_INPUT_TIMEOUT}s: $(tr -d '\n' </tmp/weft-probe.err)" ;;
  401) fall_back "$repo needs a token: pass 'token' with repo:read on the mirror" ;;
  404) fall_back "no mirror $repo on $api that this token can see" ;;
  *) fall_back "the mirror answered $status for $probe_url" ;;
esac

kind="$(sed -n 's/.*"kind":"\([a-z]*\)".*/\1/p' /tmp/weft-probe.json | head -n1)"
if [ -n "$kind" ] && [ "$kind" != "mirror" ]; then
  echo "::notice title=Weft Checkout::$repo is a $kind repository, not a mirror; checking out from it anyway"
fi

# --- fetch --------------------------------------------------------------

mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
  # Same rule as actions/checkout: the workspace is ours to replace.
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

export GIT_TERMINAL_PROMPT=0
if [ -n "$WEFT_INPUT_TOKEN" ]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.extraHeader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x:%s' "$WEFT_INPUT_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi

mirror_url="$api/$org/$name.git"
depth=()
if [ "$WEFT_INPUT_FETCH_DEPTH" = "1" ]; then
  depth=(--depth 1)
fi

git -C "$dest" init -q
git -C "$dest" remote add weft "$mirror_url"
# The origin remote is the forge, as actions/checkout leaves it, so a later
# `git push origin` goes where a developer's push goes. It carries no
# credential; the mirror is read-only and pushes need the forge's own.
git -C "$dest" remote add origin "$WEFT_GITHUB_SERVER_URL/$WEFT_GITHUB_REPOSITORY"

# git throws away the body of a refused upload-pack, and the body is where
# the mirror says why: a sync of the origin ran and did not surface the
# commit, the origin was unreachable, or the freshness budget was exceeded.
# Replay the fetch as one protocol-v2 request and read what came back.
explain() {
  local body
  body="$(printf '0012command=fetch\n0017object-format=sha1\n0001000eofs-delta\n'
          [ -z "${depth[*]:-}" ] || printf '000ddeepen 1\n'
          printf '0032want %s\n0009done\n0000' "$ref")"
  printf '%s' "$body" | curl -sS --max-time "$WEFT_INPUT_TIMEOUT" -X POST \
    -H "Content-Type: application/x-git-upload-pack-request" \
    -H "Git-Protocol: version=2" ${auth[@]+"${auth[@]}"} \
    --data-binary @- "$mirror_url/git-upload-pack" 2>/dev/null \
    | tr -d '\000' | tr '\r\n' '  ' \
    | sed -E 's/.*(ERR |error: )//; s/^[0-9a-f]{4}//; s/^(weft|stratum-mirror): //' \
    | head -c 600 || true
}

started=$(date +%s)
# One retry, a second later. A commit pushed moments ago can arrive
# while the mirror is still ingesting it; the first fetch is refused by
# name and the second is served. Two attempts cost a second and spare
# a fallback that clones the whole repository from github.com.
fetched=false
for attempt in 1 2; do
  if git -C "$dest" fetch -q ${depth[@]+"${depth[@]}"} weft "$ref" 2>/tmp/weft-fetch.err; then
    fetched=true
    break
  fi
  [ "$attempt" = 2 ] || sleep 1
done
if [ "$fetched" != true ]; then
  err="$(explain)"
  case "$err" in
    *PACK*|"") err="$(tr -d '\r' </tmp/weft-fetch.err | sed -n 's/^\(remote: \|fatal: \)\{0,1\}//p' | grep -v '^$' | tail -n 3 | tr '\n' ' ')" ;;
  esac
  # Do not leave a half-initialised repository for the fallback to trip on.
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fall_back "the mirror could not serve $ref: ${err:-git fetch failed}"
fi
elapsed=$(( $(date +%s) - started ))

git -C "$dest" checkout -q --detach FETCH_HEAD
have="$(git -C "$dest" rev-parse HEAD)"
if [ "$have" != "$ref" ]; then
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fall_back "the mirror served $have for $ref"
fi

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

echo "Checked out $have from $mirror_url in ${elapsed}s"
out source weft
out commit "$have"
out reason ""
