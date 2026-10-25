#!/usr/bin/env zsh

emulate -L zsh
setopt pipe_fail
zmodload -F zsh/stat b:zstat

typeset -g _T_PASS=0 _T_FAIL=0
typeset -g ROOT="${0:A:h:h}"
typeset -g FIX="${ROOT}/test/fixtures"
typeset -g TMP
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kon-test.XXXXXX")"

typeset -ga _T_KILL=()

cleanup() {
  local p
  for p in "${_T_KILL[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

section() { print -r -- ""; print -r -- "== $1"; }
ok()      { print -r -- "  ok    $1"; _T_PASS=$(( _T_PASS + 1 )) }
bad()     { print -r -- "  FAIL  $1"; _T_FAIL=$(( _T_FAIL + 1 )) }

is() { # name actual expected
  if [[ "$2" == "$3" ]]; then ok "$1"
  else bad "$1"; print -r -- "        expected: [$3]"; print -r -- "        actual  : [$2]"; fi
}
isnt() { # name actual unexpected
  if [[ "$2" != "$3" ]]; then ok "$1"
  else bad "$1"; print -r -- "        should differ from: [$3]"; fi
}
contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"
  else bad "$1"; print -r -- "        [$2] does not contain [$3]"; fi
}
lacks() { # name haystack needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"
  else bad "$1"; print -r -- "        [$2] unexpectedly contains [$3]"; fi
}
succeeds() { # name cmd...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n (expected success)"; fi
}
fails() { # name cmd...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$n (expected failure)"; else ok "$n"; fi
}

typeset -g _T_SEQ=0 _T_OUT=""
bounded_fails() { # name cmd...
  local n="$1" i base="${TMP}/guard.$(( ++_T_SEQ ))" pid
  shift
  ( "$@" >| "$base" 2>&1; print -r -- $? >| "$base.rc" ) &
  pid=$!
  for i in {1..50}; do [[ -e "$base.rc" ]] && break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  _T_OUT="$(<"$base")"
  [[ -e "$base.rc" ]] || { bad "$n (did not exit)"; return }
  if [[ "$(<"$base.rc")" == 0 ]]; then bad "$n (expected failure)"; else ok "$n"; fi
}

listen_as() { # name-for-argv port extra-argv
  local name="$1" port="$2" extra="${3:-}"
  local script="${TMP}/${name}"
  if [[ ! -x "$script" ]]; then
    print -r -- "#!${KON_PYTHON}" >| "$script"
    cat >> "$script" <<'PY'
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
sys.stderr.write("listening\n")
sys.stderr.flush()
time.sleep(600)
PY
    chmod +x "$script"
  fi
  "$script" "$port" "$extra" >/dev/null 2>&1 &
  local pid=$!
  _T_KILL+=("$pid")
  local i
  for i in {1..50}; do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | grep -q . && break
    sleep 0.1
  done
  print -r -- "$pid"
}

: "${KON_PYTHON:=/usr/bin/python3}"
command -v "$KON_PYTHON" >/dev/null 2>&1 || KON_PYTHON="$(command -v python3)"
export KON_PYTHON
KON_CONFIG="${TMP}/no-such-config.zsh"   # never let a real user config leak in
KON_NO_PROMPT=1
source "${ROOT}/kon.zsh"

typeset -g PROD_EKS_BASE=$KON_PORT_BASE     PROD_EKS_SPAN=$KON_PORT_SPAN
typeset -g PROD_RDS_BASE=$KON_RDS_PORT_BASE PROD_RDS_SPAN=$KON_RDS_PORT_SPAN
typeset -g HARNESS_BASE=20500               HARNESS_SPAN=100

section "registry parsing (fixture kubeconfig, no cluster needed)"
typeset -a rows
rows=(${(f)"$(_kon_registry_from_json < "${FIX}/kubeconfig.json")"})

is "only EKS contexts are listed (docker-desktop dropped)" "${#rows}" "3"

typeset -a f
f=("${(@s:	:)rows[1]}")
is "row 1 has 8 fields"          "${#f}" "8"
is "  context"                   "${f[1]}" "demo-dev-main"
is "  region from ARN"           "${f[3]}" "eu-west-1"
is "  account from ARN"          "${f[4]}" "111111111111"
is "  cluster name from ARN"     "${f[5]}" "demo-dev-main"
is "  profile from exec env"     "${f[6]}" "demo-dev"
is "  port from loopback server" "${f[7]}" "18042"
is "  host from tls-server-name" "${f[8]}" "AAAA1111.gr7.eu-west-1.eks.amazonaws.com"
lacks "  and the row carries real tabs, not two characters" "${rows[1]}" '\t'

f=("${(@s:	:)rows[2]}")
is "row 2 missing profile becomes '-'"   "${f[6]}" "-"
is "row 2 port from non-loopback server" "${f[7]}" "8000"
is "row 2 host from server hostname"     "${f[8]}" "BBBB2222.gr7.us-east-1.eks.amazonaws.com"

f=("${(@s:	:)rows[3]}")
is "row 3 loopback + no SNI leaves host '-'" "${f[8]}" "-"
is "row 3 still has 8 fields"                "${#f}"   "8"

section "AWS config parsing"
rows=(${(f)"$(_kon_profiles "${FIX}/aws-config" demo)"})
is "profiles on the session are listed" "${#rows}" "3"
lacks "other session excluded"    "${rows[*]}" "other"
lacks "credential_process excluded" "${rows[*]}" "keyless"
f=("${(@s:	:)rows[1]}")
is "  profile name" "${f[1]}" "demo-dev"
is "  account id"   "${f[2]}" "111111111111"
is "  region"       "${f[3]}" "eu-west-1"
f=("${(@s:	:)rows[3]}")
is "missing region becomes '-'" "${f[3]}" "-"

section "SSO session discovery (never hardcoded)"
_kon_reset_sso() { _KON_SSO_SESSION=""; _KON_SSO_START_URL=""; }

KON_AWS_CONFIG="${FIX}/aws-config" KON_SSO_SESSION=""
_kon_reset_sso
succeeds "single [sso-session] is discovered" _kon_sso_discover
is "  session name" "$_KON_SSO_SESSION"   "demo"
is "  start url"    "$_KON_SSO_START_URL" "https://demo.awsapps.com/start"

KON_AWS_CONFIG="${FIX}/aws-config-multi"
_kon_reset_sso
fails "several sessions without KON_SSO_SESSION is an error" _kon_sso_discover

KON_SSO_SESSION="beta"
_kon_reset_sso
succeeds "KON_SSO_SESSION disambiguates" _kon_sso_discover
is "  picked session"   "$_KON_SSO_SESSION"   "beta"
is "  picked start url" "$_KON_SSO_START_URL" "https://beta.awsapps.com/start"

KON_SSO_SESSION="nope"
_kon_reset_sso
fails "unknown KON_SSO_SESSION is an error" _kon_sso_discover

KON_SSO_SESSION=""
KON_AWS_CONFIG="${FIX}/aws-config-nosso"
_kon_reset_sso
fails "no [sso-session] at all is an error" _kon_sso_discover

KON_AWS_CONFIG="${FIX}/aws-config" KON_SSO_SESSION=""
_kon_reset_sso

section "derived ports"
KON_PORT_BASE=18000 KON_PORT_SPAN=1000

is "hash is FNV-1a 32-bit (pinned vector)" "$(_kon_hash 'kon-test-vector')" "3807563554"
is "derived port (pinned vector)"          "$(_kon_desired_port 'kon-test-vector')" "18554"
is "derived port, dev fixture"             "$(_kon_desired_port '111111111111/demo-dev-main')" "18639"
is "derived port, prod fixture"            "$(_kon_desired_port '222222222222/demo-prod-main')" "18265"

is "same identity, same port (idempotent)" \
   "$(_kon_desired_port '111111111111/demo-dev-main')" \
   "$(_kon_desired_port '111111111111/demo-dev-main')"
isnt "different identity, different port" \
   "$(_kon_desired_port '111111111111/demo-dev-main')" \
   "$(_kon_desired_port '222222222222/demo-prod-main')"

typeset -i p
p=$(_kon_desired_port 'anything at all')
if (( p >= KON_PORT_BASE && p < KON_PORT_BASE + KON_PORT_SPAN )); then
  ok "derived port lands inside the configured range"
else
  bad "derived port $p outside ${KON_PORT_BASE}-$(( KON_PORT_BASE + KON_PORT_SPAN - 1 ))"
fi

is "KON_PORT_BASE is honoured" \
   "$(KON_PORT_BASE=30000 KON_PORT_SPAN=1000 _kon_desired_port 'kon-test-vector')" \
   "30554"

section "port fallback when the canonical slot is squatted"
KON_PORT_BASE=$HARNESS_BASE KON_PORT_SPAN=$HARNESS_SPAN
typeset -i want
want=$(_kon_desired_port 'squat-case')
typeset host="SQUAT.gr7.eu-west-1.eks.amazonaws.com"

is "clean slate resolves to the canonical port" \
   "$(_kon_resolve_port 'squat-case' "$host" '-' 2>/dev/null)" "$want"

typeset pid1 pid2
pid1=$(listen_as squatter-one   $(( want )))
pid2=$(listen_as squatter-two   $(( want + 1 )))
is "canonical and +1 squatted -> deterministic +2" \
   "$(_kon_resolve_port 'squat-case' "$host" '-' 2>/dev/null)" "$(( want + 2 ))"

kill "$pid1" "$pid2" 2>/dev/null
for i in {1..50}; do
  lsof -nP -iTCP:"$want" -sTCP:LISTEN -t 2>/dev/null | grep -q . || break
  sleep 0.1
done
is "squatters gone -> back to canonical" \
   "$(_kon_resolve_port 'squat-case' "$host" '-' 2>/dev/null)" "$want"

section "REGRESSION: a live tunnel must not be identified by argv coincidence"
typeset -i fport=$(( KON_PORT_BASE + 55 ))
typeset fhost="FAKE1234.gr7.eu-west-1.eks.amazonaws.com"

