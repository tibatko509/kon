
_KON_ROOT="${0:A:h}"

source "${_KON_ROOT}/kon.zsh"

[[ -z "$KON_NO_PROMPT" ]] && source "${_KON_ROOT}/prompt.zsh"

if (( $+functions[_kon] )); then
  if (( $+functions[compdef] )); then
    compdef _kon kon
  else
    autoload -Uz add-zsh-hook 2>/dev/null
    _kon_late_compdef() {
      (( $+functions[compdef] )) || return
      compdef _kon kon
      add-zsh-hook -d precmd _kon_late_compdef
      unfunction _kon_late_compdef
    }
    add-zsh-hook precmd _kon_late_compdef 2>/dev/null
  fi
fi

unset _KON_ROOT
