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
