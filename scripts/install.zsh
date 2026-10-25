#!/usr/bin/env zsh

emulate -L zsh

typeset ROOT="${0:A:h:h}"
typeset WANT="$0"
[[ "$WANT" == /* ]] || WANT="$PWD/${WANT}"
WANT="${WANT:a:h:h}"
typeset RC="$HOME/.zshrc"
typeset -i DRY=0
typeset BEGIN="# >>> kon >>>"
typeset END="# <<< kon <<<"

while (( $# )); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --rc)      RC="${~2}"; shift 2 ;;
    -h|--help) print -r -- "usage: install.zsh [--dry-run] [--rc PATH]"; exit 0 ;;
    *) print -u2 -r -- "install.zsh: unknown argument: $1"; exit 2 ;;
  esac
done

[[ -r "$ROOT/init.zsh" ]] || {
  print -u2 -r -- "install.zsh: cannot find init.zsh under ${ROOT}"
  exit 1
}

if [[ ! -f "$RC" ]]; then
  print -r -- ">> creating ${RC}"
  (( DRY )) || : >> "$RC"
fi

typeset -a src
typeset line
while IFS= read -r line || [[ -n "$line" ]]; do src+=("$line"); done < "$RC"

typeset -i i bstart=0 bend=0
for (( i = 1; i <= ${#src}; i++ )); do
  if (( ! bstart )) && [[ "${src[i]}" == "$BEGIN" ]]; then bstart=$i; continue; fi
  if (( bstart )) && [[ "${src[i]}" == "$END" ]]; then bend=$i; break; fi
done

if (( bstart && ! bend )); then
  print -u2 -r -- "install.zsh: ${RC} line ${bstart} opens '${BEGIN}' with no '${END}'."
  print -u2 -r -- "install.zsh: refusing to guess where it ends. Close or remove it, then rerun."
  exit 1
fi

typeset -a legacy
legacy=(
  '[ -f ~/.tunnel.zsh ] && source ~/.tunnel.zsh'
  '[[ -f ~/.tunnel.zsh ]] && source ~/.tunnel.zsh'
  '(( $+functions[_kon] )) && compdef _kon kon'
)

typeset -a out
typeset -i insert_at=0 removed_legacy=0
for (( i = 1; i <= ${#src}; i++ )); do
  if (( bstart && i >= bstart && i <= bend )); then
    (( i == bstart )) && insert_at=$(( ${#out} + 1 ))
    continue
  fi
  if (( ${legacy[(Ie)${src[i]}]} )); then
    (( removed_legacy++ ))
    continue
  fi
  out+=("${src[i]}")
done

typeset placement
if (( insert_at )); then
  placement="replaced in place (line ${insert_at})"
else
  typeset -i floor=0 anchor=0
  for (( i = 1; i <= ${#out}; i++ )); do
    [[ "${out[i]}" == *compinit* || "${out[i]}" == *oh-my-zsh.sh* ]] && floor=$i
  done
  for (( i = 1; i <= ${#out}; i++ )); do
    [[ "${out[i]}" == *p10k.zsh* && "${out[i]}" != ZSH_THEME=* ]] && { anchor=$i; break }
  done
  if (( anchor > floor )); then
    insert_at=$anchor
    placement="inserted before the p10k line (line ${anchor})"
  else
    insert_at=$(( ${#out} + 1 ))
    placement="appended"
  fi
fi

typeset -a block
block=(
  "$BEGIN"
  "# Managed by ${WANT}/scripts/install.zsh - edit the repo, not this block."
  "# Provides: kon, kcloud, the RPROMPT cloud segment"
  "# and kon completion. Must stay after compinit so compdef registers."
  "if [[ -r \"${WANT}/init.zsh\" ]]; then source \"${WANT}/init.zsh\"; fi"
  "$END"
)

out[insert_at,0]=("${block[@]}")

typeset tmp="${RC}.kon-install.$$"
print -rl -- "${out[@]}" >| "$tmp"

print -r -- ">> repo         : ${ROOT}"
print -r -- ">> rc file      : ${RC}"
print -r -- ">> managed block: ${placement}"
(( removed_legacy )) && print -r -- ">> legacy lines : removed ${removed_legacy}"

if grep -qE '^[[:space:]]*(kcloud|_kon_cloud_refresh|_kon_cloud_set)\(\)' "$RC" 2>/dev/null; then
  print -r -- ""
  print -r -- "!! ${RC} defines kcloud/_kon_cloud_* inline (a pre-repo copy)."
  print -r -- "!! Delete those definitions and the RPROMPT line that uses them;"
  print -r -- "!! prompt.zsh in this repo supersedes them."
fi

if (( DRY )); then
  print -r -- ""
  print -r -- ">> dry run, ${RC} not modified. Result would be:"
  print -r -- "---8<---"
  diff -u "$RC" "$tmp" || true
  print -r -- "--->8---"
  rm -f "$tmp"
  exit 0
fi

if diff -q "$RC" "$tmp" >/dev/null 2>&1; then
  rm -f "$tmp"
  print -r -- ">> already up to date, ${RC} left untouched."
  exit 0
fi

typeset backup="${RC}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$RC" "$backup" || { print -u2 -r -- "install.zsh: backup failed"; rm -f "$tmp"; exit 1 }
mv "$tmp" "$RC"
print -r -- ">> backup       : ${backup}"
print -r -- ">> done. Open a new shell, or: source ${RC}"
