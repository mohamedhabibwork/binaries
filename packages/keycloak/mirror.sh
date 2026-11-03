#!/usr/bin/env bash
# Mirrors Keycloak (Apache-2.0) with the Temurin JRE it runs on, both checked against GitHub's
# SHA-256 of the release asset. Upstream's archive holds only jars, the same for every platform:
# the JRE (GPLv2 with the Classpath Exception, source.sh publishes its source) goes into jre/, and
# is what makes the package platform-specific.
# Usage: packages/keycloak/mirror.sh <version> <platform> <out-file>
set -euo pipefail
. "$(dirname "$0")/../../scripts/lib.sh"
V="$1"; PLATFORM="$2"; OUT="$3"
JRE="$(jq -er '.packages.keycloak.env.JRE_VERSION' "$(dirname "$0")/../../versions.json")"

ext=tar.gz
case "$PLATFORM" in
  macos-arm64) jre_target=aarch64_mac ;;
  windows-x64) jre_target=x64_windows; ext=zip ;;
  linux-x64) jre_target=x64_linux ;;
  linux-arm64) jre_target=aarch64_linux ;;
esac
unpack() { if [[ "$1" == *.zip ]]; then unzip -q "$1" -d "$2"; else tar -C "$2" -xzf "$1"; fi; }

tmp="$(mktemp -d)"; mkdir "$tmp/keycloak" "$tmp/jre"
asset="keycloak-$V.$ext"
fetch "https://github.com/keycloak/keycloak/releases/download/$V/$asset" "$tmp/$asset"
check_sha256 "$tmp/$asset" "$(github_digest keycloak/keycloak "$V" "$asset")"
unpack "$tmp/$asset" "$tmp/keycloak"
dir="$tmp/keycloak/keycloak-$V"

jre_repo="adoptium/temurin${JRE%%.*}-binaries"
jre_asset="OpenJDK${JRE%%.*}U-jre_${jre_target}_hotspot_${JRE/+/_}.$ext"
fetch "https://github.com/$jre_repo/releases/download/jdk-${JRE/+/%2B}/$jre_asset" "$tmp/$jre_asset"
check_sha256 "$tmp/$jre_asset" "$(github_digest "$jre_repo" "jdk-$JRE" "$jre_asset")"
unpack "$tmp/$jre_asset" "$tmp/jre"
home="$tmp/jre/jdk-$JRE-jre"
[[ "$PLATFORM" == macos-* ]] && home="$home/Contents/Home"
mv "$home" "$dir/jre"

# Keycloak runs headless. These link X11 and ALSA, which a server's Linux needn't have.
if [[ "$PLATFORM" == linux-* ]]; then
  rm -f "$dir"/jre/lib/{libawt_xawt.so,libjawt.so,libsplashscreen.so,libjsound.so}
fi
pack "$dir" "$OUT"