listen_as innocent-process "$fport" "$fhost" >/dev/null
fails "process merely mentioning the host is not a tunnel" \
      _kon_tunnel_live "$fport" "$fhost"
fails "  and the listener is not reported as SSM" \
      _kon_listener_is_ssm "$fport"

typeset -i sport=$(( KON_PORT_BASE + 56 )) kport=$(( KON_PORT_BASE + 57 ))
listen_as session-manager-plugin "$sport" "$fhost" >/dev/null
fails "a forged session-manager-plugin listener is not a tunnel" \
      _kon_tunnel_live "$sport" "$fhost"

typeset kbin="${TMP}/startbin" khome="${TMP}/tunnel-home"
mkdir -p "$kbin" "$khome"
cat > "${kbin}/aws" <<SH
#!/bin/sh
"${TMP}/session-manager-plugin" ${kport} "${fhost}" >/dev/null 2>&1 &
wait
SH
chmod +x "${kbin}/aws"

HOME="$khome" PATH="${kbin}:$PATH" _kon_start_tunnel eu-west-1 demo-dev i-0abc \
  "$fhost" 443 "$kport" 10 started >/dev/null 2>&1
out="$( HOME="$khome" _kon_tunnel_live "$kport" "$fhost" && echo up || echo down )"
is "a tunnel started by kon is live" "$out" "up"
HOME="$khome" _kon_kill_port "$kport" >/dev/null 2>&1
out="$( HOME="$khome" _kon_tunnel_live "$kport" "$fhost" && echo up || echo down )"
is "  stopping it reports down and drops the record" \
   "${out}/$( [[ -e "${khome}/.local/state/kon/tunnel.${kport}.pid" ]] && echo kept || echo gone )" \
   "down/gone"

section "SSO decision logic (stubbed aws, temp HOME, real cache untouched)"
typeset ssobin="${TMP}/ssobin"
typeset calllog="${TMP}/aws-calls"
mkdir -p "$ssobin"
cat > "${ssobin}/aws" <<SH
#!/bin/sh
echo "\$@" >> "${calllog}"
case "\$*" in
  *"sts get-caller-identity"*) [ -f "${TMP}/sts-fails" ] && exit 255 ; exit 0 ;;
  *"sso login"*)               exit 0 ;;
  *)                           exit 0 ;;
esac
SH
chmod +x "${ssobin}/aws"

