
typeset -g _KON_HOME="${${(%):-%x}:A:h}"

[[ -r "${KON_CONFIG:=$HOME/.config/kon/config.zsh}" ]] && source "$KON_CONFIG"
: "${KON_CLUSTER_SUFFIX:=-main}"
typeset -ga KON_JUMP_WORDS
(( ${#KON_JUMP_WORDS} )) || KON_JUMP_WORDS=(bastion jump jumpbox jumphost)
: "${KON_AWS_CONFIG:=${AWS_CONFIG_FILE:-$HOME/.aws/config}}"
: "${KON_SSO_CACHE:=$HOME/.aws/sso/cache}"
: "${KON_RDS_CACHE:=$HOME/.local/state/kon/rds.tsv}"
: "${KON_EKS_CACHE:=$HOME/.local/state/kon/eks.tsv}"
: "${KON_JUMP_CACHE:=$HOME/.local/state/kon/bastion.tsv}"
if [[ -z "$KON_PYTHON" ]]; then
  KON_PYTHON="$(whence -p python3 2>/dev/null)"
fi

_KON_HOSTS_BEGIN="## MANAGED: kon/eks-tunnel - do not edit by hand ##"
_KON_HOSTS_END="## END MANAGED ##"
typeset -g _KON_TCP_WARNED=0
typeset -g _KON_KUBECONFIG_BACKUP_DONE=0

_kon_python() {
  emulate -L zsh
  if [[ -z "$KON_PYTHON" ]]; then
    echo "!! kon: python3 is not on PATH; it is required for ${1:-a kon command}" >&2
    echo "   Install python3, or point KON_PYTHON at it." >&2
    return 1
  fi
  print -r -- "$KON_PYTHON"
}

_kon_sso_discover() {
  emulate -L zsh
  [[ -n "$_KON_SSO_SESSION" && -n "$_KON_SSO_START_URL" ]] && return 0
  local out py
  py="$(_kon_python 'reading the SSO session list in the AWS config')" || return 1
  out="$("$py" -c '
import configparser, sys
path, want = sys.argv[1], sys.argv[2]
cfg = configparser.RawConfigParser()
try:
    cfg.read(path)
except Exception as e:
    sys.stderr.write("kon: cannot read %s: %s\n" % (path, e))
    sys.exit(1)
found = {}
for s in cfg.sections():
    if s.startswith("sso-session "):
        name = s.split(" ", 1)[1].strip()
        found[name] = (dict(cfg.items(s)).get("sso_start_url") or "").strip()
if want:
    if want in found:
        print(want + "\t" + found[want])
        sys.exit(0)
    sys.stderr.write("kon: no [sso-session %s] in %s\n" % (want, path))
    sys.exit(1)
if len(found) == 1:
    name, url = next(iter(found.items()))
    print(name + "\t" + url)
    sys.exit(0)
if not found:
    sys.stderr.write("kon: no [sso-session] block in %s\n" % path)
    sys.exit(1)
sys.stderr.write("kon: several sso-sessions in %s (%s) - set KON_SSO_SESSION\n"
                 % (path, ", ".join(sorted(found))))
sys.exit(1)
' "$KON_AWS_CONFIG" "${KON_SSO_SESSION:-}")" || return 1
  _KON_SSO_SESSION="${out%%$'\t'*}"
  _KON_SSO_START_URL="${out#*$'\t'}"
  [[ -n "$_KON_SSO_SESSION" ]] || return 1
  return 0
}

: "${KON_PORT_BASE:=18000}"
: "${KON_PORT_SPAN:=1000}"

: "${KON_RDS_PORT_BASE:=19000}"
: "${KON_RDS_PORT_SPAN:=1000}"

_kon_registry_from_json() {
  emulate -L zsh
  local py
  py="$(_kon_python 'reading the kubeconfig')" || return 1
  "$py" -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
clusters = {c.get("name"): (c.get("cluster") or {}) for c in (d.get("clusters") or [])}
users    = {u.get("name"): (u.get("user") or {})    for u in (d.get("users") or [])}
for ctx in (d.get("contexts") or []):
    name = ctx.get("name") or ""
    c    = ctx.get("context") or {}
    ckey = c.get("cluster") or ""
    if not ckey.startswith("arn:aws:eks:"):
        continue
    parts = ckey.split(":")
    if len(parts) < 6:
        continue
    region, account = parts[3], parts[4]
    cname = ckey.split("cluster/")[-1]
    env = {e.get("name"): e.get("value")
           for e in ((users.get(c.get("user")) or {}).get("exec") or {}).get("env") or []}
    profile = env.get("AWS_PROFILE") or "-"
    cl      = clusters.get(ckey) or {}
    server  = cl.get("server") or ""
    m = re.search(r":(\d+)/?$", server)
    port = m.group(1) if m else "-"
    host = cl.get("tls-server-name") or ""
    if not host:
        h = re.sub(r"^https?://", "", server).split(":")[0]
        if h and not h.startswith("127.") and h != "localhost":
            host = h
    print("\t".join([name, ckey, region, account, cname, profile, port, host or "-"]))
'
}

_kon_eks_cache_rows() {
  emulate -L zsh
  [[ -r "$KON_EKS_CACHE" ]] || return 0
  grep -v -e '^#' -e '^$' -- "$KON_EKS_CACHE" 2>/dev/null
}

_kon_registry() {
  emulate -L zsh
  local -a rows
  local row ctx ckey region account cname profile port host
  local crow cname2 account2 region2 profile2
  local -a known

  rows=(${(f)"$(kubectl config view -o json 2>/dev/null | _kon_registry_from_json)"})
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    known+=("${account}/${cname}")
  done

  for crow in ${(f)"$(_kon_eks_cache_rows)"}; do
    IFS=$'\t' read -r cname2 account2 region2 profile2 <<< "$crow"
    [[ -n "$cname2" && -n "$account2" ]] || continue
    (( ${known[(Ie)${account2}/${cname2}]} )) && continue
    rows+=("-	arn:aws:eks:${region2}:${account2}:cluster/${cname2}	${region2}	${account2}	${cname2}	${profile2:--}	-	-")
  done

  (( ${#rows} )) || return 0
  print -rl -- "${rows[@]}"
}

_kon_profiles() {
  emulate -L zsh
  local cfg="${1:-$KON_AWS_CONFIG}" sess="${2:-}"
  local py
  if [[ -z "$sess" ]]; then
    _kon_sso_discover || return 1
    sess="$_KON_SSO_SESSION"
  fi
  py="$(_kon_python 'reading the profiles in the AWS config')" || return 1
  "$py" -c '
import configparser, sys
cfg = configparser.RawConfigParser()
try:
    cfg.read(sys.argv[1])
except Exception:
    sys.exit(0)
for s in cfg.sections():
    if not s.startswith("profile "):
        continue
    name = s.split(" ", 1)[1].strip()
    d = {k: (v or "").strip() for k, v in cfg.items(s)}
    if d.get("sso_session") != sys.argv[2]:
        continue
    acct = d.get("sso_account_id")
    if not acct:
        continue
    print("\t".join([name, acct, d.get("region") or "-"]))
' "$cfg" "$sess"
}

_kon_profile_for_account() {
  emulate -L zsh
  local want="$1" row p acct reg
  [[ -n "$want" ]] || return 1
  for row in ${(f)"$(_kon_profiles)"}; do
    IFS=$'\t' read -r p acct reg <<< "$row"
    [[ "$acct" == "$want" ]] && { print -r -- "$p"; return 0 }
  done
  return 1
}

_kon_sso_expiry_epoch() {
  emulate -L zsh
  local py
  _kon_sso_discover || { print -r -- 0; return 1 }
  py="$(_kon_python 'reading the SSO token cache')" || { print -r -- 0; return 1 }
  "$py" -c '
import glob, json, os, sys
from datetime import datetime, timezone

def parse(v):
    v = (v or "").strip()
    if not v:
        return 0
    v = v.replace("UTC", "").replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f",
                "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z"):
        try:
            dt = datetime.strptime(v, fmt)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return 0

best = 0
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if d.get("startUrl") != sys.argv[2] or not d.get("accessToken"):
        continue
    best = max(best, parse(d.get("expiresAt")))
print(best)
' "$KON_SSO_CACHE" "$_KON_SSO_START_URL"
}

_kon_sso_refreshable() {
  emulate -L zsh
  local py
  _kon_sso_discover || return 1
  py="$(_kon_python 'reading the SSO token cache')" || return 1
  "$py" -c '
import glob, json, os, sys
from datetime import datetime, timezone

def parse(v):
    v = (v or "").strip().replace("UTC", "").replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f",
                "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z"):
        try:
            dt = datetime.strptime(v, fmt)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return 0

now = int(datetime.now(timezone.utc).timestamp())
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if d.get("startUrl") != sys.argv[2] or not d.get("refreshToken"):
        continue
    reg = parse(d.get("registrationExpiresAt"))
    if reg == 0 or reg > now:
        sys.exit(0)
sys.exit(1)
' "$KON_SSO_CACHE" "$_KON_SSO_START_URL"
}

_kon_ensure_sso() {
  emulate -L zsh
  local profile="${1:-}" exp now
  _kon_sso_discover || return 1
  exp="$(_kon_sso_expiry_epoch 2>/dev/null)"
  [[ "$exp" == <-> ]] || exp=0
  now=$(date +%s)

  if (( exp > now + 120 )); then
    echo ">> SSO     : token good for $(( (exp - now) / 60 ))m (refreshes silently when next used)"
    return 0
  fi

  if [[ -n "$profile" ]] && _kon_sso_refreshable; then
    if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
      exp="$(_kon_sso_expiry_epoch 2>/dev/null)"
      [[ "$exp" == <-> ]] || exp=0
      now=$(date +%s)
      if (( exp > now )); then
        echo ">> SSO     : token renewed silently, good for $(( (exp - now) / 60 ))m"
      else
        echo ">> SSO     : token renewed silently"
      fi
      return 0
    fi
  fi

  if (( exp == 0 )); then
    echo ">> SSO     : no cached token - opening browser..."
  else
    echo ">> SSO     : session cannot be renewed - opening browser..."
  fi
  aws sso login --sso-session "$_KON_SSO_SESSION" || {
    echo "!! SSO login failed" >&2; return 1
  }
  return 0
}

_kon_port_busy() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

_kon_tunnel_pid_file() {
  print -r -- "${KON_EKS_CACHE:h}/tunnel.${1}.pid"
}

_kon_tunnel_live() {
  emulate -L zsh
  local port="$1" host="$2" match="$3" pids pid cmd ppid pcmd record recorded
  [[ "$port" == <-> && -n "$host" && "$host" != "-" ]] || return 1
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
  [[ -n "$pids" ]] || return 1
  record="$(_kon_tunnel_pid_file "$port")"
  recorded=""
  [[ -r "$record" ]] && recorded="$(<"$record")"
  for pid in ${(f)pids}; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    [[ "$cmd" == (*session-manager-plugin*|*"ssm start-session"*) ]] || continue
    [[ -z "$match" || "$cmd" == *"$match"* ]] || continue
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ "$recorded" == <-> ]]; then
      [[ "$cmd" == *"$host"* ]] || continue
      [[ "$pid" == "$recorded" || "$ppid" == "$recorded" ]] && return 0
      continue
    fi
    [[ -n "$ppid" ]] || continue
    pcmd="$(ps -o command= -p "$ppid" 2>/dev/null)"
    [[ -n "$match" && "$pcmd" != *"$match"* ]] && continue
    [[ "$pcmd" == *"ssm start-session"* && "$pcmd" == *"host=${host}"* ]] && return 0
  done
  return 1
}

_kon_listener_is_ssm() {
  emulate -L zsh
  local port="$1" pids pid
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
  [[ -n "$pids" ]] || return 1
  for pid in ${(f)pids}; do
    ps -o command= -p "$pid" 2>/dev/null | grep -q 'session-manager-plugin' && return 0
  done
  return 1
}

_kon_hash() {
  emulate -L zsh
  local s="$1" ch i c h=2166136261
  for (( i = 1; i <= ${#s}; i++ )); do
    ch="$s[i]"
    c=$(( #ch ))
    h=$(( ((h ^ c) * 16777619) & 0xFFFFFFFF ))
  done
  print -r -- $h
}

_kon_port_range() {
  emulate -L zsh
  case "${1:-eks}" in
    rds) print -r -- "${KON_RDS_PORT_BASE} ${KON_RDS_PORT_SPAN}" ;;
    *)   print -r -- "${KON_PORT_BASE} ${KON_PORT_SPAN}" ;;
  esac
}

_kon_desired_port() {
  emulate -L zsh
  local base span
  read -r base span <<< "$(_kon_port_range "${2:-eks}")"
  print -r -- $(( base + $(_kon_hash "$1") % span ))
}

_kon_resolve_port() {
  emulate -L zsh
  local key="$1" host="$2" recorded="$3" kind="${4:-eks}" match="$5"
  local desired probe k base span
  read -r base span <<< "$(_kon_port_range "$kind")"
  desired="$(_kon_desired_port "$key" "$kind")"

  if [[ "$recorded" == <-> ]] && _kon_tunnel_live "$recorded" "$host" "$match"; then
    [[ "$recorded" == "$desired" ]] || \
      echo ">> Port    : keeping the live tunnel on ${recorded} (canonical ${desired}, adopted on next reconnect)" >&2
    print -r -- "$recorded"
    return 0
  fi

  if ! _kon_port_busy "$desired" || _kon_tunnel_live "$desired" "$host" "$match"; then
    print -r -- "$desired"
    return 0
  fi

  for (( k = 1; k < span; k++ )); do
    probe=$(( base + ((desired - base) + k) % span ))
    if ! _kon_port_busy "$probe" || _kon_tunnel_live "$probe" "$host" "$match"; then
      echo "!! Port ${desired} is held by another process; falling back to ${probe}" >&2
      print -r -- "$probe"
      return 0
    fi
  done
  return 1
}

_kon_fzf_ok() {
  command -v fzf >/dev/null 2>&1 && [[ -t 0 ]]
}

_kon_jump_candidates_from_json() {
  emulate -L zsh
  local py
  py="$(_kon_python 'reading the instance list from AWS')" || return 1
  "$py" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def clean(v):
    v = "".join(" " if ord(c) < 32 or 127 <= ord(c) < 160 else c for c in (v or ""))
    return " ".join(v.split()) or "-"
NODE_KEYS = ("eks:cluster-name", "aws:eks:cluster-name")
NODE_PREFIX = "kubernetes.io/cluster/"
for r in (d.get("Reservations") or []):
    for i in (r.get("Instances") or []):
        iid = i.get("InstanceId") or ""
        if not iid:
            continue
        tags = {t.get("Key"): t.get("Value") for t in (i.get("Tags") or [])}
        if any(k in tags for k in NODE_KEYS):
            continue
        if any(k.startswith(NODE_PREFIX) for k in tags):
            continue
        print("\t".join([iid, clean(tags.get("Name")), i.get("VpcId") or "-"]))
'
}

_kon_jump_candidates() {
  emulate -L zsh
  local region="$1" profile="$2" ids
  ids="$(aws ssm describe-instance-information \
    --region "$region" --profile "$profile" \
    --filters "Key=PingStatus,Values=Online" \
    --query 'InstanceInformationList[?starts_with(InstanceId, `i-`)].InstanceId' \
    --output text 2>/dev/null)"
  if [[ -z "$ids" || "$ids" == "None" ]]; then
    aws ec2 describe-instances \
      --region "$region" --profile "$profile" \
      --filters "Name=instance-state-name,Values=running" \
      --output json 2>/dev/null | _kon_jump_candidates_from_json
    return 0
  fi
  aws ec2 describe-instances \
    --region "$region" --profile "$profile" \
    --instance-ids ${=ids} \
    --filters "Name=instance-state-name,Values=running" \
    --output json 2>/dev/null | _kon_jump_candidates_from_json
}

_kon_rank_candidates() {
  emulate -L zsh
  local hint="$1"; shift
  local -a rows kept
  local row id name vpc w wl nl
  rows=("$@")
  (( ${#rows} > 1 )) || { print -rl -- "${rows[@]}"; return 0 }

  for w in "${KON_JUMP_WORDS[@]}"; do
    wl="${w:l}"
    kept=()
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r id name vpc <<< "$row"
      nl="${name:l}"
      [[ "$nl" == *"$wl"* ]] && kept+=("$row")
    done
    if (( ${#kept} == 1 )); then
      print -rl -- "${kept[1]}"
      return 0
    fi
    if (( ${#kept} > 1 )); then
      rows=("${kept[@]}")
      break
    fi
  done

  if (( ${#rows} > 1 )) && [[ -n "$hint" ]]; then
    kept=()
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r id name vpc <<< "$row"
      [[ "${name:l}" == *"${hint:l}"* ]] && kept+=("$row")
    done
    (( ${#kept} == 1 )) && rows=("${kept[1]}")
  fi

  print -rl -- "${rows[@]}"
}

_kon_jump_cache_rows() {
  emulate -L zsh
  [[ -r "$KON_JUMP_CACHE" ]] || return 0
  grep -v -e '^#' -e '^$' -- "$KON_JUMP_CACHE" 2>/dev/null
}

_kon_jump_cache_split() {
  emulate -L zsh
  local row="$1" a r third fourth fifth
  IFS=$'\t' read -r a r third fourth fifth <<< "$row"
  if [[ "$third" == vpc-* || "$third" == "-" ]]; then
    print -r -- "${a}"$'\t'"${r}"$'\t'"${third}"$'\t'"${fourth}"
  else
    print -r -- "${a}"$'\t'"${r}"$'\t'"-"$'\t'"${third}"
  fi
}

_kon_jump_cache_vpc_of() {
  emulate -L zsh
  local account="$1" region="$2" row a r v n
  for row in ${(f)"$(_kon_jump_cache_rows)"}; do
    IFS=$'\t' read -r a r v n <<< "$(_kon_jump_cache_split "$row")"
    [[ "$a" == "$account" && "$r" == "$region" ]] || continue
    print -r -- "$v"
    return 0
  done
  return 1
}

_kon_jump_cache_get() {
  emulate -L zsh
  local account="$1" region="$2" vpc="${3:--}"
  local row a r v name
  for row in ${(f)"$(_kon_jump_cache_rows)"}; do
    IFS=$'\t' read -r a r v name <<< "$(_kon_jump_cache_split "$row")"
    [[ "$a" == "$account" && "$r" == "$region" ]] || continue
    [[ -n "$name" && "$name" != "-" ]] || continue
    [[ "$v" == "-" || "$vpc" == "-" || "$v" == "$vpc" ]] || continue
    print -r -- "$name"
    return 0
  done
  return 1
}

_kon_jump_cache_set() {
  emulate -L zsh
  local account="$1" region="$2" name="$3" vpc="${4:--}"
  local row a r v n
  local -a keep
  for row in ${(f)"$(_kon_jump_cache_rows)"}; do
    IFS=$'\t' read -r a r v n <<< "$(_kon_jump_cache_split "$row")"
    if [[ "$a" == "$account" && "$r" == "$region" ]]; then
      [[ "$v" == "-" || "$vpc" == "-" || "$v" == "$vpc" ]] && continue
    fi
    keep+=("${a}"$'\t'"${r}"$'\t'"${v}"$'\t'"${n}")
  done
  keep+=("${account}	${region}	${vpc}	${name}")
  mkdir -p -- "${KON_JUMP_CACHE:h}" || return 1
  {
    echo "# written by kon on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# account	region	vpc	name"
    print -rl -- "${keep[@]}"
  } >| "${KON_JUMP_CACHE}.tmp" || return 1
  mv -f -- "${KON_JUMP_CACHE}.tmp" "$KON_JUMP_CACHE"
}

_kon_jump_cache_forget() {
  emulate -L zsh
  local account="$1" row a r v n dropped=0
  local -a keep
  for row in ${(f)"$(_kon_jump_cache_rows)"}; do
    IFS=$'\t' read -r a r v n <<< "$(_kon_jump_cache_split "$row")"
    if [[ -z "$account" || "$a" == "$account" || "$n" == "$account" ]]; then
      dropped=$((dropped + 1))
      continue
    fi
    keep+=("${a}"$'\t'"${r}"$'\t'"${v}"$'\t'"${n}")
  done
  (( dropped )) || { echo ">> Nothing cached${account:+ for '$account'}"; return 0 }
  mkdir -p -- "${KON_JUMP_CACHE:h}" || return 1
  {
    echo "# written by kon on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# account	region	vpc	name"
    (( ${#keep} )) && print -rl -- "${keep[@]}"
  } >| "${KON_JUMP_CACHE}.tmp" || return 1
  mv -f -- "${KON_JUMP_CACHE}.tmp" "$KON_JUMP_CACHE"
  echo ">> Forgot ${dropped} entr$( (( dropped == 1 )) && print -n y || print -n ies )"
}

_kon_jump_resolve_name() {
  emulate -L zsh
  local region="$1" profile="$2" name="$3" out
  out="$(aws ec2 describe-instances \
    --region "$region" --profile "$profile" \
    --filters "Name=instance-state-name,Values=running" \
    --output json 2>/dev/null | _kon_jump_candidates_from_json \
    | awk -F'\t' -v want="${name:l}" 'tolower($2) == want { print $1 }')"
  [[ -n "$out" ]] || return 1
  (( $(print -r -- $out | wc -w) == 1 )) || return 2
  print -r -- "$out"
}

_kon_jump_pick() {
  emulate -L zsh
  local label="$1"; shift
  local -a rows
  local row id name vpc pick
  rows=("$@")
  if ! _kon_fzf_ok; then
    echo "!! Several instances could serve ${label}; there is no terminal to choose in." >&2
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r id name vpc <<< "$row"
      echo "     ${id}  ${name}" >&2
    done
    echo "   Run 'kon bastion' once in a terminal, or pass --bastion <name|i-xxxx>." >&2
    return 1
  fi
  pick="$(for row in "${rows[@]}"; do
            IFS=$'\t' read -r id name vpc <<< "$row"
            print -r -- "${id}"$'\t'"$(printf '%-24s %s' "$name" "$id")"
          done | fzf --height=40% --reverse --prompt='jump host> ' \
                     --delimiter=$'\t' --with-nth=2.. \
                     --header="kon: pick the instance to reach ${label} through" \
          | cut -f1)"
  [[ -n "$pick" ]] || { echo "!! Nothing selected" >&2; return 1 }
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id name vpc <<< "$row"
    [[ "$id" == "$pick" ]] && { print -r -- "$row"; return 0 }
  done
  return 1
}

_kon_jump_host() {
  emulate -L zsh
  local account="$1" region="$2" profile="$3" pin="$4" label="${5:-target}"
  local hint="$6" want_vpc="${7:--}"
  local -a rows invpc
  local row id name vpc cached picked rc

  if [[ "$pin" == i-* ]]; then
    print -r -- "$pin"
    return 0
  fi
  if [[ -n "$pin" ]]; then
    id="$(_kon_jump_resolve_name "$region" "$profile" "$pin")"
    rc=$?
    if (( rc == 0 )); then
      print -r -- "$id"
      return 0
    fi
    (( rc == 2 )) \
      && echo "!! Several running instances are named '${pin}'" >&2 \
      || echo "!! No running instance named '${pin}' in ${profile}/${region}" >&2
    return 1
  fi

  if cached="$(_kon_jump_cache_get "$account" "$region" "$want_vpc")"; then
    id="$(_kon_jump_resolve_name "$region" "$profile" "$cached")"
    rc=$?
    if (( rc == 0 )); then
      if [[ "$want_vpc" == vpc-* ]] \
         && [[ "$(_kon_jump_cache_vpc_of "$account" "$region")" == "-" ]]; then
        _kon_jump_cache_set "$account" "$region" "$cached" "$want_vpc"
      fi
      print -r -- "$id"
      return 0
    fi
    (( rc == 2 )) \
      && echo ">> Jump    : '${cached}' is ambiguous now, choosing again" >&2 \
      || echo ">> Jump    : remembered host '${cached}' is gone, looking again" >&2
  fi

  rows=(${(f)"$(_kon_jump_candidates "$region" "$profile")"})
  if (( ${#rows} == 0 )); then
    echo "!! No instance can serve ${label} in ${profile}/${region}." >&2
    echo "   Looked for a running instance that is SSM-managed and not a cluster node." >&2
    echo "   Pin one with --bastion <name|i-xxxx>." >&2
    return 1
  fi

  if (( ${#rows} > 1 )) && [[ "$want_vpc" == vpc-* ]]; then
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r id name vpc <<< "$row"
      [[ "$vpc" == "$want_vpc" ]] && invpc+=("$row")
    done
    (( ${#invpc} )) && rows=("${invpc[@]}")
  fi

  if (( ${#rows} > 1 )); then
    rows=(${(f)"$(_kon_rank_candidates "$hint" "${rows[@]}")"})
  fi

  if (( ${#rows} == 1 )); then
    IFS=$'\t' read -r id name vpc <<< "${rows[1]}"
    [[ -n "$account" && "$name" != "-" ]] \
      && _kon_jump_cache_set "$account" "$region" "$name" "$vpc"
    print -r -- "$id"
    return 0
  fi

  picked="$(_kon_jump_pick "$label" "${rows[@]}")" || return 1
  IFS=$'\t' read -r id name vpc <<< "$picked"
  [[ -n "$account" ]] && _kon_jump_cache_set "$account" "$region" "$name" "$vpc"
  print -r -- "$id"
  return 0
}

_kon_eks_host() {
  emulate -L zsh
  local region="$1" profile="$2" cluster_name="$3" out host vpc
  out="$(aws eks describe-cluster \
    --region "$region" --profile "$profile" --name "$cluster_name" \
    --query '[cluster.endpoint,cluster.resourcesVpcConfig.vpcId]' \
    --output text 2>/dev/null)"
  IFS=$'\t' read -r host vpc <<< "$out"
  host="${host#https://}"; host="${host#http://}"; host="${host%/}"
  if [[ -z "$host" || "$host" == "None" ]]; then
    echo "!! EKS endpoint not found for cluster: ${cluster_name}" >&2
    return 1
  fi
  [[ -n "$vpc" && "$vpc" != "None" ]] || vpc="-"
  print -r -- "${host}"$'\t'"${vpc}"
}

_kon_port_ready() {
  emulate -L zsh
  local port="$1" fd
  if ! zmodload -F zsh/net/tcp b:ztcp 2>/dev/null; then
    if (( ! _KON_TCP_WARNED )); then
      echo "!! kon: the zsh/net/tcp module is unavailable, so 127.0.0.1:${port} is not probed" >&2
      _KON_TCP_WARNED=1
    fi
    return 2
  fi
  ztcp 127.0.0.1 "$port" 2>/dev/null || return 1
  fd=$REPLY
  ztcp -c "$fd" 2>/dev/null
  return 0
}

_kon_start_tunnel() {
  emulate -L zsh
  local region="$1" profile="$2" instance_id="$3" host="$4"
  local remote_port="$5" local_port="$6" timeout="${7:-180}" tag="${8:-kon}"
  local dir="${KON_EKS_CACHE:h}/logs"
  local log="${dir}/${tag}-tunnel.${local_port}.log"
  ( umask 077; mkdir -p -- "$dir" && : >| "$log" ) || return 1
  nohup aws ssm start-session \
    --region "$region" --profile "$profile" \
    --target "$instance_id" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${host},portNumber=${remote_port},localPortNumber=${local_port}" \
    >"$log" 2>&1 &
  local pid=$!
  disown
  print -r -- "$pid" >| "$(_kon_tunnel_pid_file "$local_port")"
  local end=$((SECONDS + timeout)) rc
  while true; do
    _kon_port_ready "$local_port"
    rc=$?
    (( rc == 1 )) || return 0
    if (( SECONDS >= end )); then
      echo "!! Timed out after ${timeout}s waiting for 127.0.0.1:${local_port}. Log: ${log}" >&2
      return 1
    fi
    sleep 0.2
  done
}

_kon_kill_port() {
  emulate -L zsh
  local port="$1" pids pid ppid killed=0
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
  [[ -n "$pids" ]] || return 1
  for pid in ${(f)pids}; do
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ -n "$ppid" ]] && ps -o command= -p "$ppid" 2>/dev/null | grep -q 'ssm start-session'; then
      kill "$ppid" 2>/dev/null && killed=1
    fi
    kill "$pid" 2>/dev/null && killed=1
  done
  (( killed )) || return 1
  rm -f -- "$(_kon_tunnel_pid_file "$port")"
  return 0
}

_kon_orphans_matching() {
  emulate -L zsh
  local domain="$1"; shift
  local -a known lines
  local l host port k hit out=""
  known=("$@")
  lines=(${(f)"$(ps -Ao command= 2>/dev/null \
    | grep 'AWS-StartPortForwardingSessionToRemoteHost' \
    | grep -- '--parameters' \
    | grep -- "$domain" \
    | grep -v grep)"})
  for l in "${lines[@]}"; do
    [[ "$l" == *host=*localPortNumber=* ]] || continue
    host="${${l##*host=}%%,*}"
    port="${${l##*localPortNumber=}%%[^0-9]*}"
    [[ -n "$host" && -n "$port" ]] || continue
    hit=0
    for k in "${known[@]}"; do
      [[ -n "$k" && "$k" != "-" && "$host" == *"$k"* ]] && { hit=1; break }
    done
    (( hit )) && continue
    out+="   127.0.0.1:${port} -> ${host}"$'\n'
  done
  print -rn -- "$out"
}

_kon_orphan_tunnels() {
  _kon_orphans_matching 'eks.amazonaws.com' "$@"
}

_kon_rds_orphan_tunnels() {
  _kon_orphans_matching 'rds.amazonaws.com' "$@"
}

_kon_hosts_has() {
  emulate -L zsh
  local host="$1"
  [[ -n "$host" && "$host" != "-" ]] || return 1
  grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${host//./\\.}([[:space:]]|\$)" /etc/hosts 2>/dev/null
}

_kon_hosts_entry() {
  emulate -L zsh
  local host="$1" label="${2:-}" ans=""
  local py
  _kon_hosts_has "$host" && return 0
  echo ">> hosts   : no 127.0.0.1 entry for ${host}"
  echo "             kubectl does NOT need it (tls-server-name covers SNI)."
  echo "             Terraform does: kubernetes_host_override has no tls_server_name."
  if ! read -q "ans?             Add it now with sudo? [y/N] "; then
    echo
    echo "             skipped - manual: echo '127.0.0.1 ${host}' | sudo tee -a /etc/hosts"
    return 1
  fi
  echo
  py="$(_kon_python 'updating /etc/hosts')" || return 1
  sudo "$py" -c '
import shutil, sys, time
path, host, label, begin, end = "/etc/hosts", sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
shutil.copy2(path, path + ".bak." + time.strftime("%Y%m%d-%H%M%S"))
lines = open(path).read().splitlines()
entry = "127.0.0.1 " + host + ("  # " + label if label else "")
if begin in lines:
    i = lines.index(begin)
    j = lines.index(end, i) if end in lines[i:] else len(lines)
    lines.insert(j, entry)
else:
    lines += [begin, entry, end]
open(path, "w").write("\n".join(lines) + "\n")
' "$host" "$label" "$_KON_HOSTS_BEGIN" "$_KON_HOSTS_END" || {
    echo "!! Failed to update /etc/hosts" >&2; return 1
  }
  _kon_hosts_has "$host" && { echo ">> hosts   : added 127.0.0.1 ${host}"; return 0 }
  return 1
}

_kon_kubeconfig_backup() {
  emulate -L zsh
  (( _KON_KUBECONFIG_BACKUP_DONE )) && return 0
  local cfg="${KUBECONFIG:-$HOME/.kube/config}"
  cfg="${cfg%%:*}"
  [[ -f "$cfg" ]] || { _KON_KUBECONFIG_BACKUP_DONE=1; return 0; }
  local stamp dest n=1
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dest="${cfg}.bak.${stamp}"
  while [[ -e "$dest" ]]; do
    n=$((n + 1))
    dest="${cfg}.bak.${stamp}-${n}"
  done
  if ! cp -p "$cfg" "$dest"; then
    echo "!! Could not back up ${cfg} to ${dest}" >&2
    return 1
  fi
  _KON_KUBECONFIG_BACKUP_DONE=1
  return 0
}

_kon_set_cluster_endpoint() {
  emulate -L zsh
  local port="$1" host="$2" cfg_name cur target
  cfg_name="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null)"
  [[ -n "$cfg_name" ]] || { echo "!! Could not resolve kubeconfig cluster name" >&2; return 1 }
  cur="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  target="https://127.0.0.1:${port}"
  _kon_kubeconfig_backup || return 1
  kubectl config set-cluster "$cfg_name" --server "$target" --tls-server-name "$host" >/dev/null || return 1
  [[ "$cur" == "$target" ]] || echo ">> Kubecfg : server=${target}  tls-server-name=${host}"
  return 0
}

_kon_healthcheck() {
  emulate -L zsh
  local out
  if out="$(kubectl get --raw /readyz 2>&1)"; then
    echo ">> Health  : /readyz -> ${out}"
    return 0
  fi
  if [[ "${out:l}" == *forbidden* || "${out:l}" == *unauthorized* ]]; then
    echo ">> Health  : reachable (RBAC denies /readyz, connectivity OK)"
    return 0
  fi
  echo "!! Health  : ${out}" >&2
  return 1
}

_kon_select() {
  emulate -L zsh
  local want="$1" want_profile="$2" want_account="$3"
  local -a all hits lines keep
  local row ctx ckey region account cname profile port host state pick

  all=(${(f)"$(_kon_registry)"})
  if (( ${#all} == 0 )); then
    echo "!! No EKS context in kubeconfig. Try: kon --discover" >&2
    return 1
  fi

  if [[ -n "$want_profile" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      [[ "$profile" == "$want_profile" || "$profile" == ${want_profile}* ]] && keep+=("$row")
    done
    if (( ${#keep} == 0 )); then
      echo "!! No cluster cached for profile '${want_profile}'. Try: kon eks --discover" >&2
      return 1
    fi
    all=("${keep[@]}")
  fi

  if [[ -n "$want_account" ]]; then
    keep=()
    for row in "${all[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      [[ "$account" == "$want_account" ]] && keep+=("$row")
    done
    if (( ${#keep} == 0 )); then
      echo "!! No cluster ${want} in account '${want_account}'" >&2
      return 1
    fi
    all=("${keep[@]}")
  fi

  if [[ -z "$want" ]]; then
    hits=("${all[@]}")
  else
    for row in "${all[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      [[ "$cname" == "$want" || "$ctx" == "$want" ]] && hits+=("$row")
    done
    if (( ${#hits} == 0 )); then
      for row in "${all[@]}"; do
        IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
        [[ "$cname" == ${want}* || "$ctx" == ${want}* ]] && hits+=("$row")
      done
    fi
    if (( ${#hits} == 0 )); then
      for row in "${all[@]}"; do
        IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
        [[ "$cname" == *${want}* || "$ctx" == *${want}* ]] && hits+=("$row")
      done
    fi
  fi

  if (( ${#hits} == 0 )); then
    echo "!! No cluster matches '${want}'. Known clusters:" >&2
    for row in "${all[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      echo "     ${cname}" >&2
    done
    return 1
  fi

  if (( ${#hits} == 1 )); then
    print -r -- "${hits[1]}"
    return 0
  fi

  if ! _kon_fzf_ok; then
    echo "!! '${want}' is ambiguous and fzf is unavailable. Candidates:" >&2
    for row in "${hits[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      echo "     ${cname}" >&2
    done
    return 1
  fi

  for row in "${hits[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    state="$(_kon_state_label "$port" "$host")"
    lines+=("${ckey}"$'\t'"$(printf '%-22s %-16s %-13s %-15s %s' \
      "$cname" "${profile#-}" "$account" "$region" "$state")")
  done

  pick="$(print -rl -- "${lines[@]}" \
    | fzf --height=40% --reverse --prompt='cluster> ' \
          --delimiter=$'\t' --with-nth=2.. \
          --header='kon: pick a cluster (cluster / profile / account / region / tunnel)' \
    | cut -f1)"
  [[ -n "$pick" ]] || { echo "!! Nothing selected" >&2; return 1 }

  for row in "${hits[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    [[ "$ckey" == "$pick" ]] && { print -r -- "$row"; return 0 }
  done
  return 1
}

_kon_state_label() {
  emulate -L zsh
  local port="$1" host="$2"
  [[ "$port" == <-> ]] || { print -r -- "down"; return }
  _kon_port_busy "$port" || { print -r -- "down"; return }
  if _kon_tunnel_live "$port" "$host"; then
    print -r -- "up:${port}"
  elif [[ "$host" == "-" ]] && _kon_listener_is_ssm "$port"; then
    print -r -- "up:${port}?"
  else
    print -r -- "down"
  fi
}

_kon_eks_status() {
  emulate -L zsh
  local profile_filter="$1"
  local row ctx ckey region account cname profile port host current orphan
  local desired shown state marker rank drift=0 unreg=0
  local -a all hosts lines keep
  all=(${(f)"$(_kon_registry)"})
  (( ${#all} )) || { echo "No cluster known. Try: kon eks --discover"; return 0 }
  if [[ -n "$profile_filter" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      [[ "$profile" == "$profile_filter" || "$profile" == ${profile_filter}* ]] && keep+=("$row")
    done
    all=("${keep[@]}")
    if (( ${#all} == 0 )); then
      echo "No cluster cached${profile_filter:+ for '$profile_filter'}. Try: kon eks --discover"
      return 0
    fi
  fi
  current="$(kubectl config current-context 2>/dev/null)"
  printf '%-2s %-22s %-16s %-15s %-8s %s\n' "" "CLUSTER" "PROFILE" "REGION" "PORT" "TUNNEL"
  for row in "${all[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    [[ "$host" != "-" ]] && hosts+=("$host")
    desired="$(_kon_desired_port "${account}/${cname}")"
    state="$(_kon_state_label "$port" "$host")"
    if [[ "$ctx" == "-" ]]; then
      shown="$desired"; marker="+"; rank=2; unreg=1
    else
      marker="$( [[ "$ctx" == "$current" ]] && print -r -- '*' )"
      if [[ "$port" == "$desired" ]]; then
        shown="$desired"
      else
        shown="${desired}~"; drift=1
      fi
      [[ "$state" == up* ]] && rank=0 || rank=1
    fi
    lines+=("${rank}	${cname}	$(printf '%-2s %-22s %-16s %-15s %-8s %s' \
      "$marker" "$cname" "${profile#-}" "$region" "$shown" "$state")")
  done
  print -rl -- "${lines[@]}" | sort -t$'\t' -k1,1 -k2,2 | cut -f3-
  (( drift )) && echo "~ = derived port not yet adopted in the kubeconfig (next connect does it)"
  (( unreg )) && echo "+ = discovered but not in the kubeconfig yet (first connect registers it)"
  orphan="$(_kon_orphan_tunnels "${hosts[@]}")"
  [[ -n "$orphan" ]] && { echo; echo "Tunnels unknown to the kubeconfig:"; print -rn -- "$orphan" }
  return 0
}

_kon_eks_stop() {
  emulate -L zsh
  local want="$1" profile_filter="$2" row ctx ckey region account cname profile port host stopped=0 orphan
  local -a all hits hosts

  all=(${(f)"$(_kon_registry)"})
  for row in "${all[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    [[ "$host" != "-" ]] && hosts+=("$host")
  done

  if [[ -n "$profile_filter" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
      [[ "$profile" == "$profile_filter" || "$profile" == ${profile_filter}* ]] && hits+=("$row")
    done
    all=("${hits[@]}")
    hits=()
  fi

  if [[ -n "$want" ]]; then
    row="$(_kon_select "$want" "$profile_filter")" || return 1
    hits=("$row")
  else
    hits=("${all[@]}")
  fi

  for row in "${hits[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    [[ "$port" == <-> ]] || continue
    _kon_port_busy "$port" || continue
    if ! _kon_tunnel_live "$port" "$host"; then
      if [[ "$host" != "-" ]] || ! _kon_listener_is_ssm "$port"; then
        echo ">> Skipped ${cname}: 127.0.0.1:${port} is not this cluster's tunnel"
        continue
      fi
    fi
    if _kon_kill_port "$port"; then
      echo ">> Stopped ${cname} (127.0.0.1:${port})"
      stopped=$((stopped + 1))
    else
      echo "!! Could not stop ${cname} (127.0.0.1:${port})" >&2
    fi
  done

  (( stopped )) || echo ">> No tunnel to stop${want:+ for '$want'}"
  [[ -n "$want" ]] || unset TF_VAR_kubernetes_host_override
  orphan="$(_kon_orphan_tunnels "${hosts[@]}")"
  [[ -n "$orphan" ]] && { echo ">> Still running (unknown to the kubeconfig):"; print -rn -- "$orphan" }
  return 0
}

_kon_eks_discover() {
  emulate -L zsh
  local only_profile="$1"
  local row p acct preg c list found=0 known=0
  local -a prows out keep
  local kc ka kr kp

  prows=(${(f)"$(_kon_profiles)"})
  if (( ${#prows} == 0 )); then
    echo "!! No profile on sso_session '${_KON_SSO_SESSION}' in ${KON_AWS_CONFIG}" >&2
    return 1
  fi

  if [[ -n "$only_profile" ]]; then
    for row in "${prows[@]}"; do
      [[ "$row" == "$only_profile"$'\t'* ]] && known=1
    done
    (( known )) || {
      echo "!! No profile '${only_profile}' on sso_session '${_KON_SSO_SESSION}'" >&2
      return 1
    }
  fi

  IFS=$'\t' read -r p acct preg <<< "${prows[1]}"
  _kon_ensure_sso "${only_profile:-$p}" || return 1

  for row in "${prows[@]}"; do
    IFS=$'\t' read -r p acct preg <<< "$row"
    [[ -n "$only_profile" && "$p" != "$only_profile" ]] && continue
    if [[ "$preg" == "-" || -z "$preg" ]]; then
      preg="$(aws configure get region --profile "$p" 2>/dev/null)"
      : "${preg:=${AWS_DEFAULT_REGION:-}}"
    fi
    if [[ -z "$preg" ]]; then
      echo "   ${p} (${acct}): no region configured - skipped" >&2
      continue
    fi
    list="$(aws eks list-clusters --profile "$p" --region "$preg" \
              --query 'clusters[]' --output text 2>/dev/null)"
    if [[ -z "$list" || "$list" == "None" ]]; then
      echo "   ${p} (${acct}/${preg}): no cluster"
      continue
    fi
    for c in ${=list}; do
      out+=("${c}	${acct}	${preg}	${p}")
      found=$((found + 1))
      echo "   ${p}: + ${c}"
    done
  done

  if (( found == 0 )) && [[ -z "$only_profile" ]]; then
    echo ">> Discover: no cluster found."
    return 0
  fi

  if [[ -n "$only_profile" ]]; then
    for row in ${(f)"$(_kon_eks_cache_rows)"}; do
      IFS=$'\t' read -r kc ka kr kp <<< "$row"
      [[ "$kp" == "$only_profile" ]] && continue
      keep+=("$row")
    done
  fi

  mkdir -p -- "${KON_EKS_CACHE:h}" || return 1
  {
    echo "# written by kon eks --discover on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# cluster	account	region	profile"
    print -rl -- "${keep[@]}" "${out[@]}"
  } >| "${KON_EKS_CACHE}.tmp" || return 1
  mv -f -- "${KON_EKS_CACHE}.tmp" "$KON_EKS_CACHE" || return 1
  echo ">> Discover: ${found} cluster(s) recorded in ${KON_EKS_CACHE}"
  echo "   Nothing was written to the kubeconfig; connecting to one registers it."
  return 0
}

_kon_eks_register() {
  emulate -L zsh
  local region="$1" profile="$2" cname="$3" account="${4:-}"
  local alias="$cname"
  if [[ -n "$account" ]] && print -rl -- ${(f)"$(kubectl config view -o json 2>/dev/null \
       | _kon_registry_from_json)"} \
       | awk -F'\t' -v c="$cname" -v a="$account" '$5 == c && $4 != a { f = 1 } END { exit !f }'; then
    alias="${cname}@${account}"
  fi
  _kon_kubeconfig_backup || return 1
  if ! aws eks update-kubeconfig --profile "$profile" --region "$region" \
         --name "$cname" --alias "$alias" >/dev/null 2>&1; then
    echo "!! Could not register ${cname} in the kubeconfig (profile ${profile}, ${region})" >&2
    return 1
  fi
  print -r -- "$alias"
}

_kon_eks_prune() {
  emulate -L zsh
  local row ctx ckey region account cname profile port host reply
  local -a cache_keys ctx_rows drop_ctx drop_key seen
  local crow cname2 account2 region2 profile2 key

  for crow in ${(f)"$(_kon_eks_cache_rows)"}; do
    IFS=$'\t' read -r cname2 account2 region2 profile2 <<< "$crow"
    [[ -n "$cname2" ]] && cache_keys+=("${account2}/${cname2}")
  done
  if (( ${#cache_keys} == 0 )); then
    echo "!! No cluster cache, so nothing is known to be stale." >&2
    echo "   Run 'kon eks --discover' first; pruning without it could delete live entries." >&2
    return 1
  fi

  ctx_rows=(${(f)"$(kubectl config view -o json 2>/dev/null | _kon_registry_from_json)"})
  for row in "${ctx_rows[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    key="${account}/${cname}"
    if (( ${seen[(Ie)$key]} )); then
      drop_ctx+=("$ctx"); drop_key+=("duplicate of another context for ${cname}")
      continue
    fi
    seen+=("$key")
    if ! (( ${cache_keys[(Ie)$key]} )); then
      drop_ctx+=("$ctx"); drop_key+=("${cname} is not in the cluster cache any more")
    fi
  done

  if (( ${#drop_ctx} == 0 )); then
    echo ">> Nothing to prune: every EKS context matches a discovered cluster."
    return 0
  fi

  echo "The following kubeconfig entries would be removed:"
  local i
  for (( i = 1; i <= ${#drop_ctx}; i++ )); do
    echo "   ${drop_ctx[i]}  (${drop_key[i]})"
  done
  printf 'Remove them? [y/N] '
  read -r reply
  [[ "$reply" == [yY]* ]] || { echo ">> Left untouched."; return 0 }

  for row in "${ctx_rows[@]}"; do
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    (( ${drop_ctx[(Ie)$ctx]} )) || continue
    kubectl config delete-context "$ctx" >/dev/null 2>&1 \
      && echo ">> Removed context ${ctx}"
    if ! kubectl config view -o json 2>/dev/null \
         | _kon_registry_from_json | cut -f2 | grep -qx -- "$ckey"; then
      kubectl config delete-cluster "$ckey" >/dev/null 2>&1
      kubectl config delete-user "$ckey" >/dev/null 2>&1
    fi
  done
  return 0
}

_kon_rds_cache_rows() {
  emulate -L zsh
  [[ -r "$KON_RDS_CACHE" ]] || return 0
  grep -v -e '^#' -e '^$' -- "$KON_RDS_CACHE" 2>/dev/null
}

_kon_rds_discover() {
  emulate -L zsh
  local only_profile="$1"
  local -a prows out keep
  local row p acct preg line id engine ep port memberof found=0 known=0
  local kdb keng kacct kreg kprof kep kport kvpc

  prows=(${(f)"$(_kon_profiles)"})
  if (( ${#prows} == 0 )); then
    echo "!! No profile on sso_session '${_KON_SSO_SESSION}' in ${KON_AWS_CONFIG}" >&2
    return 1
  fi

  if [[ -n "$only_profile" ]]; then
    for row in "${prows[@]}"; do
      [[ "$row" == "$only_profile"$'\t'* ]] && known=1
    done
    (( known )) || {
      echo "!! No profile '${only_profile}' on sso_session '${_KON_SSO_SESSION}'" >&2
      return 1
    }
  fi

  IFS=$'\t' read -r p acct preg <<< "${prows[1]}"
  _kon_ensure_sso "${only_profile:-$p}" || return 1

  for row in "${prows[@]}"; do
    IFS=$'\t' read -r p acct preg <<< "$row"
    [[ -n "$only_profile" && "$p" != "$only_profile" ]] && continue
    if [[ "$preg" == "-" || -z "$preg" ]]; then
      preg="$(aws configure get region --profile "$p" 2>/dev/null)"
      : "${preg:=${AWS_DEFAULT_REGION:-}}"
    fi
    if [[ -z "$preg" ]]; then
      echo "   ${p} (${acct}): no region configured - skipped" >&2
      continue
    fi

    typeset -A vpcof
    vpcof=()
    local -a standalone
    local ivpc rest
    for line in ${(f)"$(aws rds describe-db-instances \
          --profile "$p" --region "$preg" \
          --query 'DBInstances[].[DBInstanceIdentifier,Engine,Endpoint.Address,Endpoint.Port,DBClusterIdentifier,DBSubnetGroup.VpcId]' \
          --output text 2>/dev/null)"}; do
      IFS=$'\t' read -r id engine ep port memberof ivpc <<< "$line"
      [[ "$ivpc" == "None" || -z "$ivpc" ]] && ivpc="-"
      if [[ "$memberof" != "None" && -n "$memberof" ]]; then
        vpcof[$memberof]="$ivpc"
        continue
      fi
      [[ -n "$id" && "$ep" != "None" && -n "$ep" ]] || continue
      standalone+=("${id}	${engine}	${acct}	${preg}	${p}	${ep}	${port}	${ivpc}")
    done

    for line in ${(f)"$(aws rds describe-db-clusters \
          --profile "$p" --region "$preg" \
          --query 'DBClusters[].[DBClusterIdentifier,Engine,Endpoint,Port]' \
          --output text 2>/dev/null)"}; do
      IFS=$'\t' read -r id engine ep port <<< "$line"
      [[ -n "$id" && "$ep" != "None" && -n "$ep" ]] || continue
      out+=("${id}	${engine}	${acct}	${preg}	${p}	${ep}	${port}	${vpcof[$id]:--}")
      found=$((found + 1))
      echo "   ${p}: + ${id} (${engine}, cluster)"
    done

    for line in "${standalone[@]}"; do
      out+=("$line")
      found=$((found + 1))
      IFS=$'\t' read -r id engine rest <<< "$line"
      echo "   ${p}: + ${id} (${engine}, instance)"
    done
  done

  if (( found == 0 )) && [[ -z "$only_profile" ]]; then
    echo ">> Discover: no database found."
    return 0
  fi

  if [[ -n "$only_profile" ]]; then
    for row in ${(f)"$(_kon_rds_cache_rows)"}; do
      IFS=$'\t' read -r kdb keng kacct kreg kprof kep kport kvpc <<< "$row"
      [[ "$kprof" == "$only_profile" ]] && continue
      keep+=("$row")
    done
  fi

  mkdir -p -- "${KON_RDS_CACHE:h}" || return 1
  {
    echo "# written by kon rds --discover on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# db_id	engine	account	region	profile	endpoint	port	vpc"
    print -rl -- "${keep[@]}" "${out[@]}"
  } >| "${KON_RDS_CACHE}.tmp" || return 1
  mv -f -- "${KON_RDS_CACHE}.tmp" "$KON_RDS_CACHE" || return 1
  echo ">> Discover: ${found} database(s) recorded in ${KON_RDS_CACHE}"
  return 0
}

_kon_rds_registry() {
  emulate -L zsh
  local nodiscover="$1"
  local -a rows
  rows=(${(f)"$(_kon_rds_cache_rows)"})
  if (( ${#rows} == 0 )) && [[ -z "$nodiscover" ]]; then
    echo ">> No database cached yet - discovering (kon rds --discover to refresh)" >&2
    _kon_rds_discover >&2 || return 1
    rows=(${(f)"$(_kon_rds_cache_rows)"})
  fi
  (( ${#rows} )) || return 1
  print -rl -- "${rows[@]}"
}

_kon_rds_state_label() {
  emulate -L zsh
  local port="$1" db_id="$2"
  [[ "$port" == <-> ]] || { print -r -- "down"; return }
  _kon_port_busy "$port" || { print -r -- "down"; return }
  if _kon_tunnel_live "$port" "$db_id" 'rds.amazonaws.com'; then
    print -r -- "up:${port}"
  else
    print -r -- "down"
  fi
}

_kon_rds_select() {
  emulate -L zsh
  local want="$1" want_profile="$2"
  local -a all hits lines profiles
  local row id engine account region profile ep rport dbvpc state pick p seen count

  all=(${(f)"$(_kon_rds_registry | sort -t$'\t' -k5,5 -k1,1)"}) || return 1
  if (( ${#all} == 0 )); then
    echo "!! No database known. Try: kon rds --discover" >&2
    return 1
  fi

  if [[ -n "$want_profile" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
      [[ "$profile" == "$want_profile" || "$profile" == ${want_profile}* ]] && hits+=("$row")
    done
    if (( ${#hits} == 0 )); then
      echo "!! No database cached for profile '${want_profile}'. Try: kon rds --discover" >&2
      return 1
    fi
    all=("${hits[@]}")
    hits=()
  fi

  if [[ -n "$want" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
      [[ "$id" == "$want" ]] && hits+=("$row")
    done
    if (( ${#hits} == 0 )); then
      for row in "${all[@]}"; do
        IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
        [[ "$id" == ${want}* || "$profile" == ${want}* ]] && hits+=("$row")
      done
    fi
    if (( ${#hits} == 0 )); then
      for row in "${all[@]}"; do
        IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
        [[ "$id" == *${want}* || "$profile" == *${want}* ]] && hits+=("$row")
      done
    fi
    if (( ${#hits} == 0 )); then
      echo "!! No database matches '${want}'. Known:" >&2
      for row in "${all[@]}"; do
        IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
        echo "     ${profile}  ${id}" >&2
      done
      return 1
    fi
  else
    for row in "${all[@]}"; do
      IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
      (( ${profiles[(Ie)$profile]} )) || profiles+=("$profile")
    done
    if (( ${#profiles} > 1 )); then
      if ! _kon_fzf_ok; then
        echo "!! Several accounts hold databases; name one with -p, or a database directly:" >&2
        for p in "${profiles[@]}"; do
          count=0
          for row in "${all[@]}"; do
            IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
            [[ "$profile" == "$p" ]] && count=$((count + 1))
          done
          echo "     ${p} (${count})" >&2
        done
        return 1
      fi
      lines=()
      for p in "${profiles[@]}"; do
        count=0; seen=""
        for row in "${all[@]}"; do
          IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
          [[ "$profile" == "$p" ]] || continue
          count=$((count + 1)); seen="$account"
        done
        lines+=("$(printf '%-18s %-15s %s' "$p" "$seen" "${count} database(s)")")
      done
      pick="$(print -rl -- "${lines[@]}" \
        | fzf --height=40% --reverse --prompt='account> ' \
              --header='kon: pick the account, then the database' \
        | awk '{print $1}')"
      [[ -n "$pick" ]] || { echo "!! Nothing selected" >&2; return 1 }
      for row in "${all[@]}"; do
        IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
        [[ "$profile" == "$pick" ]] && hits+=("$row")
      done
    else
      hits=("${all[@]}")
    fi
  fi

  if (( ${#hits} == 1 )); then
    print -r -- "${hits[1]}"
    return 0
  fi

  if ! _kon_fzf_ok; then
    echo "!! Ambiguous and there is no terminal for a picker. Candidates:" >&2
    for row in "${hits[@]}"; do
      IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
      echo "     ${profile}  ${id}" >&2
    done
    return 1
  fi

  lines=()
  for row in "${hits[@]}"; do
    IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
    state="$(_kon_rds_state_label "$(_kon_desired_port "${account}/${id}" rds)" "$id")"
    lines+=("${account}/${region}/${id}"$'\t'"$(printf '%-34s %-18s %-16s %-15s %s' \
      "$id" "$engine" "$profile" "$region" "$state")")
  done

  pick="$(print -rl -- "${lines[@]}" \
    | fzf --height=40% --reverse --prompt='database> ' \
          --delimiter=$'\t' --with-nth=2.. \
          --header='kon: pick a database (name / engine / profile / region / tunnel)' \
    | cut -f1)"
  [[ -n "$pick" ]] || { echo "!! Nothing selected" >&2; return 1 }

  for row in "${hits[@]}"; do
    IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
    [[ "$pick" == "${account}/${region}/${id}" ]] && { print -r -- "$row"; return 0 }
  done
  return 1
}

_kon_rds_status() {
  emulate -L zsh
  local profile_filter="$1"
  local row id engine account region profile ep rport dbvpc port orphan
  local -a all ids keep
  all=(${(f)"$(_kon_rds_registry nodiscover | sort -t$'\t' -k5,5 -k1,1)"})
  if [[ -n "$profile_filter" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
      [[ "$profile" == "$profile_filter" || "$profile" == ${profile_filter}* ]] && keep+=("$row")
    done
    all=("${keep[@]}")
  fi
  if (( ${#all} == 0 )); then
    echo "No database cached${profile_filter:+ for '$profile_filter'}. Try: kon rds --discover"
    return 0
  fi
  printf '%-2s %-34s %-18s %-16s %-15s %-8s %s\n' \
    "" "DATABASE" "ENGINE" "PROFILE" "REGION" "PORT" "TUNNEL"
  for row in "${all[@]}"; do
    IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
    ids+=("$id")
    port="$(_kon_desired_port "${account}/${id}" rds)"
    printf '%-2s %-34s %-18s %-16s %-15s %-8s %s\n' \
      "" "$id" "$engine" "$profile" "$region" "$port" \
      "$(_kon_rds_state_label "$port" "$id")"
  done
  orphan="$(_kon_rds_orphan_tunnels "${ids[@]}")"
  [[ -n "$orphan" ]] && { echo; echo "Tunnels unknown to the cache:"; print -rn -- "$orphan" }
  return 0
}

_kon_rds_stop() {
  emulate -L zsh
  local want="$1" profile_filter="$2" row id engine account region profile ep rport dbvpc port stopped=0 orphan
  local -a all hits ids

  all=(${(f)"$(_kon_rds_registry nodiscover)"})
  if [[ -n "$profile_filter" ]]; then
    for row in "${all[@]}"; do
      IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
      [[ "$profile" == "$profile_filter" || "$profile" == ${profile_filter}* ]] && hits+=("$row")
    done
    all=("${hits[@]}")
    hits=()
  fi
  for row in "${all[@]}"; do
    IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
    ids+=("$id")
  done

  if [[ -n "$want" ]]; then
    row="$(_kon_rds_select "$want" "$profile_filter")" || return 1
    hits=("$row")
  else
    hits=("${all[@]}")
  fi

  for row in "${hits[@]}"; do
    IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
    port="$(_kon_desired_port "${account}/${id}" rds)"
    _kon_port_busy "$port" || continue
    if ! _kon_tunnel_live "$port" "$id" 'rds.amazonaws.com'; then
      echo ">> Skipped ${id}: 127.0.0.1:${port} is not this database's tunnel"
      continue
    fi
    if _kon_kill_port "$port"; then
      echo ">> Stopped ${id} (127.0.0.1:${port})"
      stopped=$((stopped + 1))
    else
      echo "!! Could not stop ${id} (127.0.0.1:${port})" >&2
    fi
  done

  (( stopped )) || echo ">> No database tunnel to stop${want:+ for '$want'}"
  orphan="$(_kon_rds_orphan_tunnels "${ids[@]}")"
  [[ -n "$orphan" ]] && { echo ">> Still running (unknown to the cache):"; print -rn -- "$orphan" }
  return 0
}

_kon_rds_connect() {
  emulate -L zsh
  local want="$1" timeout="${2:-180}" port_override="$3" bastion_pin="$4" profile_filter="$5"
  local row id engine account region profile ep rport dbvpc instance_id chosen

  row="$(_kon_rds_select "$want" "$profile_filter")" || return 1
  IFS=$'\t' read -r id engine account region profile ep rport dbvpc <<< "$row"
  [[ "$rport" == <-> ]] || rport=5432

  echo ">> Database: ${id}  (${engine}, ${account} / ${region})"
  echo ">> Profile : ${profile}"

  _kon_ensure_sso "$profile" || return 1
  export AWS_PROFILE="$profile"
  export AWS_REGION="$region"
  export AWS_DEFAULT_REGION="$region"

  instance_id="$(_kon_jump_host "$account" "$region" "$profile" "$bastion_pin" \
                                "$id" "${id%-*}" "$dbvpc")" || return 1
  echo ">> Jump    : ${instance_id}"

  if [[ -n "$port_override" ]]; then
    chosen="$port_override"
    if _kon_port_busy "$chosen" && ! _kon_tunnel_live "$chosen" "$id" 'rds.amazonaws.com'; then
      echo "!! Port ${chosen} is held by something that is not this database's tunnel." >&2
      echo "   Drop --local-port to use the derived port instead." >&2
      return 1
    fi
  else
    chosen="$(_kon_resolve_port "${account}/${id}" "$id" '' rds 'rds.amazonaws.com')" || {
      echo "!! No free port in ${KON_RDS_PORT_BASE}-$((KON_RDS_PORT_BASE + KON_RDS_PORT_SPAN - 1))" >&2
      return 1
    }
  fi

  if _kon_tunnel_live "$chosen" "$id" 'rds.amazonaws.com'; then
    echo ">> Tunnel  : already up on 127.0.0.1:${chosen} -> ${ep}:${rport}"
  else
    echo ">> Tunnel  : 127.0.0.1:${chosen} -> ${ep}:${rport} via ${instance_id}"
    _kon_start_tunnel "$region" "$profile" "$instance_id" "$ep" \
                      "$rport" "$chosen" "$timeout" kon-rds || return 1
    echo ">> Tunnel  : ready"
  fi

  case "$engine" in
    *postgres*) echo ">> Try     : psql -h 127.0.0.1 -p ${chosen} -U <user> -d <database>" ;;
    *mysql*|*maria*) echo ">> Try     : mysql -h 127.0.0.1 -P ${chosen} -u <user> -p" ;;
    *) echo ">> Ready   : 127.0.0.1:${chosen}" ;;
  esac
  return 0
}

_kon_bastion_status() {
  emulate -L zsh
  local row a r v n
  local -a all
  all=(${(f)"$(_kon_jump_cache_rows | sort -t$'\t' -k1,1)"})
  if (( ${#all} == 0 )); then
    echo "No jump host remembered yet. One is chosen and stored on first connect."
    return 0
  fi
  printf '%-16s %-16s %-24s %s\n' "ACCOUNT" "REGION" "VPC" "JUMP HOST"
  for row in "${all[@]}"; do
    IFS=$'\t' read -r a r v n <<< "$(_kon_jump_cache_split "$row")"
    printf '%-16s %-16s %-24s %s\n' "$a" "$r" "$v" "$n"
  done
  echo
  echo "Names are resolved to a live instance id on every connect, so a replaced"
  echo "instance needs no action here. 'kon bastion' changes a choice."
  return 0
}

_kon_bastion_choose() {
  emulate -L zsh
  local want="$1"
  local -a prows rows
  local row p acct preg picked id name vpc

  prows=(${(f)"$(_kon_profiles)"})
  if (( ${#prows} == 0 )); then
    echo "!! No profile on sso_session '${_KON_SSO_SESSION}' in ${KON_AWS_CONFIG}" >&2
    return 1
  fi

  if [[ -z "$want" ]]; then
    want="${AWS_PROFILE:-}"
  fi
  if [[ -z "$want" ]]; then
    echo "!! Which account? Pass a profile name, or set AWS_PROFILE." >&2
    echo "   Known: $(print -r -- ${(j:, :)${(f)$(_kon_profiles | cut -f1)}})" >&2
    return 1
  fi

  for row in "${prows[@]}"; do
    IFS=$'\t' read -r p acct preg <<< "$row"
    [[ "$p" == "$want" ]] && break
    p=""
  done
  if [[ -z "$p" ]]; then
    echo "!! No profile named '${want}' on the SSO session" >&2
    return 1
  fi
  if [[ "$preg" == "-" || -z "$preg" ]]; then
    preg="$(aws configure get region --profile "$p" 2>/dev/null)"
    : "${preg:=${AWS_DEFAULT_REGION:-}}"
  fi
  [[ -n "$preg" ]] || { echo "!! No region for profile '${p}'" >&2; return 1 }

  _kon_ensure_sso "$p" || return 1

  rows=(${(f)"$(_kon_jump_candidates "$preg" "$p")"})
  if (( ${#rows} == 0 )); then
    echo "!! Nothing in ${p}/${preg} is SSM-managed and not a cluster node." >&2
    return 1
  fi

  echo ">> Account : ${acct} (${p} / ${preg})"
  if (( ${#rows} == 1 )); then
    IFS=$'\t' read -r id name vpc <<< "${rows[1]}"
    picked="$name"
    echo ">> Only one candidate: ${name} (${id})"
  else
    row="$(_kon_jump_pick "${p}" "${rows[@]}")" || return 1
    IFS=$'\t' read -r id picked vpc <<< "$row"
  fi
  _kon_jump_cache_set "$acct" "$preg" "$picked" || return 1
  echo ">> Remembered ${picked} for ${acct}/${preg}"
  return 0
}

_kon_help() {
  cat <<'EOF'
kon - reach a private cluster or database in one command

  kon                      pick a cluster interactively (fzf)
  kon CLUSTER              connect (exact, then prefix, then substring match)
  kon --status             every cluster AND database, with its port and tunnel
  kon --stop [NAME]        stop one tunnel, or all of them
  kon --discover [PROFILE] scan every SSO profile for clusters and cache them
  kon --prune              drop kubeconfig entries for clusters that are gone
  kon --update             update the way it was installed (git pull, apt, brew)
  kon doctor               check what kon needs and name what is missing
  kon --version / --help

The target type is an optional first word. It defaults to eks, so everything
above is shorthand for `kon eks ...`; `eks`, `rds` and `doctor` are reserved names.

  kon eks [CLUSTER]        same as above, said explicitly
  kon eks --status         clusters only
  kon eks --stop [CLUSTER]
  kon eks --prune          same as kon --prune

  kon rds                  pick a database (fzf)
  kon rds NAME             connect to it
  kon rds --status         databases only
  kon rds --stop [NAME]
  kon rds --discover [PROFILE]
                           ask AWS what databases exist and cache the answer

  kon bastion [PROFILE]    choose the instance to tunnel through for an account
  kon bastion --status     what is remembered, per account and region
  kon bastion --forget [ACCOUNT]
                           drop a remembered choice, or all of them

Options
  -l, --local-port PORT    force the local port instead of the derived one
  -t, --timeout SEC        tunnel readiness timeout (default 180)
  -b, --bastion NAME|i-ID  pin the instance to jump through, once
  -p, --profile PROFILE    scope rds to one account

Ports
  Every target gets a port derived from its identity - FNV-1a of
  <account>/<name> - so it is the same in every shell and every day, whatever
  order you connect in, and many tunnels coexist. Clusters land in 18000-18999
  and databases in 19000-19999, so the port alone tells you the target type.
  `kon --status` prints the map.

Where the target list comes from
  Both sides cache what AWS reports, so picking, --status and --stop make no AWS
  call. --discover is read-only: it writes only the cache. A cluster is added to
  the kubeconfig the first time you connect to it, because registering every
  cluster in every account up front fills that file with entries you never use.
  In --status, + marks a cluster kon knows about that kubectl does not yet.
  --prune removes kubeconfig entries whose cluster no longer exists, and extra
  contexts for a cluster another context already covers. It only ever considers
  arn:aws:eks: entries, and asks before removing anything.

Which instance it jumps through
  A port-forward needs an instance registered with SSM, and that, not its name,
  is the requirement. A candidate is a running instance that is SSM-managed and
  is NOT tagged as a Kubernetes cluster node, which across all seven accounts
  here leaves exactly one: the bastion. Worker nodes are SSM-managed too, so
  that exclusion is what makes the test work.

  A name is never looked up. When several candidates survive, they are ranked by
  KON_JUMP_WORDS in order (default: bastion jump jumpbox jumphost, matched case
  insensitively anywhere in the name), then by the cluster or database stem. A
  ranking tier that would leave nothing is skipped, so a hint can narrow but
  never eliminate the right answer.

  Genuine ambiguity is asked once and remembered in KON_JUMP_CACHE, keyed by
  account and region, storing the Name TAG rather than the instance id, so a
  replaced instance keeps working. `kon bastion` revisits the choice.

What a cluster connect does, all idempotent:
  resolve cluster -> derive the AWS profile from the kubeconfig/account id
  -> refresh SSO if the cached token expired -> export AWS_PROFILE/AWS_REGION
  -> switch kube context -> find the jump host -> derive the port
  -> point kubeconfig at 127.0.0.1:PORT with tls-server-name
  -> start the SSM port-forward -> export TF_VAR_kubernetes_host_override when
  /etc/hosts allows -> check /readyz.
EOF
}

_kon_eks_connect() {
  emulate -L zsh
  local want="$1" timeout="${2:-180}" port_override="$3" bastion_pin="$4"
  local row ctx ckey region account cname profile port host
  local instance_id eks_host chosen

  row="$(_kon_select "$want")" || return 1
  IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"

  [[ "$profile" == "-" ]] && profile="$(_kon_profile_for_account "$account")"
  if [[ -z "$profile" || "$profile" == "-" ]]; then
    echo "!! No AWS profile maps to account ${account} (cluster ${cname})." >&2
    echo "   Add a [profile ...] with sso_account_id = ${account} to ~/.aws/config" >&2
    return 1
  fi

  echo ">> Cluster : ${cname}  (${account} / ${region})"

  if [[ "$ctx" == "-" ]]; then
    echo ">> Register: adding ${cname} to the kubeconfig (first connect)"
    ctx="$(_kon_eks_register "$region" "$profile" "$cname" "$account")" || return 1
    row="$(_kon_select "$cname" "" "$account")" || return 1
    IFS=$'\t' read -r ctx ckey region account cname profile port host <<< "$row"
    [[ "$profile" == "-" ]] && profile="$(_kon_profile_for_account "$account")"
  fi

  echo ">> Profile : ${profile}   Context: ${ctx}"

  _kon_ensure_sso "$profile" || return 1

  export AWS_PROFILE="$profile"
  export AWS_REGION="$region"
  export AWS_DEFAULT_REGION="$region"

  if [[ "$(kubectl config current-context 2>/dev/null)" != "$ctx" ]]; then
    kubectl config use-context "$ctx" >/dev/null || return 1
  fi

  local eks_vpc
  IFS=$'\t' read -r eks_host eks_vpc <<< "$(_kon_eks_host "$region" "$profile" "$cname")"
  [[ -n "$eks_host" ]] || return 1
  instance_id="$(_kon_jump_host "$account" "$region" "$profile" "$bastion_pin" \
                                "$cname" "${cname%$KON_CLUSTER_SUFFIX}" "$eks_vpc")" || return 1
  echo ">> Jump    : ${instance_id}"

  if [[ -n "$port_override" ]]; then
    chosen="$port_override"
    if _kon_port_busy "$chosen" && ! _kon_tunnel_live "$chosen" "$eks_host"; then
      echo "!! Port ${chosen} is held by something that is not this cluster's tunnel." >&2
      echo "   Drop --local-port to use the derived port instead." >&2
      return 1
    fi
  else
    chosen="$(_kon_resolve_port "${account}/${cname}" "$eks_host" "$port")" || {
      echo "!! No free port in ${KON_PORT_BASE}-$((KON_PORT_BASE + KON_PORT_SPAN - 1))" >&2
      return 1
    }
  fi

  _kon_set_cluster_endpoint "$chosen" "$eks_host" || return 1

  if _kon_tunnel_live "$chosen" "$eks_host"; then
    echo ">> Tunnel  : already up on 127.0.0.1:${chosen} -> ${eks_host}:443"
  else
    echo ">> Tunnel  : 127.0.0.1:${chosen} -> ${eks_host}:443 via ${instance_id}"
    _kon_start_tunnel "$region" "$profile" "$instance_id" "$eks_host" \
                      443 "$chosen" "$timeout" kon || return 1
    echo ">> Tunnel  : ready"
  fi

  if _kon_hosts_has "$eks_host" || _kon_hosts_entry "$eks_host" "$cname"; then
    export TF_VAR_kubernetes_host_override="https://${eks_host}:${chosen}"
    echo ">> TF var  : TF_VAR_kubernetes_host_override=${TF_VAR_kubernetes_host_override}"
  else
    unset TF_VAR_kubernetes_host_override
  fi

  (( $+functions[_kon_cloud_set] )) && _kon_cloud_set "$region"

  _kon_healthcheck || return 1
  echo ">> Ready   : k get po"
  return 0
}

_kon_version_of() {
  emulate -L zsh
  local root="${1:-$_KON_HOME}" v="unknown"
  [[ -r "${root}/VERSION" ]] && v="$(<"${root}/VERSION")"
  print -r -- "${v//[[:space:]]/}"
}

_kon_version() {
  emulate -L zsh
  local v desc=""
  v="$(_kon_version_of "$_KON_HOME")"

  if [[ "$(git -C "$_KON_HOME" rev-parse --show-toplevel 2>/dev/null)" == "${_KON_HOME:A}" ]]; then
    desc="$(git -C "$_KON_HOME" describe --tags --always --dirty 2>/dev/null)"
    [[ -n "$desc" && "$desc" != "$v" && "$desc" != "v$v" ]] && v="${v} (git: ${desc})"
  fi
  print -r -- "kon ${v}"
}

_kon_doctor() {
  emulate -L zsh
  local f='>> %-8s : %s\n'
  local -a missing
  local -i zmaj=${ZSH_VERSION%%.*} zmin
  zmin="${${ZSH_VERSION#*.}%%.*}"
  [[ "$zmin" == <-> ]] || zmin=0

  if (( zmaj >= 5 )); then
    printf "$f" zsh "${ZSH_VERSION} (needs 5.0 or newer)"
  else
    printf "$f" zsh "${ZSH_VERSION} (too old, needs 5.0 or newer)"
    missing+=("zsh 5.0+")
  fi

  local kv init_path note
  kv="$(_kon_version_of)"
  init_path="${_KON_HOME}/init.zsh"
  if [[ -r "$init_path" ]]; then
    note="$init_path (kon ${kv})"
  else
    note="${_KON_HOME} is gone (kon ${kv})"
    missing+=("a checkout at ${_KON_HOME}")
  fi
  (( $+functions[_kon_cloud_refresh] )) || note+=", prompt.zsh not loaded"
  if [[ -o promptsubst ]]; then
    note+=", prompt_subst on"
  else
    note+=", prompt_subst off"
  fi
  if (( $+functions[compdef] )); then
    note+=", compdef loaded"
  else
    note+=", compdef not loaded"
  fi
  printf "$f" init "$note"

  local abin aver amaj
  abin="$(whence -p aws 2>/dev/null)"
  if [[ -z "$abin" ]]; then
    printf "$f" aws "not on PATH"
    missing+=("awscli v2")
  else
    aver="$("$abin" --version 2>&1)"
    aver="${aver%%$'\n'*}"
    aver="${${aver%% *}#aws-cli/}"
    amaj="${aver%%.*}"
    if [[ "$amaj" == 2 ]]; then
      printf "$f" aws "${aver} at ${abin} (v2)"
    elif [[ "$amaj" == <-> ]]; then
      printf "$f" aws "${aver} at ${abin} (v1, SSO needs v2)"
      missing+=("awscli v2")
    else
      printf "$f" aws "version unknown at ${abin}"
    fi
  fi

  local sbin sver
  sbin="$(whence -p session-manager-plugin 2>/dev/null)"
  if [[ -z "$sbin" ]]; then
    printf "$f" plugin "session-manager-plugin not on PATH (aws ssm start-session would time out)"
    missing+=("session-manager-plugin")
  else
    sver="$("$sbin" --version 2>&1)"
    sver="${sver%%$'\n'*}"
    if [[ -n "$sver" ]]; then
      printf "$f" plugin "${sver} at ${sbin}, on PATH for aws"
    else
      printf "$f" plugin "${sbin} does not run (aws cannot exec it)"
      missing+=("session-manager-plugin")
    fi
  fi

  local kbin kver
  kbin="$(whence -p kubectl 2>/dev/null)"
  if [[ -z "$kbin" ]]; then
    printf "$f" kubectl "not on PATH"
    missing+=("kubectl")
  else
    kver="$("$kbin" version --client 2>/dev/null)"
    kver="${kver%%$'\n'*}"
    kver="${kver#Client Version: }"
    printf "$f" kubectl "${kver:-version unknown} at ${kbin}"
  fi

  local pver
  if [[ -z "$KON_PYTHON" ]]; then
    printf "$f" python3 "not found on PATH (set KON_PYTHON)"
    missing+=("python3")
  elif [[ ! -x "$KON_PYTHON" ]]; then
    printf "$f" python3 "${KON_PYTHON} is not executable (set KON_PYTHON)"
    missing+=("python3")
  else
    pver="$("$KON_PYTHON" --version 2>&1)"
    pver="${pver%%$'\n'*}"
    if [[ -n "$pver" ]]; then
      printf "$f" python3 "${KON_PYTHON} (${pver})"
    else
      printf "$f" python3 "${KON_PYTHON} does not run (set KON_PYTHON)"
      missing+=("python3")
    fi
  fi

  local fbin fver
  fbin="$(whence -p fzf 2>/dev/null)"
  if [[ -z "$fbin" ]]; then
    printf "$f" fzf "not on PATH (optional, the picker becomes a listing)"
  else
    fver="$("$fbin" --version 2>/dev/null)"
    fver="${fver%%$'\n'*}"
    printf "$f" fzf "${fver:-version unknown} at ${fbin}"
  fi

  local lbin tcp
  lbin="$(whence -p lsof 2>/dev/null)"
  if zmodload -F zsh/net/tcp b:ztcp 2>/dev/null; then
    tcp="zsh/net/tcp available"
  else
    tcp="zsh/net/tcp unavailable"
    missing+=("zsh/net/tcp")
  fi
  if [[ -z "$lbin" ]]; then
    printf "$f" tools "lsof not on PATH, ${tcp}"
    missing+=("lsof")
  else
    printf "$f" tools "lsof at ${lbin}, ${tcp}"
  fi

  local cfg="$KON_AWS_CONFIG" line prows
  local -i nsso=0 nprof=0
  local -a clines
  if [[ ! -r "$cfg" ]]; then
    printf "$f" "aws cfg" "${cfg} not found"
    missing+=("aws config at ${cfg}")
  else
    clines=("${(@f)$(<"$cfg")}")
    for line in "${clines[@]}"; do
      [[ "$line" == "[sso-session "* ]] && (( nsso += 1 ))
    done
    if [[ -n "$KON_PYTHON" && -x "$KON_PYTHON" ]]; then
      prows="$(_kon_profiles 2>/dev/null)"
      [[ -n "$prows" ]] && nprof="${#${(f)prows}}"
      if (( nsso == 0 )); then
        printf "$f" "aws cfg" "${cfg}, no [sso-session], ${nprof} profiles"
        missing+=("an [sso-session] in ${cfg}")
      elif (( nsso > 1 )) && [[ -z "$KON_SSO_SESSION" ]]; then
        printf "$f" "aws cfg" "${cfg}, ${nsso} [sso-session], ${nprof} profiles (set KON_SSO_SESSION)"
        missing+=("KON_SSO_SESSION (${nsso} [sso-session])")
      elif (( nprof == 0 )); then
        printf "$f" "aws cfg" "${cfg}, ${nsso} [sso-session], no profile"
        missing+=("a [profile] on the sso session")
      else
        printf "$f" "aws cfg" "${cfg}, ${nsso} [sso-session], ${nprof} profiles"
      fi
    else
      printf "$f" "aws cfg" "${cfg}, ${nsso} [sso-session], profiles unknown (python3 missing)"
    fi
  fi

  local sdir="${KON_EKS_CACHE:h}" t cname acct region prof dbid engine ep rport thost tmatch port
  local -a crows drows targets
  local -i pfree=0 pkon=0 pother=0
  crows=(${(f)"$(_kon_eks_cache_rows)"})
  drows=(${(f)"$(_kon_rds_cache_rows)"})
  for t in "${crows[@]}"; do
    IFS=$'\t' read -r cname acct region prof <<< "$t"
    targets+=("$(_kon_desired_port "${acct}/${cname}")"$'\t'"-"$'\t'"-")
  done
  for t in "${drows[@]}"; do
    IFS=$'\t' read -r dbid engine acct region prof ep rport <<< "$t"
    targets+=("$(_kon_desired_port "${acct}/${dbid}" rds)"$'\t'"${dbid}"$'\t'rds.amazonaws.com)
  done
  if [[ -d "$sdir" ]]; then
    local ports="nothing cached yet (kon --discover fills it)"
    if (( ${#targets} )); then
      if [[ -n "$lbin" ]]; then
        for t in "${targets[@]}"; do
          IFS=$'\t' read -r port thost tmatch <<< "$t"
          if ! _kon_port_busy "$port"; then
            (( pfree += 1 ))
          elif [[ "$thost" == "-" ]]; then
            if _kon_listener_is_ssm "$port"; then (( pkon += 1 )); else (( pother += 1 )); fi
          else
            if _kon_tunnel_live "$port" "$thost" "$tmatch"; then (( pkon += 1 )); else (( pother += 1 )); fi
          fi
        done
        ports="${pfree} free, ${pkon} in use by kon, ${pother} in use by something else"
      else
        ports="not checked, lsof is missing"
      fi
    fi
    printf "$f" state "${sdir}, clusters ${#crows}, databases ${#drows}, ports ${ports}"
  else
    printf "$f" state "${sdir} absent, nothing cached yet (kon --discover fills it)"
  fi

  if [[ -w /etc/hosts ]]; then
    printf "$f" sudo "/etc/hosts is writable without sudo (only Terraform needs the entry)"
  else
    printf "$f" sudo "/etc/hosts needs sudo (only Terraform needs the entry)"
  fi

  if (( ${#missing} == 0 )); then
    print -r -- ">> all required pieces present"
    return 0
  fi

  local -a cmd
  local ids
  case "$OSTYPE" in
    darwin*)
      for t in "${missing[@]}"; do
        case "$t" in
          "awscli v2")              cmd+=("brew install awscli") ;;
          "session-manager-plugin") cmd+=("brew install --cask session-manager-plugin") ;;
          "kubectl")                cmd+=("brew install kubectl") ;;
          "python3")                cmd+=("brew install python") ;;
          "lsof")                   cmd+=("brew install lsof") ;;
          "zsh 5.0+")               cmd+=("brew install zsh") ;;
        esac
      done ;;
    linux*)
      [[ -r /etc/os-release ]] && ids="$(</etc/os-release)"
      if [[ "$ids" == *ID=debian* || "$ids" == *ID=ubuntu* || "$ids" == *ID_LIKE=*debian* || "$ids" == *ID_LIKE=*ubuntu* ]]; then
        for t in "${missing[@]}"; do
          case "$t" in
            "python3")  cmd+=("sudo apt install python3") ;;
            "lsof")     cmd+=("sudo apt install lsof") ;;
            "zsh 5.0+") cmd+=("sudo apt install zsh") ;;
          esac
        done
      fi ;;
  esac
  local fix=""
  (( ${#cmd} )) && fix=" - install with: ${(j: && :)cmd}"
  print -r -- "!! missing: ${(j:, :)missing}${fix}"
  return 1
}

_kon_update() {
  emulate -L zsh
  local root="${1:-$_KON_HOME}"
  local before after vbefore vafter branch out
  local -i rc

  if [[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" != "${root:A}" ]]; then
    if [[ "${root:A}" == /usr/share/kon ]]; then
      echo "!! ${root} comes from the .deb package; git is not how it updates." >&2
      echo "   Upgrade with: sudo apt install --only-upgrade kon" >&2
      echo "   Then reload the shell: exec zsh" >&2
      return 1
    fi
    if [[ "${root:A}" == */Cellar/* || "${root:A}" == /opt/homebrew/* ]]; then
      echo "!! ${root} comes from Homebrew; git is not how it updates." >&2
      echo "   Upgrade with: brew upgrade kon" >&2
      echo "   Then reload the shell: exec zsh" >&2
      return 1
    fi
    echo "!! ${root} is not a git checkout, so there is nothing to pull." >&2
    echo "   Clone the repo and re-run scripts/install.zsh to switch to one." >&2
    return 1
  fi

  if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    echo "!! ${root} has uncommitted changes; refusing to pull over them." >&2
    git -C "$root" status --short >&2
    echo "   Commit them on a branch, or stash them, then retry." >&2
    return 1
  fi

  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  before="$(git -C "$root" rev-parse HEAD)"
  vbefore="$(_kon_version_of "$root")"
  echo ">> Update  : ${root} (branch ${branch})"

  out="$(git -C "$root" pull --ff-only --tags 2>&1)"; rc=$?
  [[ -n "$out" ]] && print -r -- "$out" | sed 's/^/   /'
  if (( rc != 0 )); then
    echo "!! Pull failed. If the history has diverged, reconcile it by hand." >&2
    return 1
  fi

  after="$(git -C "$root" rev-parse HEAD)"
  vafter="$(_kon_version_of "$root")"

  if [[ "$before" == "$after" ]]; then
    echo ">> Already up to date (${vafter})."
    return 0
  fi

  echo ">> Updated : ${vbefore} -> ${vafter}"
  git -C "$root" log --oneline "${before}..${after}" | sed 's/^/   /'
  echo ">> This session still runs the old code: functions are loaded at startup."
  echo "   Reload with 'exec zsh' - running tunnels survive it, same PID."

  if [[ -t 0 && "$root" == "$_KON_HOME" ]]; then
    printf ">> Reload now? [y/N] "
    local ans; read -r ans
    [[ "$ans" == [yY]* ]] && exec zsh
  fi
  return 0
}

kon() {
  emulate -L zsh
  setopt local_options
  _KON_KUBECONFIG_BACKUP_DONE=0
  local want="" mode="connect" timeout=180 port_override="" bastion_pin=""
  local noun="" profile_filter=""

  case "$1" in
    eks|rds|bastion) noun="$1"; shift ;;
  esac

  while (( $# )); do
    case "$1" in
      -s|--status)     mode="status";   shift ;;
      -S|--stop)       mode="stop";     shift ;;
      -d|--discover)   mode="discover"; shift ;;
      -P|--prune)      mode="prune";    shift ;;
      -F|--forget)     mode="forget";   shift ;;
      -l|--local-port)
        (( $# >= 2 )) || { echo "kon: $1 needs a value (try kon --help)" >&2; return 2; }
        port_override="$2"; shift 2 ;;
      -t|--timeout)
        (( $# >= 2 )) || { echo "kon: $1 needs a value (try kon --help)" >&2; return 2; }
        timeout="$2"; shift 2 ;;
      -b|--bastion)
        (( $# >= 2 )) || { echo "kon: $1 needs a value (try kon --help)" >&2; return 2; }
        bastion_pin="$2"; shift 2 ;;
      -p|--profile)
        (( $# >= 2 )) || { echo "kon: $1 needs a value (try kon --help)" >&2; return 2; }
        profile_filter="$2"; shift 2 ;;
      -h|--help)       _kon_help; return 0 ;;
      -V|--version)    _kon_version; return 0 ;;
      -u|--update)     mode="update";   shift ;;
      --doctor)        mode="doctor";   shift ;;
      --)              shift; want="$1"; shift ;;
      -*)              echo "kon: unknown option: $1 (try kon --help)" >&2; return 2 ;;
      *)               want="$1"; shift ;;
    esac
  done

  if [[ "$mode" == doctor || ( "$mode" == connect && "$want" == doctor ) ]]; then
    _kon_doctor
    return $?
  fi

  if [[ "$noun" == "bastion" ]]; then
    case "$mode" in
      status) _kon_bastion_status; return $? ;;
      forget) _kon_jump_cache_forget "$want"; return $? ;;
      connect) _kon_bastion_choose "${want:-$profile_filter}"; return $? ;;
      *) echo "kon bastion: only --status, --forget and a bare pick apply here" >&2; return 2 ;;
    esac
  fi

  case "$mode" in
    update) _kon_update; return $? ;;
    forget) echo "kon: --forget applies to 'kon bastion'" >&2; return 2 ;;
    prune)
      if [[ "$noun" == "rds" ]]; then
        echo "!! --prune applies to clusters; 'kon rds --discover' rewrites its cache." >&2
        return 2
      fi
      _kon_eks_prune; return $? ;;
    status)
      case "$noun" in
        rds) _kon_rds_status "$profile_filter"; return $? ;;
        eks) _kon_eks_status "$profile_filter"; return $? ;;
        *)   _kon_eks_status "$profile_filter" || return 1
             echo
             _kon_rds_status "$profile_filter"
             return $? ;;
      esac ;;
    stop)
      case "$noun" in
        rds) _kon_rds_stop "$want" "$profile_filter"; return $? ;;
        eks) _kon_eks_stop "$want" "$profile_filter"; return $? ;;
        *)   _kon_eks_stop "$want" "$profile_filter" || return 1
             _kon_rds_stop "$want" "$profile_filter"
             return $? ;;
      esac ;;
    discover)
      if [[ "$noun" == "rds" ]]; then
        _kon_rds_discover "${want:-$profile_filter}"
        return $?
      fi
      _kon_eks_discover "${want:-$profile_filter}" || return 1
      return 0 ;;
  esac

  if [[ "$noun" == "rds" ]]; then
    _kon_rds_connect "$want" "$timeout" "$port_override" "$bastion_pin" "$profile_filter"
    return $?
  fi
  _kon_eks_connect "$want" "$timeout" "$port_override" "$bastion_pin"
}

_kon() {
  local -a nouns clusters dbs flags
  nouns=(eks rds bastion)
  flags=(--status --stop --discover --prune --forget --update --local-port --timeout --bastion --profile --version --help --doctor)

  case "${words[2]}" in
    bastion)
      _alternative \
        "profiles:profile:(${(f)$(_kon_profiles 2>/dev/null | cut -f1)})" \
        "flags:option:(--status --forget --help)"
      return ;;
    rds)
      dbs=(${(f)"$(_kon_rds_cache_rows 2>/dev/null | cut -f1)"})
      _alternative \
        "databases:database:(${dbs})" \
        "flags:option:(${flags})"
      return ;;
    eks)
      clusters=(${(f)"$(_kon_registry 2>/dev/null | cut -f5)"})
      _alternative \
        "clusters:cluster:(${clusters})" \
        "flags:option:(${flags})"
      return ;;
  esac

  clusters=(${(f)"$(_kon_registry 2>/dev/null | cut -f5)"})
  _alternative \
    "nouns:target type:(${nouns})" \
    "clusters:cluster:(${clusters})" \
    "flags:option:(${flags})"
}
