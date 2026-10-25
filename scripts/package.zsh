#!/usr/bin/env zsh

emulate -L zsh
setopt err_exit pipe_fail

typeset ROOT="${0:A:h:h}"
typeset DIST="${ROOT}/dist"
typeset VERSION STAGE TARBALL DEB PKG

if [[ ! -r "${ROOT}/VERSION" ]]; then
  print -u2 -r -- "package.zsh: cannot read ${ROOT}/VERSION"
  exit 1
fi

VERSION="$(<"${ROOT}/VERSION")"
VERSION="${VERSION//[[:space:]]/}"

if [[ "$VERSION" != <->.<->.<-> ]]; then
  print -u2 -r -- "package.zsh: VERSION must be X.Y.Z, found '${VERSION}'"
  exit 1
fi

STAGE="${DIST}/kon-${VERSION}"
TARBALL="${DIST}/kon-${VERSION}.tar.gz"
DEB="${DIST}/kon_${VERSION}_all.deb"

rm -rf "${DIST}"
mkdir -p "${STAGE}/scripts"

typeset -a FILES
FILES=(init.zsh kon.zsh prompt.zsh VERSION README.md scripts/install.zsh)
if [[ -r "${ROOT}/LICENSE" ]]; then
  FILES+=(LICENSE)
fi

typeset f
for f in "${FILES[@]}"; do
  if [[ ! -r "${ROOT}/${f}" ]]; then
    print -u2 -r -- "package.zsh: cannot stage ${f}: not readable under ${ROOT}"
    exit 1
  fi
  cp -- "${ROOT}/${f}" "${STAGE}/${f}"
done

tar -czf "${TARBALL}" -C "${DIST}" "kon-${VERSION}"
print -r -- ">> tarball  : ${TARBALL}"

if ! whence -p dpkg-deb >/dev/null; then
  print -r -- ">> deb      : skipped, no dpkg-deb on this machine; the release job builds it on ubuntu-latest"
  exit 0
fi

PKG="${DIST}/deb"
mkdir -p "${PKG}/DEBIAN" "${PKG}/usr/share/kon" "${PKG}/usr/share/doc/kon"
cp -R -- "${STAGE}/." "${PKG}/usr/share/kon/"
if [[ -r "${ROOT}/LICENSE" ]]; then
  cp -- "${ROOT}/LICENSE" "${PKG}/usr/share/doc/kon/copyright"
fi

typeset -a CONTROL
CONTROL=(
  "Package: kon"
  "Version: ${VERSION}"
  "Section: admin"
  "Priority: optional"
  "Architecture: all"
  "Maintainer: Jonathan Amilcar MIDI <jonathan.amilcarmidi@gmail.com>"
  "Depends: zsh, python3"
  "Recommends: lsof, fzf"
  "Suggests: kubectl, session-manager-plugin"
  "Description: one command to reach a private EKS cluster or RDS database (zsh)"
  " kon resolves the whole chain for a private target: the AWS profile, the SSO"
  " session, the kube context, the bastion, the SSM tunnel on a port derived"
  " from the target's identity, and the kubeconfig rewrite. kubectl and"
  " Terraform then reach the private API through 127.0.0.1."
  " ."
  " This package holds zsh sources only. It installs no maintainer script and"
  " writes nothing outside /usr/share/kon."
)
print -rl -- "${CONTROL[@]}" >| "${PKG}/DEBIAN/control"

dpkg-deb -Zxz --build --root-owner-group "${PKG}" "${DEB}"
print -r -- ">> deb      : ${DEB}"