mk_token() { # expires-offset-seconds  with-refresh-token
  local off="$1" refresh="$2"
  local cache="${TMP}/ssocache"
  rm -rf "$cache"; mkdir -p "$cache"
  "$KON_PYTHON" - "$cache" "$off" "$refresh" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone
cache, off, refresh = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "yes"
now = datetime.now(timezone.utc)
d = {
    "startUrl": "https://demo.awsapps.com/start",
    "region": "eu-west-1",
    "accessToken": "fake-access-token",
    "expiresAt": (now + timedelta(seconds=off)).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if refresh:
    d["refreshToken"] = "fake-refresh-token"
    d["registrationExpiresAt"] = (now + timedelta(days=80)).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(os.path.join(cache, "token.json"), "w") as fh:
    json.dump(d, fh)
PY
  KON_SSO_CACHE="$cache"
}

: >| "$calllog"
mk_token 3600 no
out="$(PATH="${ssobin}:$PATH" _kon_ensure_sso demo-dev 2>&1)"
contains "valid token reports remaining lifetime" "$out" "token good"
is "  no aws call at all" "$(wc -l < "$calllog" | tr -d ' ')" "0"

: >| "$calllog"
rm -f "${TMP}/sts-fails"
mk_token -60 yes
out="$(PATH="${ssobin}:$PATH" _kon_ensure_sso demo-dev 2>&1)"
contains "expired + refreshable renews silently" "$out" "renewed silently"
contains "  via a get-caller-identity probe" "$(cat "$calllog")" "sts get-caller-identity"
lacks "  and never opens a browser" "$(cat "$calllog")" "sso login"

: >| "$calllog"
mk_token -60 no
out="$(PATH="${ssobin}:$PATH" _kon_ensure_sso demo-dev 2>&1)"
contains "expired + no refresh token opens a browser" "$out" "opening browser"
contains "  by calling sso login" "$(cat "$calllog")" "sso login"

: >| "$calllog"
mk_token -60 yes
touch "${TMP}/sts-fails"
out="$(PATH="${ssobin}:$PATH" _kon_ensure_sso demo-dev 2>&1)"
contains "failed probe falls back to browser" "$out" "opening browser"
contains "  after trying the probe first" "$(cat "$calllog")" "sts get-caller-identity"
rm -f "${TMP}/sts-fails"

: >| "$calllog"
KON_SSO_CACHE="${TMP}/absent-cache"
out="$(PATH="${ssobin}:$PATH" _kon_ensure_sso demo-dev 2>&1)"
contains "empty cache reports no cached token" "$out" "no cached token"

section "installer: never relocates, never lands above compinit"
typeset INST="${ROOT}/scripts/install.zsh"
typeset idir="${TMP}/install"
mkdir -p "$idir"

typeset rc="${idir}/inplace.zshrc"
{
  print -r -- "autoload -Uz compinit && compinit"
  print -r -- "# >>> kon >>>"
  print -r -- "source /somewhere/old/init.zsh"
  print -r -- "# <<< kon <<<"
  print -r -- "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh"
  print -r -- "alias ll='ls -l'"
} >| "$rc"
out="$(zsh "$INST" --rc "$rc" 2>&1)"
contains "existing block is replaced in place" "$out" "replaced in place"
is "  and keeps its original line number" \
   "$(grep -n '>>> kon >>>' "$rc" | cut -d: -f1)" "2"
is "  so it still precedes the p10k line" \
   "$(( $(grep -n 'p10k.zsh' "$rc" | cut -d: -f1) > $(grep -n '>>> kon >>>' "$rc" | cut -d: -f1) ))" "1"
contains "  and now points at this repo" "$(cat "$rc")" "${ROOT}/init.zsh"

rc="${idir}/fresh.zshrc"
{
  print -r -- "source \$ZSH/oh-my-zsh.sh"
  print -r -- "autoload -Uz compinit && compinit"
  print -r -- "[ -f ~/.tunnel.zsh ] && source ~/.tunnel.zsh"
  print -r -- "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh"
} >| "$rc"
out="$(zsh "$INST" --rc "$rc" 2>&1)"
contains "fresh install anchors on the p10k line" "$out" "inserted before the p10k line"
contains "  and reports the legacy line it removed" "$out" "legacy lines : removed 1"
lacks "  legacy tunnel.zsh source is gone" "$(cat "$rc")" ".tunnel.zsh"
typeset -i lc lk lp
lc=$(grep -n "autoload -Uz compinit" "$rc" | cut -d: -f1)
lk=$(grep -n '>>> kon >>>' "$rc" | cut -d: -f1)
lp=$(grep -n 'p10k.zsh' "$rc" | cut -d: -f1)
is "  ordering is compinit < kon < p10k" "$(( lc < lk && lk < lp ))" "1"

typeset before="$(cat "$rc")"
out="$(zsh "$INST" --rc "$rc" 2>&1)"
contains "second run is a no-op" "$out" "already up to date"
is "  file is byte-identical" "$(cat "$rc")" "$before"
is "  and there is exactly one block" "$(grep -c '>>> kon >>>' "$rc")" "1"

rc="${idir}/broken.zshrc"
printf 'a=1\n# >>> kon >>>\nsource whatever\nb=2\n' >| "$rc"
before="$(cat "$rc")"
fails "unterminated block is refused" zsh "$INST" --rc "$rc"
is "  and the rc is left untouched" "$(cat "$rc")" "$before"

rc="${idir}/order.zshrc"
printf 'source ~/.p10k.zsh\nautoload -Uz compinit && compinit\nalias y=2\n' >| "$rc"
out="$(zsh "$INST" --rc "$rc" 2>&1)"
contains "p10k above compinit falls back to appending" "$out" "appended"
is "  block still lands after compinit" \
   "$(( $(grep -n '>>> kon >>>' "$rc" | cut -d: -f1) > $(grep -n "autoload -Uz compinit" "$rc" | cut -d: -f1) ))" "1"

rc="${idir}/dry.zshrc"
printf 'autoload -Uz compinit && compinit\n' >| "$rc"
before="$(cat "$rc")"
out="$(zsh "$INST" --dry-run --rc "$rc" 2>&1)"
contains "--dry-run announces itself" "$out" "dry run"
is "  and writes nothing" "$(cat "$rc")" "$before"
typeset -a leftovers
leftovers=("${idir}"/dry.zshrc.kon-install.*(N))
is "  leaving no temp file behind" "${#leftovers}" "0"

rc="${idir}/linked.zshrc"
printf 'autoload -Uz compinit && compinit\n' >| "$rc"
typeset ldir="${idir}/linked"
ln -s "$ROOT" "$ldir"
out="$(zsh "${ldir}/scripts/install.zsh" --rc "$rc" 2>&1)"
is "a symlinked install writes the invoked path, guarded and quoted" \
   "$(grep -F 'init.zsh' "$rc")" \
   "if [[ -r \"${ldir:a}/init.zsh\" ]]; then source \"${ldir:a}/init.zsh\"; fi"
lacks "  and never the resolved target" "$(cat "$rc")" "${ROOT}/init.zsh"

section "version reporting and release config"
typeset vfile="${ROOT}/VERSION"
is "VERSION file exists" "$( [[ -r "$vfile" ]] && print yes || print no )" "yes"
typeset ver="$(cat "$vfile")"
ver="${ver//[[:space:]]/}"
if [[ "$ver" == (<0-999>.<0-999>.<0-999>|<0-999>.<0-999>.<0-999>-*) ]]; then
  ok "VERSION is semver-shaped ($ver)"
else
  bad "VERSION is semver-shaped"; print -r -- "        got: [$ver]"
fi

out="$(kon --version 2>&1)"
contains "kon --version reports the VERSION file" "$out" "$ver"
contains "  and names the tool" "$out" "kon "
is "  -V is the same thing" "$(kon -V 2>&1)" "$out"
typeset desc="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null)"
if [[ -z "$desc" || "$desc" == "$ver" || "$desc" == "v$ver" ]]; then
  is "  no git annotation when HEAD is the released tag" "$out" "kon ${ver}"
else
  contains "  annotates a checkout ahead of the release" "$out" "(git: ${desc})"
fi

succeeds ".releaserc.json is valid JSON" "${KON_PYTHON:-/usr/bin/python3}" -c \
  "import json;json.load(open('${ROOT}/.releaserc.json'))"
succeeds "package.json is valid JSON" "${KON_PYTHON:-/usr/bin/python3}" -c \
  "import json;json.load(open('${ROOT}/package.json'))"
out="$("${KON_PYTHON:-/usr/bin/python3}" -c "
import json
c = json.load(open('${ROOT}/.releaserc.json'))
p = json.load(open('${ROOT}/package.json'))
names = [x if isinstance(x, str) else x[0] for x in c['plugins']]
print('private=%s npm=%s branches=%s' % (p.get('private'), '@semantic-release/npm' in names, ','.join(c['branches'])))
")"
contains "package.json is private" "$out" "private=True"
contains "no npm publish plugin is configured" "$out" "npm=False"
contains "releases only from main" "$out" "branches=main"
out="$("${KON_PYTHON:-/usr/bin/python3}" -c "
import json;print(json.load(open('${ROOT}/.releaserc.json')).get('repositoryUrl',''))")"
contains "repositoryUrl is a real https github.com URL" "$out" "https://github.com/"
lacks "  and not the local ssh alias" "$out" "github-perso"
lacks "VERSION is not tracked as a stale duplicate of package.json" \
  "$(${KON_PYTHON:-/usr/bin/python3} -c "import json;print(json.load(open('${ROOT}/package.json'))['version'])")" "$ver"

section "packaging: the tarball carries exactly what ships"
out="$(zsh "${ROOT}/scripts/package.zsh" 2>&1)"

typeset stage="${ROOT}/dist/kon-${ver}"
typeset -a want
want=(README.md VERSION init.zsh kon.zsh prompt.zsh scripts/install.zsh)
[[ -r "${ROOT}/LICENSE" ]] && want+=(LICENSE)
is "the staged tree is exactly those files, and no test/, .git or local config" \
   "$(cd "$stage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')" \
   "$(print -rl -- "${want[@]}" | LC_ALL=C sort | tr '\n' ' ')"

typeset unpack="${TMP}/unpack"
mkdir -p "$unpack"
tar -xzf "${ROOT}/dist/kon-${ver}.tar.gz" -C "$unpack"
is "the tarball unpacks to a single kon-<version>/ directory" \
   "$(ls "$unpack")" "kon-${ver}"

section "pre-push guard"
typeset HOOK="${ROOT}/.githooks/pre-push"
is "hook exists" "$( [[ -f "$HOOK" ]] && print yes || print no )" "yes"
is "hook is executable" "$( [[ -x "$HOOK" ]] && print yes || print no )" "yes"

typeset Z=0000000000000000000000000000000000000000

fails    "refuses a direct push to main"       zsh -c "print -r -- 'refs/heads/main abc123 refs/heads/main $Z' | '$HOOK' origin url"
succeeds "allows a feature branch"             zsh -c "print -r -- 'refs/heads/feat abc123 refs/heads/feat $Z' | '$HOOK' origin url"
succeeds "honours KON_ALLOW_MAIN_PUSH=1"       zsh -c "print -r -- 'refs/heads/main abc123 refs/heads/main $Z' | KON_ALLOW_MAIN_PUSH=1 '$HOOK' origin url"
fails    "refuses deleting main"               zsh -c "print -r -- 'refs/heads/main $Z refs/heads/main abc123' | '$HOOK' origin url"

out="$(print -r -- "refs/heads/main abc123 refs/heads/main $Z" | "$HOOK" origin url 2>&1)"
contains "  and explains the branch-and-PR route" "$out" "gh pr create"
contains "  and names the deliberate override" "$out" "KON_ALLOW_MAIN_PUSH=1"

typeset leakrepo="${TMP}/leak-repo" leakhome="${TMP}/leak-home" leaksha
acct="$(printf '%s%s' 210987654 321)"
mkdir -p "${leakrepo}/.githooks" "$leakhome"
cp "${ROOT}/.githooks/pre-push" "${ROOT}/.githooks/leak-patterns" "${leakrepo}/.githooks/"
git -C "$leakrepo" init -q --initial-branch=main
print -r -- "sso_account_id = ${acct}" >| "${leakrepo}/leak.txt"
git -C "$leakrepo" add -A
git -C "$leakrepo" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm "feat: add a config"
leaksha="$(git -C "$leakrepo" rev-parse HEAD)"

out="$(cd "$leakrepo" && HOME="$leakhome" KON_LEAK_PATTERNS="${TMP}/absent-patterns" \
        ./.githooks/pre-push origin url <<< "refs/heads/feat $leaksha refs/heads/feat $Z" 2>&1 )"; rc=$?
is "the committed patterns block a real-shaped value, as file:line and never the value" \
   "${rc}:$( [[ "$out" == *"leak.txt:1"* ]] && print file-line )$( [[ "$out" == *"$acct"* ]] && print echoed )" \
   "1:file-line"

mkdir -p "${TMP}/no-hook" "${TMP}/no-home"
cp "$HOOK" "${TMP}/no-hook/pre-push"
out="$(cd "${TMP}/no-hook" && HOME="${TMP}/no-home" KON_LEAK_PATTERNS="${TMP}/absent-patterns" \
        ./pre-push origin url <<< "refs/heads/feat abc123 refs/heads/feat $Z" 2>&1 )"; rc=$?
is "no readable pattern file refuses the push and names the file it wanted" \
   "${rc}:$( [[ "$out" == *leak-patterns* && "$out" == *absent-patterns* ]] && print named )" "1:named"

fails "the committed patterns spell no account id, host or home path of their own" \
      git -C "$ROOT" grep -nE '[0-9]{12}|[a-z0-9]+\.awsapps\.com|/(Users|home)/[A-Za-z]' -- .githooks/leak-patterns

section "self-update"
typeset udir="${TMP}/upd"
typeset -a GITQ
GITQ=(-c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false)
mkdir -p "${udir}/origin"
git -C "${udir}/origin" init -q --initial-branch=main
printf '1.0.0\n' >| "${udir}/origin/VERSION"
git -C "${udir}/origin" add -A
git -C "${udir}/origin" "${GITQ[@]}" commit -q -m "seed"
git clone -q "${udir}/origin" "${udir}/clone" 2>/dev/null

is "version is read from an arbitrary checkout" "$(_kon_version_of "${udir}/clone")" "1.0.0"

out="$(_kon_update "${udir}/clone" 2>&1)"
contains "no new commits reports up to date" "$out" "Already up to date (1.0.0)"
lacks "  and does not claim to have updated" "$out" "Updated :"

printf '1.1.0\n' >| "${udir}/origin/VERSION"
git -C "${udir}/origin" add -A
git -C "${udir}/origin" "${GITQ[@]}" commit -q -m "feat: something new"
out="$(_kon_update "${udir}/clone" 2>&1)"
contains "a fast-forward is reported with both versions" "$out" "1.0.0 -> 1.1.0"
contains "  and lists what arrived" "$out" "feat: something new"
contains "  and says the session must be reloaded" "$out" "exec zsh"
is "  and the checkout really moved" "$(_kon_version_of "${udir}/clone")" "1.1.0"

printf 'local edit\n' >> "${udir}/clone/VERSION"
out="$(_kon_update "${udir}/clone" 2>&1)"
contains "uncommitted changes are refused" "$out" "refusing to pull over them"
fails "  and it exits non-zero" _kon_update "${udir}/clone"
git -C "${udir}/clone" checkout -q -- VERSION

mkdir -p "${udir}/plain"
out="$(_kon_update "${udir}/plain" 2>&1)"
contains "a non-git directory is reported clearly" "$out" "not a git checkout"
fails "  and it exits non-zero" _kon_update "${udir}/plain"

mkdir -p "${udir}/foreign/sub"
git -C "${udir}/foreign" init -q --initial-branch=main
printf '9.9.9\n' >| "${udir}/foreign/sub/VERSION"
git -C "${udir}/foreign" add -A
git -C "${udir}/foreign" "${GITQ[@]}" commit -q -m "seed"
typeset saved_home="$_KON_HOME"
_KON_HOME="${udir}/foreign/sub"
is "a directory inside another work tree gets no git suffix" \
   "$(_kon_version 2>&1)" "kon 9.9.9"
_KON_HOME="$saved_home"

mkdir -p "${udir}/homebrew/opt/Cellar/kon/1.6.0/share/kon"
git -C "${udir}/homebrew" init -q --initial-branch=main
printf '9.9.9\n' >| "${udir}/homebrew/opt/Cellar/kon/1.6.0/share/kon/VERSION"
git -C "${udir}/homebrew" add -A
git -C "${udir}/homebrew" "${GITQ[@]}" commit -q -m "seed"
out="$(_kon_update "${udir}/homebrew/opt/Cellar/kon/1.6.0/share/kon" 2>&1)"
contains "a packaged path names its upgrade command" "$out" "brew upgrade kon"

section "port ranges: clusters, databases and the harness stay disjoint"
is "cluster range is 18000-18999" \
   "${PROD_EKS_BASE}-$(( PROD_EKS_BASE + PROD_EKS_SPAN - 1 ))" "18000-18999"
is "database range is 19000-19999" \
   "${PROD_RDS_BASE}-$(( PROD_RDS_BASE + PROD_RDS_SPAN - 1 ))" "19000-19999"

ranges_overlap() { # a_base a_span b_base b_span
  (( $1 < $3 + $4 && $3 < $1 + $2 ))
}
fails "cluster and database ranges do not overlap" \
      ranges_overlap $PROD_EKS_BASE $PROD_EKS_SPAN $PROD_RDS_BASE $PROD_RDS_SPAN
fails "harness range is outside the cluster range" \
      ranges_overlap $HARNESS_BASE $HARNESS_SPAN $PROD_EKS_BASE $PROD_EKS_SPAN
fails "harness range is outside the database range" \
      ranges_overlap $HARNESS_BASE $HARNESS_SPAN $PROD_RDS_BASE $PROD_RDS_SPAN

is "_kon_port_range defaults to the cluster range" \
   "$(KON_PORT_BASE=$PROD_EKS_BASE KON_PORT_SPAN=$PROD_EKS_SPAN _kon_port_range)" \
   "18000 1000"
is "_kon_port_range eks is explicit and identical" \
   "$(KON_PORT_BASE=$PROD_EKS_BASE KON_PORT_SPAN=$PROD_EKS_SPAN _kon_port_range eks)" \
   "18000 1000"
is "_kon_port_range rds selects the database range" \
   "$(_kon_port_range rds)" "19000 1000"

section "derived database ports"
typeset dbport
dbport="$(_kon_desired_port '111111111111/demo-dev-db' rds)"
is "a database port lands in the database range" \
   "$(( dbport >= PROD_RDS_BASE && dbport < PROD_RDS_BASE + PROD_RDS_SPAN ))" "1"
is "and it is stable across calls" \
   "$(_kon_desired_port '111111111111/demo-dev-db' rds)" "$dbport"
isnt "a different database gets a different port" \
   "$(_kon_desired_port '111111111111/demo-prod-db' rds)" "$dbport"
isnt "the same identity differs between kinds" \
   "$(KON_PORT_BASE=$PROD_EKS_BASE KON_PORT_SPAN=$PROD_EKS_SPAN _kon_desired_port 'x/y' eks)" \
   "$(_kon_desired_port 'x/y' rds)"

section "REGRESSION: a local database must never be mistaken for a tunnel"
typeset dbid="demo-dev-db"
typeset dbep="${dbid}.cluster-abc123.eu-west-1.rds.amazonaws.com"
typeset dbp=$(( HARNESS_BASE + 40 ))

typeset pgpid
pgpid=$(listen_as postgres "$dbp")
fails "a plain listener is not a database tunnel" \
      _kon_tunnel_live "$dbp" "$dbid" 'rds.amazonaws.com'
is "  and --status reports it down, not up" \
   "$(_kon_rds_state_label "$dbp" "$dbid")" "down"
kill "$pgpid" 2>/dev/null
for i in {1..50}; do
  lsof -nP -iTCP:"$dbp" -sTCP:LISTEN -t 2>/dev/null | grep -q . || break
  sleep 0.1
done

typeset smpid
smpid=$(listen_as session-manager-plugin "$dbp" "host=${dbep},portNumber=5432,localPortNumber=${dbp}")
fails "a forged forwarder is not this database's tunnel" \
      _kon_tunnel_live "$dbp" "$dbid" 'rds.amazonaws.com'
is "  and --status reports it down" \
   "$(_kon_rds_state_label "$dbp" "$dbid")" "down"
fails "a forwarder for another database does not match" \
      _kon_tunnel_live "$dbp" "other-db" 'rds.amazonaws.com'
fails "requiring rds.amazonaws.com rejects a non-database forward" \
      _kon_tunnel_live "$dbp" "$dbid" 'no-such-domain.example'
kill "$smpid" 2>/dev/null

section "database cache: picking and --status make no AWS call"
typeset cache="${TMP}/rds.tsv"
{
  print -r -- "# written by a test"
  print -r -- "# db_id	engine	account	region	profile	endpoint	port"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    demo-dev-db aurora-postgresql 111111111111 eu-west-1 demo-dev \
    "demo-dev-db.cluster-abc.eu-west-1.rds.amazonaws.com" 5432
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    demo-prod-db aurora-mysql 222222222222 eu-west-1 demo-prod \
    "demo-prod-db.cluster-def.eu-west-1.rds.amazonaws.com" 3306
} >| "$cache"

typeset -a crows
crows=(${(f)"$(KON_RDS_CACHE=$cache _kon_rds_cache_rows)"})
is "comments and blank lines are skipped" "${#crows}" "2"
is "the first field is the database id" \
   "$(print -r -- ${crows[1]} | cut -f1)" "demo-dev-db"

typeset awsdir="${TMP}/nonet"
mkdir -p "$awsdir"
print -r -- "#!/bin/sh" >| "${awsdir}/aws"
print -r -- "echo called >> ${TMP}/aws-was-called; exit 1" >> "${awsdir}/aws"
chmod +x "${awsdir}/aws"

out="$(PATH="${awsdir}:$PATH" KON_RDS_CACHE=$cache _kon_rds_status 2>&1)"
contains "--status lists the cached databases" "$out" "demo-dev-db"
contains "  and the other one"                 "$out" "demo-prod-db"
contains "  with the engine"                   "$out" "aurora-mysql"
contains "  and the derived port"              "$out" \
         "$(_kon_desired_port '111111111111/demo-dev-db' rds)"
is "no AWS call was made" "$( [[ -e "${TMP}/aws-was-called" ]] && echo yes || echo no )" "no"

out="$(KON_RDS_CACHE="${TMP}/absent.tsv" _kon_rds_status 2>&1)"
contains "an empty cache says how to fill it" "$out" "kon rds --discover"

section "jump host: identified by capability, never by name"
typeset jjson="${TMP}/instances.json"
cat > "$jjson" <<'JSON'
{"Reservations":[{"Instances":[
 {"InstanceId":"i-bastion","VpcId":"vpc-1","Tags":[
   {"Key":"Name","Value":"demo-dev-bastion"},
   {"Key":"ManagedBy","Value":"terraform"},
   {"Key":"Team","Value":"platform"}]},
 {"InstanceId":"i-node1","VpcId":"vpc-1","Tags":[
   {"Key":"Name","Value":"demo-dev-node"},
   {"Key":"eks:cluster-name","Value":"demo-dev-main"},
   {"Key":"kubernetes.io/cluster/demo-dev-main","Value":"owned"}]},
 {"InstanceId":"i-node2","VpcId":"vpc-1","Tags":[
   {"Key":"Name","Value":"other-node"},
   {"Key":"aws:eks:cluster-name","Value":"demo-dev-main"}]},
 {"InstanceId":"i-node3","VpcId":"vpc-1","Tags":[
   {"Key":"Name","Value":"self-managed"},
   {"Key":"kubernetes.io/cluster/some-other","Value":"shared"}]}
]}]}
JSON

typeset -a jrows
jrows=(${(f)"$(_kon_jump_candidates_from_json < "$jjson")"})
is "cluster nodes are excluded, whatever tag marks them" "${#jrows}" "1"
is "  the survivor is the bastion" "$(print -r -- ${jrows[1]} | cut -f1)" "i-bastion"
is "  its name is carried" "$(print -r -- ${jrows[1]} | cut -f2)" "demo-dev-bastion"
is "  and its VPC" "$(print -r -- ${jrows[1]} | cut -f3)" "vpc-1"

print -r -- '{"Reservations":[{"Instances":[{"InstanceId":"i-x","Tags":[]}]}]}' \
  >| "${TMP}/untagged.json"
is "an untagged instance still yields a row with placeholders" \
   "$(_kon_jump_candidates_from_json < "${TMP}/untagged.json")" "$(printf 'i-x\t-\t-')"

section "jump host: the name filter must never reach the AWS API"
typeset qlog="${TMP}/ec2-query-log"
typeset qbin="${TMP}/qbin"
mkdir -p "$qbin"
cat > "${qbin}/aws" <<SH
#!/bin/sh
echo "\$@" >> "${qlog}"
case "\$1 \$2" in
  "ssm describe-instance-information") echo "i-bastion" ;;
  "ec2 describe-instances") cat "${jjson}" ;;
  *) : ;;
