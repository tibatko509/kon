# Changelog

Releases from 1.0.0 onward are generated from the Conventional Commit
history by semantic-release. Do not edit released sections by hand.

# [1.8.0](https://github.com/tibatko509/kon/compare/v1.7.1...v1.8.0) (2026-10-25)


### Features

* **packaging:** ship a Homebrew formula and sync it to the tap ([77e0801](https://github.com/tibatko509/kon/commit/77e0801ffe3ed0af49ccdffdd36767f666a341de))

# Changelog

Releases from here on are generated from Conventional Commits by
semantic-release. Released sections are not edited by hand.

## 1.7.1

First public release. The version continues from the private history, which is
not part of this repository, and this is the commit the public history starts
from.

- one command reaches a private EKS cluster or an RDS database through an SSM
  tunnel: the AWS profile, SSO session, kube context, jump host and local port
  are resolved for you
- targets are discovered, never derived from a naming convention
- local ports come from the target's identity, so they are the same in every
  shell and on every machine
- `kon doctor` names a missing prerequisite before the first connect does
- ships as a zsh source tree, a tarball and a Debian package
