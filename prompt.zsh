
autoload -Uz add-zsh-hook
zmodload -F zsh/stat b:zstat 2>/dev/null

kcloud() {
  emulate -L zsh
  local ctx cluster provider region
  ctx="$(kubectl config current-context 2>/dev/null)" || return 0
  [[ -n "$ctx" ]] || return 0

  provider="k8s"
  region=""
  cluster="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null)"

  if [[ "$cluster" == arn:aws:eks:* ]]; then
    provider="aws"; region="${${cluster#arn:aws:eks:}%%:*}"
  elif [[ "$ctx" == arn:aws:eks:* ]]; then
    provider="aws"; region="${${ctx#arn:aws:eks:}%%:*}"
  elif [[ "$ctx" == gke_* ]]; then
    provider="gcp"; region="${${(s:_:)ctx}[-2]}"
  elif [[ "$ctx" == (*aks*|*AKS*) ]]; then
    provider="azure"
  fi

  if [[ -z "$region" ]]; then
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-${AZURE_DEFAULTS_LOCATION:-${CLOUDSDK_COMPUTE_REGION:-}}}}"
  fi

  [[ -n "$region" ]] && print -r -- "${provider}:${region}" || print -r -- "${provider}"
}

_kon_cloud_set() {
  local st
  _KON_CLOUD="aws:${1}"
  zstat -A st +mtime -- "${${KUBECONFIG:-$HOME/.kube/config}%%:*}" 2>/dev/null \
    && _KON_CLOUD_MTIME="$st[1]"
}

_kon_cloud_refresh() {
  local kcfg="${${KUBECONFIG:-$HOME/.kube/config}%%:*}" st
  if ! zstat -A st +mtime -- "$kcfg" 2>/dev/null; then
    _KON_CLOUD=""; _KON_CLOUD_MTIME=""; return
  fi
  [[ "$st[1]" == "$_KON_CLOUD_MTIME" ]] && return
  _KON_CLOUD_MTIME="$st[1]"
  _KON_CLOUD="$(kcloud)"
}

add-zsh-hook precmd _kon_cloud_refresh

setopt prompt_subst

if [[ "$RPROMPT" != *_KON_CLOUD* ]]; then
  if (( $+functions[kube_ps1] )); then
    RPROMPT='${_KON_CLOUD} $(kube_ps1)'
  elif [[ -n "$RPROMPT" ]]; then
    RPROMPT='${_KON_CLOUD} '"$RPROMPT"
  else
    RPROMPT='${_KON_CLOUD}'
  fi
fi