esac
exit 0
SH
chmod +x "${qbin}/aws"

out="$(PATH="${qbin}:$PATH" _kon_jump_candidates eu-west-1 demo-dev)"
is "candidates come back through the local filter" "$(print -r -- "$out" | cut -f1)" "i-bastion"
lacks "no tag:Name filter was sent to EC2" "$(cat "$qlog")" "tag:Name"
contains "  only the state filter was" "$(cat "$qlog")" "instance-state-name"

section "jump host: ranking is case insensitive and may only narrow"
mixed() {
  printf 'i-a\tBASTION-01\tvpc-1\ni-b\tapp-server\tvpc-1\n'
}
is "an uppercase name matches a lowercase word" \
   "$(_kon_rank_candidates '' ${(f)"$(mixed)"} | cut -f1)" "i-a"

KON_JUMP_WORDS=(BaStIoN)
is "a mixed-case configured word matches too" \
   "$(_kon_rank_candidates '' ${(f)"$(mixed)"} | cut -f1)" "i-a"
KON_JUMP_WORDS=(bastion jump jumpbox jumphost)

ordered() {
  printf 'i-b\tfoo-bastion\tvpc-1\ni-j\tjump-01\tvpc-1\n'
}
is "an earlier word wins over a later one" \
   "$(_kon_rank_candidates '' ${(f)"$(ordered)"} | cut -f1)" "i-b"
KON_JUMP_WORDS=(jump bastion)
is "reordering the vocabulary changes the winner" \
   "$(_kon_rank_candidates '' ${(f)"$(ordered)"} | cut -f1)" "i-j"
KON_JUMP_WORDS=(bastion jump jumpbox jumphost)

nobastion() {
  printf 'i-j\tjump-01\tvpc-1\ni-r\trunner-01\tvpc-1\n'
}
is "a word that matches nothing is skipped, the next one resolves" \
   "$(_kon_rank_candidates '' ${(f)"$(nobastion)"} | cut -f1)" "i-j"

