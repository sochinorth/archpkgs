#!/usr/bin/env bash
# Edits PKGBUILD in place when either crate has a new release:
#   new kak-tree-sitter -> pkgver bumped, pkgrel reset to 1
#   new ktsctl only     -> _ktsctlver bumped, pkgrel + 1
# Prints nothing; the CI regenerates checksums when PKGBUILD changes.
set -euo pipefail

latest() {
	curl -fsSL -A "pacman-repo-ci (GitHub Actions)" \
		"https://crates.io/api/v1/crates/$1" | jq -er '.crate.max_stable_version'
}
var() { sed -n "s/^$1=//p" PKGBUILD; }

kts=$(latest kak-tree-sitter)
ktsctl=$(latest ktsctl)
rel=$(var pkgrel)

if [ "$kts" != "$(var pkgver)" ]; then
	rel=1
elif [ "$ktsctl" != "$(var _ktsctlver)" ]; then
	rel=$((rel + 1))
fi

sed -i -e "s/^pkgver=.*/pkgver=$kts/" \
			 -e "s/^_ktsctlver=.*/_ktsctlver=$ktsctl/" \
			 -e "s/^pkgrel=.*/pkgrel=$rel/" PKGBUILD
