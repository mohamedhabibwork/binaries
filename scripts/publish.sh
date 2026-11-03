#!/usr/bin/env bash
# Uploads a package to its release <package>-<version>, creating the release if needed. For
# packages with publish_source in versions.json (GPL, SSPL, AGPL), the upstream source tarball
# is uploaded first as <package>-<version>-source.<ext>, once per release.
# Further files (sources a build adds for its license) are uploaded the same way, once per release.
# A published asset is never replaced: uploading one that exists fails.
# Usage: scripts/publish.sh <package> <version> <asset-file> [<extra-file>...]   (GH_TOKEN, GH_REPO set)
set -euo pipefail
PKG="$1"; V="$2"; ASSET="$3"; shift 3
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="$PKG-$V"
# A PostgreSQL extension's package (postgis-pg18) has the settings of its extension (postgis).
CONFIG="$PKG"
if [[ "$PKG" =~ ^(.+)-pg([0-9]+)$ ]] && [[ "$(jq -r --arg p "${BASH_REMATCH[1]}" '.packages[$p].postgres // empty' "$ROOT/versions.json")" ]]; then
  CONFIG="${BASH_REMATCH[1]}" MAJOR="${BASH_REMATCH[2]}"
fi

title() {
  if [[ "$CONFIG" != "$PKG" ]]; then
    case "$CONFIG" in
      pgvector) echo -n pgvector ;; postgis) echo -n PostGIS ;; pgrouting) echo -n pgRouting ;; timescaledb) echo -n TimescaleDB ;; *) echo -n "$CONFIG" ;;
    esac
    echo " for PostgreSQL $MAJOR"
    return
  fi
  case "$PKG" in
    postgres) echo PostgreSQL ;; mariadb) echo MariaDB ;; mysql) echo MySQL ;; mongodb) echo MongoDB ;;
    redis) echo Redis ;; valkey) echo Valkey ;; meilisearch) echo Meilisearch ;; typesense) echo Typesense ;;
    rustfs) echo RustFS ;; keycloak) echo Keycloak ;; node) echo Node.js ;; php) echo PHP ;; php-exts) echo "PHP extensions" ;;
    frankenphp) echo "FrankenPHP for PHP" ;; *) echo "$PKG" ;;
  esac
}

# Uploads a file that every platform of the release shares. Another platform may be uploading
# the same name at once: if our upload fails, wait until its upload has finished.
upload_once() {
  local file="$1" name; name="$(basename "$1")"
  gh release upload "$TAG" "$file" && return
  for _ in $(seq 60); do
    gh api "repos/{owner}/{repo}/releases/tags/$TAG" \
      --jq '.assets[] | select(.state == "uploaded") | .name' | grep -qx "$name" && return
    sleep 10
  done
  echo "$name is not on $TAG after 10 minutes" >&2
  return 1
}

if ! gh release view "$TAG" >/dev/null 2>&1; then
  # Two platforms can publish at once: losing the race to create the release is fine.
  gh release create "$TAG" --title "$(title) $V" --latest=false \
    --notes "$(title) $V for Flock. Packages are listed in the signed manifest." \
    || gh release view "$TAG" >/dev/null
fi

assets="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
if [[ "$(jq -r --arg p "$CONFIG" '.packages[$p].publish_source // false' "$ROOT/versions.json")" == true ]]; then
  ext=tar.gz; [[ "$PKG" == postgres ]] && ext=tar.bz2
  src="$PKG-$V-source.$ext"
  if ! grep -qx "$src" <<<"$assets"; then
    tmp="$(mktemp -d)"
    if [[ "$CONFIG" != "$PKG" ]]; then
      # An extension's source.sh fetches into a folder, the one its build uses, with the versions
      # of what it bundles (PostGIS: GEOS, PROJ, ...) from its env.
      while IFS='=' read -r key value; do export "$key=$value"; done \
        < <(jq -r --arg p "$CONFIG" '.packages[$p].env // {} | to_entries[] | "\(.key)=\(.value)"' "$ROOT/versions.json")
      bash "$ROOT/packages/$CONFIG/source.sh" "$V" "$tmp/src" >/dev/null
      tar -C "$tmp" --exclude .git -czf "$tmp/$src" src
    else
      bash "$ROOT/packages/$CONFIG/source.sh" "$V" "$tmp/$src"
    fi
    upload_once "$tmp/$src"
  fi
fi

# Extra files: once per release (another platform may have uploaded the same one).
for extra in "$@"; do
  [[ -f "$extra" ]] || continue
  name="$(basename "$extra")"
  if ! grep -qx "$name" <<<"$assets"; then
    upload_once "$extra"
  fi
done

# No --clobber: a published asset is never replaced.
gh release upload "$TAG" "$ASSET"
echo "published $(basename "$ASSET") on $TAG"