nowords() {
  printf 'i-1\talpha\tvpc-1\ni-2\tbeta\tvpc-1\n'
}
is "no word matching anything leaves every candidate" \
   "$(_kon_rank_candidates '' ${(f)"$(nowords)"} | wc -l | tr -d ' ')" "2"
is "  and the stem then decides" \
   "$(_kon_rank_candidates 'beta' ${(f)"$(nowords)"} | cut -f1)" "i-2"
is "a stem matching nothing changes nothing" \
   "$(_kon_rank_candidates 'zeta' ${(f)"$(nowords)"} | wc -l | tr -d ' ')" "2"

twobastions() {
  printf 'i-foo\tfoo-dev-bastion\tvpc-1\ni-bar\tbar-dev-bastion\tvpc-1\n'
}
is "two matches on the same word fall through to the stem" \
   "$(_kon_rank_candidates 'bar-dev' ${(f)"$(twobastions)"} | cut -f1)" "i-bar"
is "  and stay ambiguous without one" \
   "$(_kon_rank_candidates '' ${(f)"$(twobastions)"} | wc -l | tr -d ' ')" "2"

section "jump host: the remembered selector is a name, not an instance id"
typeset jcache="${TMP}/bastion.tsv"
KON_JUMP_CACHE="$jcache"

fails "an empty cache is a miss" _kon_jump_cache_get 111111111111 eu-west-1
succeeds "a choice can be stored" _kon_jump_cache_set 111111111111 eu-west-1 my-bastion
is "  and read back" "$(_kon_jump_cache_get 111111111111 eu-west-1)" "my-bastion"
fails "another region is a separate entry" _kon_jump_cache_get 111111111111 eu-north-1
fails "another account is a separate entry" _kon_jump_cache_get 222222222222 eu-west-1

_kon_jump_cache_set 111111111111 eu-west-1 replaced-bastion >/dev/null
is "storing again replaces rather than appends" \
   "$(_kon_jump_cache_get 111111111111 eu-west-1)" "replaced-bastion"
is "  leaving one row for that key" \
   "$(_kon_jump_cache_rows | grep -c '^111111111111')" "1"

_kon_jump_cache_set 222222222222 eu-west-1 other-bastion >/dev/null
_kon_jump_cache_forget 111111111111 >/dev/null
fails "forgetting one account drops it" _kon_jump_cache_get 111111111111 eu-west-1
is "  and leaves the other" "$(_kon_jump_cache_get 222222222222 eu-west-1)" "other-bastion"

typeset rbin="${TMP}/rbin"
mkdir -p "$rbin"
print -r -- "#!/bin/sh" >| "${rbin}/aws"
cat >> "${rbin}/aws" <<'SH'
case "$1 $2" in
  "ssm describe-instance-information") echo "i-brandnew" ;;
  "ec2 describe-instances")
    echo '{"Reservations":[{"Instances":[{"InstanceId":"i-brandnew","VpcId":"vpc-1","Tags":[{"Key":"Name","Value":"my-bastion"}]}]}]}' ;;
esac
exit 0
SH
chmod +x "${rbin}/aws"
_kon_jump_cache_set 333333333333 eu-west-1 my-bastion >/dev/null
is "a cached name resolves to whatever id now carries it" \
   "$(PATH="${rbin}:$PATH" _kon_jump_host 333333333333 eu-west-1 demo-dev '' label)" \
   "i-brandnew"

typeset gbin="${TMP}/gbin"
mkdir -p "$gbin"
print -r -- "#!/bin/sh" >| "${gbin}/aws"
cat >> "${gbin}/aws" <<'SH'
case "$1 $2" in
  "ssm describe-instance-information") echo "i-newbastion" ;;
  "ec2 describe-instances")
    echo '{"Reservations":[{"Instances":[{"InstanceId":"i-newbastion","VpcId":"vpc-1","Tags":[{"Key":"Name","Value":"fresh-bastion"}]}]}]}' ;;
esac
exit 0
SH
chmod +x "${gbin}/aws"
_kon_jump_cache_set 444444444444 eu-west-1 vanished-bastion >/dev/null
out="$(PATH="${gbin}:$PATH" _kon_jump_host 444444444444 eu-west-1 demo-dev '' label 2>&1)"
contains "a vanished host is reported" "$out" "is gone"
contains "  and the replacement is used" "$out" "i-newbastion"
is "  and remembered in its place" "$(_kon_jump_cache_get 444444444444 eu-west-1)" "fresh-bastion"

section "jump host: the VPC narrows candidates when it is known"
_kon_jump_candidates() {
  printf 'i-here\tbastion-a\tvpc-here\ni-there\tbastion-b\tvpc-there\n'
}
KON_JUMP_CACHE="${TMP}/vpc-bastion.tsv"
rm -f "$KON_JUMP_CACHE"

is "a known VPC picks the candidate inside it" \
   "$(_kon_jump_host 777777777777 eu-west-1 demo-dev '' label '' vpc-there)" "i-there"
is "  and the other VPC picks the other one" \
   "$(_kon_jump_host 888888888888 eu-west-1 demo-dev '' label '' vpc-here)" "i-here"
is "  the choice is remembered against that VPC" \
   "$(_kon_jump_cache_get 777777777777 eu-west-1 vpc-there)" "bastion-b"
fails "  and is not offered for a different VPC" \
      _kon_jump_cache_get 777777777777 eu-west-1 vpc-here

_kon_jump_cache_set 999999999999 eu-west-1 first-bastion vpc-1 >/dev/null
_kon_jump_cache_set 999999999999 eu-west-1 second-bastion vpc-2 >/dev/null
is "one account can hold a bastion per VPC" \
   "$(_kon_jump_cache_get 999999999999 eu-west-1 vpc-1)" "first-bastion"
is "  independently" "$(_kon_jump_cache_get 999999999999 eu-west-1 vpc-2)" "second-bastion"

_kon_jump_candidates() { printf 'i-only\tsolo-bastion\tvpc-here\n'; }
rm -f "$KON_JUMP_CACHE"
is "an unknown VPC does not exclude anything" \
   "$(_kon_jump_host 000000000000 eu-west-1 demo-dev '' label '' -)" "i-only"

_kon_jump_candidates() {
  printf 'i-a\tbastion-a\tvpc-nomatch\ni-b\tbastion-b\tvpc-alsonot\n'
}
rm -f "$KON_JUMP_CACHE"
out="$(_kon_jump_host 111111111111 eu-west-1 demo-dev '' label '' vpc-absent 2>&1)"
contains "a VPC matching no candidate leaves them all, so it stays ambiguous" \
         "$out" "i-a"

unfunction _kon_jump_candidates

section "jump host: a pre-VPC cache row is still readable"
KON_JUMP_CACHE="${TMP}/legacy-bastion.tsv"
{
  print -r -- "# written by kon"
  printf '%s\t%s\t%s\t%s\n' 222222222222 eu-west-1 legacy-bastion 2026-09-09
} >| "$KON_JUMP_CACHE"
is "a legacy row still resolves" \
   "$(_kon_jump_cache_get 222222222222 eu-west-1)" "legacy-bastion"
is "  and matches any VPC" \
   "$(_kon_jump_cache_get 222222222222 eu-west-1 vpc-anything)" "legacy-bastion"
is "  the split reports no VPC rather than guessing" \
   "$(_kon_jump_cache_split "$(printf '222222222222\teu-west-1\tlegacy-bastion\t2026-09-09')" | cut -f3)" \
   "-"
_kon_jump_cache_set 222222222222 eu-west-1 upgraded-bastion vpc-9 >/dev/null
is "  writing over it produces a VPC-keyed row" \
   "$(_kon_jump_cache_rows | grep 222222222222 | cut -f3)" "vpc-9"

KON_JUMP_CACHE="${TMP}/legacy-heal.tsv"
{
  print -r -- "# written by kon"
  printf '%s\t%s\t%s\t%s\n' 333333333333 eu-west-1 heal-me 2026-09-09
} >| "$KON_JUMP_CACHE"
typeset hbin="${TMP}/hbin"
mkdir -p "$hbin"
print -r -- "#!/bin/sh" >| "${hbin}/aws"
cat >> "${hbin}/aws" <<'SH'
case "$1 $2" in
  "ssm describe-instance-information") echo "i-heal" ;;
  "ec2 describe-instances")
    echo '{"Reservations":[{"Instances":[{"InstanceId":"i-heal","VpcId":"vpc-7","Tags":[{"Key":"Name","Value":"heal-me"}]}]}]}' ;;
esac
exit 0
SH
chmod +x "${hbin}/aws"
is "an agnostic row is still used when the VPC is known" \
   "$(PATH="${hbin}:$PATH" _kon_jump_host 333333333333 eu-west-1 demo-dev '' label '' vpc-7)" \
   "i-heal"
is "  and it upgrades itself to that VPC" \
   "$(_kon_jump_cache_vpc_of 333333333333 eu-west-1)" "vpc-7"

KON_JUMP_CACHE="${TMP}/bastion.tsv"

section "jump host: pins, and refusing to hang without a terminal"
typeset nbin="${TMP}/nbin"
mkdir -p "$nbin"
print -r -- "#!/bin/sh" >| "${nbin}/aws"
print -r -- "echo called >> ${TMP}/pin-aws-called; exit 1" >> "${nbin}/aws"
chmod +x "${nbin}/aws"
is "an explicit instance id is used verbatim" \
   "$(PATH="${nbin}:$PATH" _kon_jump_host 111111111111 eu-west-1 demo-dev i-0abc123 label)" \
   "i-0abc123"
is "  with no AWS call at all" \
   "$( [[ -e "${TMP}/pin-aws-called" ]] && echo yes || echo no )" "no"

_kon_jump_candidates() { printf 'i-1\talpha\tvpc-1\ni-2\tbeta\tvpc-1\n'; }
out="$(_kon_jump_host 555555555555 eu-west-1 demo-dev '' 'the cluster' 2>&1)"
fails "ambiguity without a terminal does not hang" \
      _kon_jump_host 555555555555 eu-west-1 demo-dev '' 'the cluster'
