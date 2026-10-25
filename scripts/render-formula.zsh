#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit pipe_fail

typeset ROOT="${0:A:h:h}"
typeset VERSION="$1"
typeset SHA="$2"
typeset OUT="${3:-${ROOT}/build/kon.rb}"

if [[ -z "$VERSION" || -z "$SHA" ]]; then
  print -u2 -r -- "usage: render-formula.zsh <version> <sha256> [output]"
  exit 2
fi

if [[ "$VERSION" != <->.<->.<-> ]]; then
  print -u2 -r -- "render-formula.zsh: version must be X.Y.Z, got '${VERSION}'"
  exit 2
fi

if (( ${#SHA} != 64 )) || [[ -n "${SHA//[0-9a-f]/}" ]]; then
  print -u2 -r -- "render-formula.zsh: sha256 must be 64 lowercase hex characters"
  exit 2
fi

mkdir -p -- "${OUT:h}"
sed -e "s|__VERSION__|${VERSION}|g" -e "s|__SHA256__|${SHA}|g" \
  -- "${ROOT}/packaging/kon.rb.in" >| "$OUT"

print -r -- ">> formula : ${OUT} (kon ${VERSION})"
