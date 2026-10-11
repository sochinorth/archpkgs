#!/usr/bin/env bash
# Builds every <folder>/PKGBUILD in the repo root into a pacman repo in _site/.
#
# Run from the repo root as an unprivileged user with passwordless sudo
# (makepkg refuses to run as root, and uses sudo to install build deps).
#
# Env:
#   REPO_NAME        pacman repo name (the [section] users put in pacman.conf)
#   BASE_URL         where the repo is published now, used to reuse packages
#                    that haven't changed instead of rebuilding them
#   FORCE            "true" rebuilds everything
#   GPG_PRIVATE_KEY  optional; when set, packages and the database are signed
#
# Per-package hook: if <folder>/update.sh exists, it runs in that folder and
# either prints the latest upstream version (pkgver is bumped and pkgrel reset
# to 1 when it differs) or edits PKGBUILD itself and prints nothing. Whenever
# PKGBUILD ends up changed, checksums are regenerated before building.
#
# Packages that fail to build keep their previously published version; their
# names are written to failed.txt so the workflow can report them.

set -euo pipefail
shopt -s nullglob

: "${REPO_NAME:?REPO_NAME must be set}" "${BASE_URL:?BASE_URL must be set}"
FORCE=${FORCE:-false}
BASE_URL=${BASE_URL%/}
ROOT=$PWD
OUT=$ROOT/_site
WORK=$(mktemp -d)
export BUILDDIR=$WORK/build SRCDEST=$WORK/src PKGDEST=$OUT
mkdir -p "$OUT" "$BUILDDIR" "$SRCDEST"
: > "$ROOT/failed.txt"

log() { printf '\n==> %s\n' "$*"; }
git_() { git -C "$ROOT" -c safe.directory='*' "$@"; }

# --- What is published right now -----------------------------------------
declare -A have_ver=()   # "name-[epoch:]pkgver-pkgrel" -> filename
declare -A have_name=()  # "name" -> filename
if curl -fsSL "$BASE_URL/$REPO_NAME.db" -o "$WORK/old.db"; then
	mkdir "$WORK/olddb"
	tar -xf "$WORK/old.db" -C "$WORK/olddb"
	for desc in "$WORK"/olddb/*/desc; do
		file=$(awk '/^%FILENAME%$/ {getline; print; exit}' "$desc")
		name=$(awk '/^%NAME%$/ {getline; print; exit}' "$desc")
		have_ver[$(basename "$(dirname "$desc")")]=$file
		have_name[$name]=$file
	done
	log "Published repo has ${#have_ver[@]} package(s)"
else
	log "Nothing published at $BASE_URL yet, building everything"
fi

# Copy a package (and its signature, if any) from the live site into _site.
fetch_old() {
	curl -fsSL "$BASE_URL/$1" -o "$OUT/$1"
	curl -fsSL "$BASE_URL/$1.sig" -o "$OUT/$1.sig" 2>/dev/null || rm -f "$OUT/$1.sig"
}

# --- Optional signing ------------------------------------------------------
KEY=""
SIGN=()
if [ -n "${GPG_PRIVATE_KEY:-}" ]; then
	printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --import 2>/dev/null
	KEY=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
	SIGN=(--sign --key "$KEY")
	log "Signing with key $KEY"
fi

# --- Build each package folder --------------------------------------------
for pkgbuild in "$ROOT"/*/PKGBUILD; do
	dir=$(dirname "$pkgbuild")
	pkg=$(basename "$dir")
	[[ $pkg == _* ]] && continue
	log "$pkg"
	cd "$dir"

	if [ -f update.sh ]; then
		before=$(sha256sum PKGBUILD)
		if latest=$(bash update.sh); then
			current=$(sed -n 's/^pkgver=//p' PKGBUILD)
			if [ -n "$latest" ] && [ "$latest" != "$current" ]; then
				sed -i -e "s/^pkgver=.*/pkgver=$latest/" -e "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
			fi
			if [ "$(sha256sum PKGBUILD)" != "$before" ]; then
				echo "    update.sh changed PKGBUILD:"
				git_ diff --unified=0 -- "$pkg/PKGBUILD" | grep '^[-+][^-+]' | sed 's/^/      /' || true
				if ! updpkgsums; then
					echo "::warning::$pkg: couldn't fetch the new sources, keeping the current version"
					git_ checkout -- "$pkg/PKGBUILD"
				fi
			fi
		else
			echo "::warning::$pkg: update.sh failed, keeping the current version"
			git_ checkout -- "$pkg/PKGBUILD"
		fi
	fi

	srcinfo=$(makepkg --printsrcinfo)
	field() { awk -F' = ' -v k="$1" '$1 == "\t" k {print $2; exit}' <<<"$srcinfo"; }
	epoch=$(field epoch)
	ver="${epoch:+$epoch:}$(field pkgver)-$(field pkgrel)"
	names=$(awk -F' = ' '$1 == "pkgname" {print $2}' <<<"$srcinfo")

	build=$FORCE
	for n in $names; do
		if [ -z "${have_ver[$n-$ver]:-}" ]; then build=true; fi
	done

	if [ "$build" = true ]; then
		echo "    building $ver"
		if ! makepkg --syncdeps --noconfirm --cleanbuild --force; then
			echo "::error::$pkg failed to build"
			echo "$pkg" >> "$ROOT/failed.txt"
			git_ checkout -- "$pkg/PKGBUILD"   # don't commit a bump that doesn't build
			for n in $names; do
				if [ -n "${have_name[$n]:-}" ]; then fetch_old "${have_name[$n]}"; fi
			done
		fi
	else
		echo "    $ver already published, reusing it"
		for n in $names; do fetch_old "${have_ver[$n-$ver]}"; done
	fi
	cd "$ROOT"