contains "  it lists the candidates" "$out" "i-1"
contains "  names the fix" "$out" "kon bastion"
contains "  and mentions --bastion" "$out" "--bastion"
fails "  nothing was remembered from a failed pick" \
      _kon_jump_cache_get 555555555555 eu-west-1

_kon_jump_candidates() { return 0; }
out="$(_kon_jump_host 666666666666 eu-west-1 demo-dev '' 'the cluster' 2>&1)"
contains "no candidate at all explains what was looked for" "$out" "SSM-managed"
contains "  and suggests a pin" "$out" "--bastion"

unfunction _kon_jump_candidates

section "bastion --status reads the four-column cache layout"
typeset bhome="${TMP}/bhome"
mkdir -p "${bhome}/.local/state/kon"
printf '%s\t%s\t%s\t%s\n' 111111111111 eu-west-1 vpc-1 bastion-prod \
  >| "${bhome}/.local/state/kon/bastion.tsv"
typeset -a blines bf
blines=(${(f)"$(HOME="$bhome" KON_NO_PROMPT=1 zsh -f -c "source '${ROOT}/kon.zsh'; _kon_bastion_status")"})
bf=(${=blines[1]})
is "the header names VPC before the host" "${(j: :)bf}" "ACCOUNT REGION VPC JUMP HOST"
bf=(${=blines[2]})
is "the row shows account, region, vpc then host" "${(j: :)bf}" \
   "111111111111 eu-west-1 vpc-1 bastion-prod"

section "cluster cache: discovery is read-only, registration is lazy"
typeset ekscache="${TMP}/eks.tsv"
{
  print -r -- "# written by a test"
  print -r -- "# cluster	account	region	profile"
  printf '%s\t%s\t%s\t%s\n' demo-dev-main  111111111111 eu-west-1 demo-dev
  printf '%s\t%s\t%s\t%s\n' demo-new-main  111111111111 eu-west-1 demo-dev
} >| "$ekscache"

typeset -a ecrows
ecrows=(${(f)"$(KON_EKS_CACHE=$ekscache _kon_eks_cache_rows)"})
is "comments and blank lines are skipped" "${#ecrows}" "2"

typeset kstub="${TMP}/kbin"
mkdir -p "$kstub"
cat > "${kstub}/kubectl" <<SH
#!/bin/sh
case "\$*" in
  "config view -o json") cat "\${KON_TEST_KUBECONFIG:-${FIX}/kubeconfig.json}" ;;
  "config current-context") echo "demo-dev-main" ;;
  *"get --raw"*) printf '%s\n' "\$KON_TEST_READYZ" >&2; exit 1 ;;
  *set-cluster*) exit 0 ;;
  *"clusters[0].name"*) echo "demo-dev-main" ;;
  *"clusters[0].cluster.server"*) echo "https://127.0.0.1:18042" ;;
  *) exit 1 ;;
esac
SH
cat > "${kstub}/aws" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "${kstub}/kubectl" "${kstub}/aws"

typeset -a ureg
ureg=(${(f)"$(PATH="${kstub}:$PATH" KON_EKS_CACHE=$ekscache _kon_registry)"})
is "registry unions kubeconfig with the cache" "${#ureg}" "4"
is "  an already-registered cluster is not duplicated" \
   "$(print -rl -- "${ureg[@]}" | cut -f5 | grep -c '^demo-dev-main$')" "1"

typeset newrow
newrow="$(print -rl -- "${ureg[@]}" | grep 'demo-new-main')"
is "  an unregistered cluster has no context" "$(print -r -- "$newrow" | cut -f1)" "-"
is "  its cluster key is a synthesised ARN" "$(print -r -- "$newrow" | cut -f2)" \
   "arn:aws:eks:eu-west-1:111111111111:cluster/demo-new-main"
is "  it carries no cached port" "$(print -r -- "$newrow" | cut -f7)" "-"
is "  and no endpoint yet"       "$(print -r -- "$newrow" | cut -f8)" "-"
is "  but it does know its profile" "$(print -r -- "$newrow" | cut -f6)" "demo-dev"

out="$(PATH="${kstub}:$PATH" KON_EKS_CACHE=$ekscache _kon_eks_status 2>&1)"
contains "--status shows the unregistered cluster" "$out" "demo-new-main"
contains "  marked with +"                          "$out" "+ "
contains "  and explains the marker"                "$out" "not in the kubeconfig yet"

typeset dlog="${TMP}/discover-aws-calls"
typeset dbin="${TMP}/dbin"
mkdir -p "$dbin"
cat > "${dbin}/aws" <<SH
#!/bin/sh
echo "\$@" >> "${dlog}"
case "\$1 \$2" in
  "eks list-clusters") echo "demo-dev-main	demo-new-main" ;;
  "sts get-caller-identity") echo 111111111111 ;;
  *) : ;;
esac
exit 0
SH
chmod +x "${dbin}/aws"

typeset written="${TMP}/eks-written.tsv"
_kon_profiles()   { printf 'demo-dev\t111111111111\teu-west-1\n'; }
_kon_ensure_sso() { return 0; }
out="$(PATH="${dbin}:$PATH" KON_EKS_CACHE=$written _kon_eks_discover 2>&1)"
contains "discover reports what it found" "$out" "demo-dev-main"
contains "  and says the kubeconfig was untouched" "$out" "Nothing was written to the kubeconfig"
is "  the cache file was written" "$( [[ -s "$written" ]] && echo yes || echo no )" "yes"
is "  with one row per cluster" \
   "$(KON_EKS_CACHE=$written _kon_eks_cache_rows | wc -l | tr -d ' ')" "2"
lacks "  and update-kubeconfig was NEVER called" "$(cat "$dlog")" "update-kubeconfig"

rm -f "$dlog"
is "_kon_eks_register returns the context name" \
   "$(KUBECONFIG="${TMP}/absent-kubeconfig" PATH="${dbin}:$PATH" _kon_eks_register eu-west-1 demo-dev demo-new-main)" "demo-new-main"
contains "  by calling update-kubeconfig for that one cluster" \
   "$(cat "$dlog")" "update-kubeconfig"
contains "  with an alias equal to the cluster name" "$(cat "$dlog")" "--alias demo-new-main"

section "prune: only ever removes arn:aws:eks entries, and asks first"
out="$(KON_EKS_CACHE="${TMP}/absent.tsv" _kon_eks_prune 2>&1)"
contains "refuses without a cache to compare against" "$out" "nothing is known to be stale"
KON_EKS_CACHE="${TMP}/absent.tsv" _kon_eks_prune >/dev/null 2>&1
is "  and exits non-zero" "$?" "1"

typeset onlyone="${TMP}/eks-one.tsv"
printf '%s\t%s\t%s\t%s\n' demo-dev-main 111111111111 eu-west-1 demo-dev >| "$onlyone"
out="$(PATH="${kstub}:$PATH" KON_EKS_CACHE=$onlyone _kon_eks_prune 2>&1 <<< "n")"
contains "lists a stale context" "$out" "not in the cluster cache any more"
contains "  and asks before removing" "$out" "[y/N]"
contains "  answering no changes nothing" "$out" "Left untouched"
lacks "  a non-EKS context is never a candidate" "$out" "rancher-desktop"

section "healthcheck: RBAC denial is a permission problem, not a broken cluster"
out="$(PATH="${kstub}:$PATH" KON_TEST_READYZ='Error from server (fOrBiDdEn): readyz is not allowed' _kon_healthcheck 2>&1)"; rc=$?
is "a Forbidden body exits 0" "$rc" "0"
contains "  and is reported as reachable" "$out" "reachable"
out="$(PATH="${kstub}:$PATH" KON_TEST_READYZ='error: dial tcp 127.0.0.1:8000: connection refused' _kon_healthcheck 2>&1)"; rc=$?
is "a real error still exits 1" "$rc" "1"

section "profile-scoped discovery merges into the cache instead of replacing it"
typeset mbin="${TMP}/mergebin"; mkdir -p "$mbin"
cat > "${mbin}/aws" <<'SH'
#!/bin/sh
case "$*" in
  *list-clusters*) echo "demo-dev-main demo-dev-new" ;;
  *describe-db-clusters*) printf 'db-dev-cluster\taurora-postgresql\tdb-dev-cluster.x.rds.amazonaws.com\t5432\n' ;;
esac
exit 0
SH
chmod +x "${mbin}/aws"

_kon_profiles() { printf 'demo-dev\t111111111111\teu-west-1\ndemo-prod\t222222222222\teu-west-1\n' }
_kon_ensure_sso() { return 0; }

typeset mcache="${TMP}/eks-merge.tsv"
typeset -a seed
seed=( "demo-dev-main 111111111111 eu-west-1 demo-dev"
       "demo-prod-main 222222222222 eu-west-1 demo-prod"
       "gone-main 222222222222 eu-west-1 demo-prod" )
for row in "${seed[@]}"; do printf '%s\t%s\t%s\t%s\n' ${=row}; done >| "$mcache"

PATH="${mbin}:$PATH" KON_EKS_CACHE=$mcache _kon_eks_discover demo-dev >/dev/null 2>&1
typeset -a mrows
mrows=(${(f)"$(KON_EKS_CACHE=$mcache _kon_eks_cache_rows)"})
is "the other profile's rows survive" \
   "$(print -rl -- "${mrows[@]}" | grep -c 'demo-prod')" "2"
is "  the scanned profile is replaced, not appended to" \
   "$(print -rl -- "${mrows[@]}" | cut -f1 | grep -c '^demo-dev')" "2"

typeset before_mcache="$(cksum < "$mcache")"
PATH="${mbin}:$PATH" KON_EKS_CACHE=$mcache _kon_eks_discover nope >/dev/null 2>&1; rc=$?
is "an unknown profile is refused, leaving the cache untouched" \
   "$rc $(cksum < "$mcache")" "1 ${before_mcache}"

