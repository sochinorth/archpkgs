#!/usr/bin/env bash
# Prints the latest upstream version; the CI bumps pkgver when it changes.
curl -fsSL -A "pacman-repo-ci (GitHub Actions)" \
  https://crates.io/api/v1/crates/ktsctl | jq -r '.crate.max_stable_version'