done

# --- Repo database ---------------------------------------------------------
cd "$OUT"
pkgs=( *.pkg.tar.zst *.pkg.tar.xz )
if [ ${#pkgs[@]} -eq 0 ]; then
	echo "::error::No packages to publish"
	exit 1
fi

if [ -n "$KEY" ]; then
	for p in "${pkgs[@]}"; do
		if [ ! -f "$p.sig" ]; then
			gpg --batch --yes --detach-sign --no-armor -u "$KEY" "$p"
		fi
	done
	gpg --batch --armor --export "$KEY" > key.asc
fi

repo-add "${SIGN[@]}" "$REPO_NAME.db.tar.gz" "${pkgs[@]}"

# repo-add makes NAME.db / NAME.files symlinks; web hosts need real files.
for f in "$REPO_NAME".{db,files}{,.sig}; do
	if [ -L "$f" ]; then cp --remove-destination "$(readlink -f "$f")" "$f"; fi
done

# --- Landing page ----------------------------------------------------------
{
	cat <<EOF
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$REPO_NAME</title>
<style>
	body { font: 15px/1.55 system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; }
	pre { background: #8881; padding: .8rem 1rem; overflow-x: auto; border-radius: 6px; }
</style>
<h1>$REPO_NAME</h1>
<p>A personal pacman repository. Add this to <code>/etc/pacman.conf</code>:</p>
EOF
	if [ -n "$KEY" ]; then
		cat <<EOF
<pre>[$REPO_NAME]
Server = $BASE_URL</pre>
<p>and trust the signing key once:</p>
<pre>curl -O $BASE_URL/key.asc
sudo pacman-key --add key.asc
sudo pacman-key --lsign-key $KEY</pre>
EOF
	else
		cat <<EOF
<pre>[$REPO_NAME]
SigLevel = Optional TrustAll
Server = $BASE_URL</pre>
EOF
	fi
	echo "<p>Then run <code>sudo pacman -Syu</code>.</p>"
	echo "<h2>Packages</h2><ul>"
	for p in "${pkgs[@]}"; do echo "  <li><a href=\"$p\">$p</a></li>"; done
	echo "</ul>"
} > index.html

log "Published ${#pkgs[@]} package(s)"
if [ -s "$ROOT/failed.txt" ]; then
	log "Failed: $(paste -sd' ' "$ROOT/failed.txt")"
fi