typeset rmcache="${TMP}/rds-merge.tsv"
typeset -a rseed
rseed=( "db-dev-old aurora-postgresql 111111111111 eu-west-1 demo-dev db-dev-old.x.rds.amazonaws.com 5432 vpc-1"
        "db-prod-keep aurora-postgresql 222222222222 eu-west-1 demo-prod db-prod-keep.x.rds.amazonaws.com 5432 vpc-2"
        "db-prod-gone aurora-postgresql 222222222222 eu-west-1 demo-prod db-prod-gone.x.rds.amazonaws.com 5432 vpc-2" )
for row in "${rseed[@]}"; do printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' ${=row}; done >| "$rmcache"

PATH="${mbin}:$PATH" KON_RDS_CACHE=$rmcache _kon_rds_discover demo-dev >/dev/null 2>&1
typeset -a rrows
rrows=(${(f)"$(KON_RDS_CACHE=$rmcache _kon_rds_cache_rows)"})
is "the other profile's rows survive a database discover" \
   "$(print -rl -- "${rrows[@]}" | grep -c 'demo-prod')" "2"
is "  and the scanned profile holds only the fresh rows" \
   "$(print -rl -- "${rrows[@]}" | cut -f1 | grep '^db-dev' | sort | tr '\n' ' ')" \
   "db-dev-cluster "

section "--stop -p only stops that profile's tunnels"
typeset -i spa=$(( HARNESS_BASE + 60 )) spb=$(( HARNESS_BASE + 61 ))
sed -e "s/18042/${spa}/" -e "s/18077/${spb}/" "${FIX}/kubeconfig.json" >| "${TMP}/two-profile.json"
typeset spapid spbpid stop_home="${TMP}/stop-home"
spapid=$(listen_as session-manager-plugin "$spa" AAAA1111.gr7.eu-west-1.eks.amazonaws.com)
spbpid=$(listen_as session-manager-plugin "$spb" BBBB2222.gr7.us-east-1.eks.amazonaws.com)
mkdir -p "${stop_home}/.local/state/kon"
print -r -- "$spapid" >| "${TMP}/tunnel.${spa}.pid"
print -r -- "$spbpid" >| "${TMP}/tunnel.${spb}.pid"

HOME="$stop_home" PATH="${kstub}:$PATH" KON_TEST_KUBECONFIG="${TMP}/two-profile.json" KON_EKS_CACHE="${TMP}/no-eks-cache.tsv" \
  kon eks --stop -p demo-dev >/dev/null 2>&1
fails "kon eks --stop -p stops only that profile's listener" _kon_port_busy "$spa"
succeeds "  and leaves the other profile's listener up" _kon_port_busy "$spb"

section "python3 is resolved from PATH instead of a hardcoded path"
typeset pbin="${TMP}/pystub"; mkdir -p "$pbin"
printf '#!/bin/sh\nexit 0\n' >| "${pbin}/python3"
chmod +x "${pbin}/python3"

out="$(env -u KON_PYTHON PATH="${pbin}:$PATH" KON_CONFIG="${TMP}/no-such-config.zsh" \
       zsh -f -c "source '${ROOT}/kon.zsh'; print -r -- \$KON_PYTHON")"
is "a python3 earlier in PATH is picked up" "$out" "${pbin}/python3"

typeset emptybin="${TMP}/emptybin"
mkdir -p "$emptybin"
out="$(zsh -f -c "unset KON_PYTHON; PATH='${emptybin}'; KON_CONFIG='${TMP}/no-such-config.zsh'; \
                  source '${ROOT}/kon.zsh'; _kon_sso_discover" 2>&1)"; rc=$?
is "a PATH without python3 fails the first use" "$rc" "1"
contains "  naming python3" "$out" "python3"
lacks "  without a shell traceback" "$out" "command not found"

section "doctor: the report a bug report needs, without an AWS call"
typeset docbin="${TMP}/doctor-bin" zbin dcmd dpath
mkdir -p "$docbin"
zbin="$(whence -p zsh)"
for dcmd in aws kubectl lsof python3; do
  dpath="$(whence -p $dcmd)" && ln -sf "$dpath" "${docbin}/${dcmd}"
done

typeset dout drc
dout="$(env PATH="${docbin}" HOME="${TMP}/doctor-home" KON_CONFIG="${TMP}/no-such-config.zsh" \
        KON_AWS_CONFIG="${FIX}/aws-config" "$zbin" -f -c "source '${ROOT}/kon.zsh'; kon doctor" 2>&1)"; drc=$?
is "a missing session-manager-plugin is named and fails the check" \
   "${drc}:$( [[ "$dout" == *"session-manager-plugin not on PATH"* ]] && print found )" "1:found"

dout="$(env PATH="${docbin}" HOME="${TMP}/doctor-home" KON_CONFIG="${TMP}/no-such-config.zsh" \
        KON_AWS_CONFIG="${FIX}/aws-config" "$zbin" -f -c \
        "unsetopt prompt_subst; source '${ROOT}/kon.zsh'; kon doctor" 2>&1)"
contains "prompt_subst unset is reported" "$dout" "prompt_subst off"

dout="$(env -u KON_PYTHON PATH="${emptybin}" HOME="${TMP}/doctor-home" KON_CONFIG="${TMP}/no-such-config.zsh" \
        KON_AWS_CONFIG="${FIX}/aws-config" "$zbin" -f -c "source '${ROOT}/kon.zsh'; kon doctor" 2>&1)"
is "an empty PATH gets the missing list and an install command, not a shell error" \
   "$(print -r -- "$dout" | grep -c 'command not found'):$( [[ "$dout" == *"!! missing: awscli v2, session-manager-plugin, kubectl, python3, lsof"* && "$dout" == *"install with:"* ]] && print actionable )" \
   "0:actionable"

: >| "$calllog"
dout="$(env PATH="${ssobin}:$PATH" HOME="${TMP}/doctor-home" KON_CONFIG="${TMP}/no-such-config.zsh" \
        KON_AWS_CONFIG="${FIX}/aws-config" "$zbin" -f -c "source '${ROOT}/kon.zsh'; kon doctor" 2>&1)"
is "doctor asks aws only for its version, never the API" \
   "$(cat "$calllog")" "--version"

section "tunnel readiness is probed with zsh/net/tcp, not netcat"
typeset -i rport=$(( HARNESS_BASE + 70 )) cport=$(( HARNESS_BASE + 71 )) nport=$(( HARNESS_BASE + 72 ))
listen_as innocent-process "$rport" >/dev/null
succeeds "the probe accepts a real listener" _kon_port_ready "$rport"
fails "  and rejects a port where nothing listens" _kon_port_ready "$cport"

typeset nclog="${TMP}/nc-called" tbin="${TMP}/tunnelbin"
mkdir -p "$tbin"
printf '#!/bin/sh\ntouch %s\nexit 1\n' "${nclog}" >| "${tbin}/nc"
printf '#!/bin/sh\nexit 0\n' >| "${tbin}/aws"
chmod +x "${tbin}/nc" "${tbin}/aws"

listen_as innocent-process "$nport" >/dev/null
HOME="${TMP}/probe-home" PATH="${tbin}:$PATH" _kon_start_tunnel eu-west-1 demo-dev i-0abc PROBE.gr7.eu-west-1.eks.amazonaws.com 443 "$nport" 5 t4 >/dev/null 2>&1; rc=$?
is "the connect path succeeds with netcat stubbed to fail" "$rc" "0"
is "  and never shells out to netcat" "$( [[ -e "$nclog" ]] && echo yes || echo no )" "no"

section "REGRESSION: tunnel logs stay out of /tmp"
typeset -i lgport=$(( HARNESS_BASE + 75 ))
typeset lhome="${TMP}/log-home" ltag="klog.$$.${RANDOM}"
mkdir -p "$lhome"
listen_as innocent-process "$lgport" >/dev/null
HOME="$lhome" KON_EKS_CACHE="${lhome}/.local/state/kon/eks.tsv" PATH="${tbin}:$PATH" \
  _kon_start_tunnel eu-west-1 demo-dev i-0abc PROBE.gr7.eu-west-1.eks.amazonaws.com 443 "$lgport" 5 "$ltag" >/dev/null 2>&1
typeset lgdir="${lhome}/.local/state/kon/logs"
typeset lgfile="${lgdir}/${ltag}-tunnel.${lgport}.log"
is "the log lands in the user's state directory" \
   "$( [[ -f "$lgfile" ]] && echo yes || echo no )" "yes"
is "  in a 700 directory with a 600 file" \
   "$(printf '%o %o' $(( $(zstat +mode "$lgdir") & 511 )) $(( $(zstat +mode "$lgfile") & 511 )))" \
   "700 600"
is "  and nothing named after the tunnel under /tmp" \
   "$( [[ -e "/tmp/${ltag}-tunnel.${lgport}.log" ]] && echo yes || echo no )" "no"

section "the kubeconfig is backed up once before the first write"
typeset bhome="${TMP}/backup-home"; mkdir -p "${bhome}/.kube"
print -r -- "apiVersion: v1" >| "${bhome}/.kube/config"
chmod 600 "${bhome}/.kube/config"

HOME="$bhome" KUBECONFIG= PATH="${kstub}:$PATH" zsh -f -c \
  "source '${ROOT}/kon.zsh'; _kon_eks_register eu-west-1 demo-dev demo-a-main; _kon_set_cluster_endpoint 18042 demo-a.gr7.example" >/dev/null 2>&1
typeset -a baks
baks=( "${bhome}/.kube/config.bak."*(N) )
is "exactly one backup is taken for the whole run" "${#baks}" "1"
typeset -i bmode="$(zstat +mode "${baks[1]}")"
is "  with the original mode preserved" "$(printf '%o' $(( bmode & 511 )))" "600"

rm -f "${bhome}/.kube/config.bak."*(N)
HOME="$bhome" KUBECONFIG= PATH="${kstub}:$PATH" KON_EKS_CACHE="${TMP}/no-eks.tsv" _kon_eks_status >/dev/null 2>&1
baks=( "${bhome}/.kube/config.bak."*(N) )
is "a read-only command takes no backup" "${#baks}" "0"

