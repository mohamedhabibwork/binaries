#!/usr/bin/env bash
# Downloads the sources of what the Keycloak package bundles, published next to it for the JRE's
# GPL: Keycloak's release tag and Temurin's OpenJDK sources, as one archive holding both.
# Usage: packages/keycloak/source.sh <version> <file.tar.gz>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="${1:?usage: source.sh <version> <file>}"; OUT="${2:?usage: source.sh <version> <file>}"
JRE="$(jq -er '.packages.keycloak.env.JRE_VERSION' "$(dirname "$0")/../../versions.json")"

tmp="$(mktemp -d)"
fetch "https://github.com/keycloak/keycloak/archive/refs/tags/$V.tar.gz" "$tmp/keycloak-$V-source.tar.gz"
jre_repo="adoptium/temurin${JRE%%.*}-binaries"
jre_asset="OpenJDK${JRE%%.*}U-jdk-sources_${JRE/+/_}.tar.gz"
fetch "https://github.com/$jre_repo/releases/download/jdk-${JRE/+/%2B}/$jre_asset" "$tmp/$jre_asset"
check_sha256 "$tmp/$jre_asset" "$(github_digest "$jre_repo" "jdk-$JRE" "$jre_asset")" >&2
tar -C "$tmp" -czf "$OUT" "keycloak-$V-source.tar.gz" "$jre_asset"