section "noun dispatch: eks is implicit, so nothing pre-noun changed meaning"
_kon_eks_status()   { print -r -- "EKS-STATUS[$1]" }
_kon_rds_status()   { print -r -- "RDS-STATUS[$1]" }
_kon_eks_stop()     { print -r -- "EKS-STOP[$1|$2]" }
_kon_rds_stop()     { print -r -- "RDS-STOP[$1|$2]" }
_kon_eks_discover() { print -r -- "EKS-DISCOVER[$1]" }
_kon_rds_discover() { print -r -- "RDS-DISCOVER[$1]" }
_kon_eks_connect()  { print -r -- "EKS-CONNECT[$1|$2|$3|$4]" }
_kon_rds_connect()  { print -r -- "RDS-CONNECT[$1|$2|$3|$4|$5]" }

is "kon --status shows both, clusters first" \
   "$(kon --status)" $'EKS-STATUS[]\n\nRDS-STATUS[]'
is "kon eks --status narrows to clusters"   "$(kon eks --status)" "EKS-STATUS[]"
is "kon rds --status narrows to databases"  "$(kon rds --status)" "RDS-STATUS[]"
is "kon rds --status -p scopes to an account" \
   "$(kon rds --status -p demo-dev)" "RDS-STATUS[demo-dev]"
is "kon eks --status -p scopes to an account" \
   "$(kon eks --status -p demo-dev)" "EKS-STATUS[demo-dev]"
is "kon --status -p scopes both sides" \
   "$(kon --status -p demo-dev)" $'EKS-STATUS[demo-dev]\n\nRDS-STATUS[demo-dev]'

is "kon CLUSTER still connects to a cluster" \
   "$(kon demo-dev-main)" "EKS-CONNECT[demo-dev-main|180||]"
is "kon eks CLUSTER is the same thing said explicitly" \
   "$(kon eks demo-dev-main)" "EKS-CONNECT[demo-dev-main|180||]"
is "kon rds NAME connects to a database" \
   "$(kon rds demo-dev-db)" "RDS-CONNECT[demo-dev-db|180|||]"
is "kon eks alone opens the cluster picker" "$(kon eks)" "EKS-CONNECT[|180||]"
is "kon rds alone opens the database picker" "$(kon rds)" "RDS-CONNECT[|180|||]"
is "kon alone still opens the cluster picker" "$(kon)" "EKS-CONNECT[|180||]"
is "kon rds -p scopes the picker to one account" \
   "$(kon rds -p demo-dev)" "RDS-CONNECT[|180|||demo-dev]"

is "kon --stop stops both kinds"      "$(kon --stop)" $'EKS-STOP[|]\nRDS-STOP[|]'
is "kon rds --stop NAME is scoped"    "$(kon rds --stop demo-dev-db)" "RDS-STOP[demo-dev-db|]"
is "kon eks --stop -p scopes to an account" \
   "$(kon eks --stop -p demo-dev)" "EKS-STOP[|demo-dev]"
is "kon --stop -p scopes both kinds" \
   "$(kon --stop -p demo-dev)" $'EKS-STOP[|demo-dev]\nRDS-STOP[|demo-dev]'
is "kon --discover still means clusters" "$(kon --discover)" "EKS-DISCOVER[]"
is "kon rds --discover takes a profile"  "$(kon rds --discover demo-dev)" "RDS-DISCOVER[demo-dev]"
is "kon rds --discover -p is equivalent" "$(kon rds --discover -p demo-dev)" "RDS-DISCOVER[demo-dev]"

is "--bastion and --timeout reach the cluster path" \
   "$(kon -b i-0abc -t 42 demo-dev-main)" "EKS-CONNECT[demo-dev-main|42||i-0abc]"
is "--local-port and --bastion reach the database path" \
   "$(kon rds -l 15432 -b i-0abc demo-dev-db)" "RDS-CONNECT[demo-dev-db|180|15432|i-0abc|]"

_kon_bastion_status()  { print -r -- "BASTION-STATUS" }
_kon_bastion_choose()  { print -r -- "BASTION-CHOOSE[$1]" }
_kon_jump_cache_forget() { print -r -- "BASTION-FORGET[$1]" }

is "kon bastion picks for the current account" "$(kon bastion)" "BASTION-CHOOSE[]"
is "kon bastion PROFILE picks for that one"    "$(kon bastion demo-dev)" "BASTION-CHOOSE[demo-dev]"
is "kon bastion --status is its own view"      "$(kon bastion --status)" "BASTION-STATUS"
is "kon bastion --forget clears one"           "$(kon bastion --forget 111111111111)" \
   "BASTION-FORGET[111111111111]"
is "kon bastion --forget with no argument clears all" "$(kon bastion --forget)" "BASTION-FORGET[]"
is "bastion is a reserved noun, not a cluster name" "$(kon bastion)" "BASTION-CHOOSE[]"
fails "a mode that makes no sense for bastion is refused" kon bastion --stop
fails "--forget outside bastion is refused" kon --forget

section "a value flag with no value is refused, not spun on"
bounded_fails "kon -l with no value" kon -l
contains "  and the message names the flag" "$_T_OUT" "-l"

section "the prompt segment works in a bare zsh"
out="$(zsh -f -c "source '${ROOT}/init.zsh'; print -r -- \${options[promptsubst]}")"
is "sourcing init.zsh turns prompt_subst on" "$out" "on"

section "no employer identifier is baked into the source"
is "KON_DB_SUFFIX no longer exists at all" \
   "$(grep -c 'KON_DB_SUFFIX:=' "${ROOT}/kon.zsh")" "0"

typeset -a leaks
leaks=(${(f)"$(grep -rnEi 'awsapps\.com|\.gr7\.' "${ROOT}"/*.zsh 2>/dev/null || true)"})
is "no SSO start URL or EKS endpoint in *.zsh" "${#leaks}" "0"
(( ${#leaks} )) && print -r -- "${(F)leaks}"

section "two accounts can hold the same cluster or database name"
typeset twinpick="${TMP}/twinpick"
mkdir -p "$twinpick"
cat > "${twinpick}/fzf" <<'SH'
#!/bin/sh
if [ -n "$KON_TEST_PICK" ]; then
  grep -F -- "$KON_TEST_PICK"
else
  tail -1
fi
SH
chmod +x "${twinpick}/fzf"
_kon_fzf_ok() { return 0 }

print -r -- '{}' >| "${TMP}/twin-kubeconfig.json"
typeset twin_eks="${TMP}/twin-eks.tsv"
{
  printf '%s\t%s\t%s\t%s\n' demo-dev-main 111111111111 eu-west-1 demo-dev
  printf '%s\t%s\t%s\t%s\n' demo-dev-main 222222222222 eu-west-1 demo-prod
} >| "$twin_eks"

typeset twinrow
twinrow="$(PATH="${twinpick}:${kstub}:$PATH" KON_TEST_KUBECONFIG="${TMP}/twin-kubeconfig.json" \
  KON_EKS_CACHE="$twin_eks" _kon_select demo-dev-main)"
is "the second same-named cluster resolves to its own account" \
   "$(print -r -- "$twinrow" | cut -f4)" "222222222222"

rm -f "$dlog"
KUBECONFIG="${TMP}/absent-kubeconfig" PATH="${twinpick}:${dbin}:${kstub}:$PATH" \
  _kon_eks_register eu-west-1 demo-prod demo-dev-main 222222222222 >/dev/null
contains "registering it keeps a separate kubeconfig context" \
  "$(cat "$dlog")" "--alias demo-dev-main@222222222222"

typeset twin_rds="${TMP}/twin-rds.tsv"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    twin-db aurora-postgresql 111111111111 eu-west-1 demo-dev twin-db.a.rds.amazonaws.com 5432
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    twin-db aurora-postgresql 222222222222 eu-west-1 demo-prod twin-db.b.rds.amazonaws.com 5432
} >| "$twin_rds"

twinrow="$(PATH="${twinpick}:$PATH" KON_RDS_CACHE="$twin_rds" _kon_rds_select twin-db)"
is "the second same-named database resolves to its own account" \
   "$(print -r -- "$twinrow" | cut -f3)" "222222222222"

section "an EC2 tag is sanitized before it joins the candidate stream"
typeset nasty="${TMP}/nasty-instances.json"
cat > "$nasty" <<'JSON'
{"Reservations":[{"Instances":[
 {"InstanceId":"i-good","VpcId":"vpc-1","Tags":[{"Key":"Name","Value":"my bastion"}]},
 {"InstanceId":"i-forged","VpcId":"vpc-1","Tags":[{"Key":"Name","Value":"foo\ni-0bad\tbastion\tvpc-1"}]},
 {"InstanceId":"i-esc","VpcId":"vpc-1","Tags":[{"Key":"Name","Value":"\u001b]52;c;payload\u0007 bastion"}]}
]}]}
JSON

typeset -a nrows
nrows=(${(f)"$(_kon_jump_candidates_from_json < "$nasty")"})
is "a tag carrying rows and columns stays in one row" "${#nrows}" "3"
lacks "no escape byte survives into the candidate stream" \
  "$(_kon_jump_candidates_from_json < "$nasty")" $'\x1b'

KON_JUMP_CACHE="${TMP}/nasty-bastion.tsv"
rm -f "$KON_JUMP_CACHE"
_kon_jump_candidates() { _kon_jump_candidates_from_json < "$nasty"; }
is "a name containing a space still selects its instance id" \
   "$(KON_TEST_PICK='my bastion' PATH="${twinpick}:$PATH" \
      _kon_jump_host 111111111111 eu-west-1 demo-dev '' label)" "i-good"

unfunction _kon_jump_candidates
unfunction _kon_fzf_ok
KON_JUMP_CACHE="${TMP}/bastion.tsv"

print -r -- ""
print -r -- "============================================"
print -r -- " passed: ${_T_PASS}   failed: ${_T_FAIL}"
print -r -- "============================================"
(( _T_FAIL == 0 )) || exit 1
exit 0
