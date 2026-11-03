# Flock binaries

Prebuilt PHP, FrankenPHP and services (PostgreSQL, MariaDB, MySQL, MongoDB, Valkey, Redis,
Meilisearch, Typesense, RustFS, Keycloak, Node.js, cloudflared) for [Flock](https://github.com/flock-php/flock), built
reproducibly on GitHub Actions and published as GitHub Releases. Flock downloads them from a
signed manifest, so nothing has to be compiled on your machine.

## What we publish

Platforms are macOS on Apple Silicon (`macos-arm64`, macOS 13+), Windows x64 (`windows-x64`) and
Linux x64 and arm64 (`linux-x64`, `linux-arm64`: glibc, built on Ubuntu 24.04, the oldest
distribution Flock supports).
Every package is either **built** here from verified upstream source, or **mirrored**: the
vendor's own binaries, checked against the vendor's checksum or signature.

| Package | macOS arm64 | Windows x64 | Linux x64, arm64 | Versions (`versions.json`) |
|---|---|---|---|---|
| `php` | built: cli + fpm, extensions compiled in, optional ones in `ext/` | mirrored: the official thread-safe build from windows.php.net | built: as on macOS, against glibc | macOS and Linux 8.1–8.5, Windows 7.4–8.5 |
| `php-exts` | – | built: extension DLLs for the Windows build (below) | – | one pack per Windows minor |
| `frankenphp` | built: FrankenPHP with the same PHP and extensions as `php` | built: FrankenPHP next to the official PHP build it links against | built: as on macOS | PHP 8.2–8.5 |
| `postgres` | built: server, client tools (psql, pg_dump, …), contrib, headers and PGXS | built | built | 14–18 |
| `pgvector-pg<major>` | built against `postgres` | built with MSVC against `postgres` | built against `postgres` | 0.8, for PostgreSQL 14–18 |
| `postgis-pg<major>` | built against `postgres`, with GEOS and PROJ | repackaged from OSGeo's bundle | built against `postgres`, with GEOS and PROJ | 3.6, for PostgreSQL 14–18 |
| `pgrouting-pg<major>` | built against `postgres` (needs `postgis`) | repackaged from OSGeo's bundle | built against `postgres` (needs `postgis`) | 4, for PostgreSQL 14–18 |
| `timescaledb-pg<major>` | built against `postgres`, with the TSL part | mirrored: Timescale's own build | built against `postgres`, with the TSL part | 2, for PostgreSQL 16–18 |
| `mariadb` | built | mirrored | built | 10.11, 11.4, 11.8, 12.3 |
| `mysql` | mirrored | mirrored | mirrored, with libaio and libnuma built here (below) | 8.0, 8.4, 9.7 |
| `mongodb` | mirrored | mirrored | mirrored: the Ubuntu 24.04 build (22.04's for 7.0) | 7.0, 8.0, 9.0 |
| `valkey` | built | built with MSYS2 (`fork()` for persistence) | built | 9.1 |
| `redis` | built | – (Valkey only) | – (Valkey only) | 7.2, 7.4, 8.4, 8.10 |
| `meilisearch` | mirrored (Community Edition) | mirrored (Community Edition) | mirrored (Community Edition) | 1 |
| `typesense` | mirrored | – (no Windows build upstream) | mirrored | 29, 30 |
| `rustfs` | mirrored | mirrored | mirrored | 1 |
| `keycloak` | mirrored, with a Temurin JRE | mirrored, with a Temurin JRE | mirrored, with a Temurin JRE | 26.7, 26.8 |
| `cloudflared` | mirrored (Cloudflare's signed build, for `flock share`) | mirrored (Cloudflare's signed build) | mirrored | 2026 |
| `node` | mirrored | mirrored | mirrored | 16, 18, 20, 22, 24, 26 |

The versions column lists release lines: every day the newest upstream release of each line is
looked up (`tools/flockrel/upstream.go`, php.net and windows.php.net for PHP) and built or mirrored
when it isn't published yet. Patch releases come in on their own; a new line (PostgreSQL 19, Node.js
28, PHP 8.6) is one entry in `versions.json`.

### PHP release candidates

A PHP minor in `versions.json` that has no release yet gets its release candidates instead
(8.6.0RC3: php.net's list of release candidates for macOS, windows.php.net's `qa/` for Windows),
until the release itself is out. Only the RCs of a new minor are built, not the RCs of patch
releases (8.4.27RC1). They are pre-releases, so they go to the beta channel and never to stable;
the release starts in experimental like any new line. FrankenPHP and the Windows extension pack
are built on the RC too, but upstream may not support the new minor yet: those builds are marked
optional in the plan, a failure is only a warning, and the next daily run tries again. Flock offers
PHP on Windows only together with its extension pack. The pack is kept for the release (the
extension API doesn't change after the first RC); raise `php.windows.extensions.build` to rebuild it.
PHP itself on macOS is not optional: add the minor once static-php-cli and the compiled-in
extensions (apcu, igbinary, redis) support it (PHP 8.6: not yet, static-php-cli 2.8.5 can't patch
its source).

### Windows extension packs

`php-exts-<minor>` holds thread-safe DLLs built with
[php-windows-builder](https://github.com/php/php-windows-builder) against the official build of
that minor, so they load into both `php` and `frankenphp` for Windows: apcu, igbinary, imagick
(with ImageMagick), pcov, redis, xdebug and opentelemetry (from PHP 8.0 on, `min_php`), plus the
MongoDB maintainers' own DLLs from PHP 8.1 on. Releases per extension, and per minor where one
needs another release (xdebug 3.1 for PHP 7.4), are in `php.windows.extensions`. memcached is
macOS only. On Windows, imagick reports its version
as `@PACKAGE_VERSION@` (`phpversion('imagick')`), like the imagick maintainers' own Windows DLLs:
its source leaves the version to the PECL release. The pack only depends on the minor, so it
isn't rebuilt for PHP patch releases; raise `php.windows.extensions.build` to rebuild it.

### opentelemetry

The macOS `php` and `frankenphp` packages and the Windows packs from PHP 8.0 on have the
[opentelemetry extension](https://github.com/open-telemetry/opentelemetry-php-instrumentation)
(Apache-2.0) as a shared extension: `ext/opentelemetry.so` on macOS (thread-safe in `frankenphp`),
`ext/php_opentelemetry.dll` in the packs. Flock doesn't load it by default: its runtime
capture (queries, logs, views, jobs and dumps) loads it with its own ini file and uses only its
`hook()` function. The release is pinned in `packages/php/macos/build.sh` (macOS) and
`php.windows.extensions.from_source` (Windows), both built from the PECL release (the GitHub
repository keeps the extension in `ext/`). It has no `composer.json` for php-windows-builder to
read its configure option from, so `--enable-opentelemetry` is passed explicitly. The smoke tests check that hooks fire
(`scripts/smoke-opentelemetry.php`), not just that the extension loads.

### PostgreSQL extensions

An extension (`pgvector`; PostGIS, pgRouting and TimescaleDB follow) is built for every
PostgreSQL major in its `postgres` list in `versions.json`, as a package of its own:
`pgvector-pg18-0.8.7-build1-linux-x64.tar.gz` on the `pgvector-pg18-0.8.7` release. Flock
installs them per major and links their files into that major's server, so an update of either
keeps the other. A platform can list fewer majors (`platforms.<platform>.postgres`) where upstream
supports fewer.

They are built after `postgres` in the same release run (`build-pg-extension.yml`), against
the published `postgres` package of their major with the build `versions.json` asks for
(`scripts/postgres-package.sh`): the same compiler, flags and headers as the server that loads
them. The smoke test (`scripts/smoke-pg-extension.sh`, `scripts/windows/smoke-pg-extension.ps1`)
runs them in that server the way Flock does: symlinked (copied on Windows) into it, with their
libraries on `LD_LIBRARY_PATH` on Linux. A package has `lib/` (the modules), `extension/`
(control and SQL files), `deps/` (libraries the modules need) and `LICENSES/`.

PostGIS bundles GEOS and PROJ (in `deps/`, with PROJ's `proj.db` in `share/proj`, which PROJ
finds next to its library) and links json-c, and on Linux SQLite and libxml2, statically. Every
source is checked against what its upstream publishes (`packages/postgis/source.sh`), and they are
all published with the release, as PostGIS is GPL-2.0 and GEOS LGPL. Not included: raster
(GDAL), SFCGAL, `ST_AsMVT`/`ST_AsGeobuf` (protobuf) and `address_standardizer`. pgRouting
requires PostGIS (`requires` in `versions.json`): its smoke test loads the published PostGIS
package of its major.

On Windows, PostGIS and pgRouting come from OSGeo's PostGIS bundles
(download.osgeo.org/postgis/windows), built for PostgreSQL's MSVC builds and checked against the
MD5 OSGeo publishes. Their versions trail the source releases and differ per major, so
`platforms.windows-x64.upstream` (`osgeo-bundle`, `tools/flockrel/osgeo.go`) looks them up per
major: PostGIS from the bundle's name, pgRouting from its file list (read with range requests,
without downloading the bundle). Of the bundle only the modules, their extension files, the DLLs
they load (following their imports, `scripts/windows/repack-osgeo.ps1`) and PROJ's data are
taken: about 30 MB instead of 280.

pgvector and TimescaleDB publish no source checksums or archives: their source is a shallow
clone of the release tag, and the build log records the commit.

TimescaleDB is complete and unmodified: the Apache-2.0 part and the part under the
[Timescale License](https://github.com/timescale/timescaledb/blob/main/tsl/LICENSE-TIMESCALE)
(compression, continuous aggregates, policies), which may be distributed in unmodified
standalone form and not be offered as a database service. On Windows it is Timescale's own
build, checked against the SHA-256 GitHub recorded for it (`packages/timescaledb/windows/fetch.sh`).
It has to be preloaded (`shared_preload_libraries=timescaledb`); Flock does that, with
`timescaledb.telemetry_level=off`. TimescaleDB supports PostgreSQL 16–18 since 2.29 (its
CMakeLists.txt still mentions 15, but the code refuses it).

### Package layouts

Archives are `.tar.gz` on macOS and Linux, and `.zip` on Windows. Mirrored packages keep the vendor's layout,
usually one top-level folder (`mysql-8.4.11-macos15-arm64/bin/mysqld`); unpack and drop it. What we
build has `flock-package.json` at the top (what it is, how it was built) and `LICENSES/`.

| Package | Layout |
|---|---|
| `php` (macOS, Linux) | `bin/php`, `bin/php-fpm`, `ext/*.so` |
| `php` (Windows) | the official zip: `php.exe`, `php-cgi.exe`, `ext/` |
| `php-exts` | `ext/php_<name>.dll` into PHP's `ext\`; `*.dll` next to `php.exe` (ImageMagick) |
| `frankenphp` (macOS, Linux) | `bin/frankenphp`, `ext/*.so` |
| `frankenphp` (Windows) | `frankenphp.exe` next to the official PHP build of the same version |
| `postgres` | `bin/`, `lib/`, `share/` (relocatable), `include/` and PGXS (Windows: `lib/postgres.lib`) to build extensions against it |
| `mariadb` (macOS, Linux) | `bin/`, `scripts/mariadb-install-db`, `share/`, `lib/plugin/`; run with `--basedir` |
| `valkey`, `redis` | `<name>-server`, `<name>-cli`, `<name>-benchmark` (Windows: with the MSYS2 DLLs) |
| `meilisearch`, `rustfs`, `typesense`, `cloudflared` | the executable and its license |
| `keycloak` | Keycloak's own layout (`lib/`, `conf/`, `themes/`, `bin/`) with Temurin's JRE in `jre/` |

### Things to know

- **MySQL on macOS** needs macOS 15: Oracle builds it for no older release.
- **MySQL on Linux** needs `libaio.so.1` and `libnuma.so.1`, which not every distribution has under
  that name (Ubuntu 24.04 calls it `libaio.so.1t64`): both are built here into `lib/private`, which
  MySQL searches first.
- **Linux builds** link only libraries every desktop Linux has, or bundle them, and need no newer
  glibc than Ubuntu 24.04's (`scripts/verify-linux.sh`). Mirrored MongoDB also links OpenSSL and
  libcurl, and MySQL libkeyutils: Flock's Linux packages depend on them.
- **PostgreSQL on Windows** refuses to run as an administrator: start it with `pg_ctl`, which drops
  the administrator rights first.
- **PHP on Windows** is only mirrored while it is windows.php.net's current build of its minor
  (older builds have no published checksum): a patch the daily run misses entirely is skipped.
- **Keycloak** is the one package that bundles a Java runtime: upstream publishes only jars, so
  each platform's package adds the Temurin JRE in `JRE_VERSION` (`packages/keycloak/mirror.sh`).
  A newer JRE is reported by the weekly check like other pinned versions; updating it means
  raising `build`. On Linux the libraries that link X11 and ALSA are removed, as Keycloak runs headless.
- **Meilisearch** is only ever the MIT Community Edition, never the BUSL `meilisearch-enterprise-*`
  builds.

## Releases

What we build is pinned in [`versions.json`](versions.json). The daily `Release` workflow
(`release.yml`) asks `tools/flockrel plan` which package versions aren't published yet, builds or
mirrors and tests each one, and uploads it to a release tagged `<package>-<version>` as
`<package>-<version>-build<N>-<platform>.tar.gz|zip`. A package is only uploaded when every check
passed (a smoke test on a fresh runner: on macOS without Homebrew), and an uploaded asset is never
replaced. Run `Release` by hand with `packages` (e.g. `postgres,node`, or `php`, `php-exts`,
`frankenphp`) to publish only some packages, or a build workflow by hand to test a version without
publishing it.

To rebuild versions that are already published (a security fix in a bundled library, an added
extension, a bug the tests missed), raise the platform's `build` in `versions.json`. The next run
builds the newest version of every line again as the new build, next to the old one. A rebuild
starts in the experimental channel (see Channels); each channel's manifest lists the newest build
that has reached it, and Flock updates an installed package when its channel has a higher build of
the same version.

| Workflow | What |
|---|---|
| `release.yml` | daily: plan, build/mirror everything missing, then `manifest.yml` |
| `manifest.yml` | the three channel manifests and the Ready for testing issue: after every Release and decision, every 6 hours, by hand |
| `promote.yml` | records a channel decision (promote, hold, yank) in `channels.json` |
| `check.yml` | weekly: new release lines, end of life, newer pinned versions as issues |
| `build-php-macos.yml` | `php` and `frankenphp` for macOS (static-php-cli) |
| `build-php-linux.yml` | `php` and `frankenphp` for Linux, x64 and arm64 (static-php-cli, glibc) |
| `build-php-exts-windows.yml` | `php-exts` for one PHP minor |
| `build-frankenphp-windows.yml` | `frankenphp` for Windows |
| `build-service.yml` | PostgreSQL, MariaDB (macOS, Linux), Valkey, Redis from source |
| `mirror.yml` | everything mirrored, including PHP for Windows |

### Licenses and sources

Each package contains the licenses of what it bundles in `LICENSES/` (mirrored archives: the
vendor's own license files). For GPL, SSPL and AGPL software (MySQL, MariaDB, MongoDB, Typesense,
Redis) the matching upstream source is published on the same release as
`<package>-<version>-source.tar.gz`; for Keycloak that archive holds Keycloak's source and the
OpenJDK source of its JRE (GPLv2 with the Classpath Exception); Valkey for Windows has the source package of the MSYS2
runtime it ships (LGPL) next to it.

## Upstream check

The daily run only follows the release lines in `versions.json`. Every Monday `check.yml`
(`flockrel check`) looks for what they don't cover and opens issues (label `upstream`); it only
reports, nothing gets built:

| Issue | When |
|---|---|
| New release line: PHP 8.6 | a line newer than the newest we build. MySQL and MariaDB: LTS lines only; Node.js: even majors only. A new PHP minor is reported from its first release candidate on; otherwise never pre-releases. |
| End of life: Node.js 18 | a line we build no longer gets updates upstream ([endoflife.date](https://endoflife.date)) |
| Updates available for pinned versions | something pinned (FrankenPHP, static-php-cli, OpenSSL, the Windows extensions, xdebug and opentelemetry on macOS) has a newer stable release; one issue, updated weekly |

Close a new-line or end-of-life issue to decide against it (skip the line, keep building it): it
isn't reported again. Issues close by themselves once versions.json covers them (the line was added
or removed, the pins are current). The pinned-versions issue comes back when there's an update it
didn't list.

## Channels

Every published build is in one of three channels, and each channel has its own signed manifest
listing the builds at its level or above:

| Channel | Manifest | Who | Contains |
|---|---|---|---|
| stable | `manifest.json` | every Flock installation | what has been promoted |
| beta | `manifest-beta.json` | opt-in in Flock | stable, patches in their waiting time, approved new lines, pre-releases |
| experimental | `manifest-experimental.json` | testing before promotion | everything published |

Where a build goes (`tools/flockrel/channels.go`, timers in `versions.json` under `channels`):

| Build | Path |
|---|---|
| a patch of a line that is already stable on that platform | beta at once, stable after 48 hours |
| a new line, package or platform, or a rebuild (higher build number) | experimental; beta once approved, then stable after 48 hours. Without a decision it moves to beta after 7 days, and to stable only when approved. |
| a pre-release (RC, beta, alpha) | beta, never stable |

What a person decided is in [`channels.json`](channels.json): approvals for beta or stable, holds
(which stop every timer of a build) and yanks, keyed by build (`<package>-<version>-build<N>-<platform>`).
Everything published before its `baseline` is stable. Timers aren't stored: every manifest run works
them out from the publish times, so the manifests only depend on the releases, `channels.json` and
the clock. `flockrel manifest -dry-run` prints every build's channel and why. A rebuild doesn't
replace the build a channel already has until it reaches that channel.

A yanked build stays listed, so Flock can warn whoever installed it, but Flock won't install it: a
channel offers the newest build that isn't yanked, and only the yanked one when there is no other.

### Deciding

The open **Ready for testing** issue (label `channels`) lists what waits for a decision, what is on
its way to stable and when, and what is held, yanked or a pre-release. The Manifest workflow keeps
it up to date, comments when a build newly waits for a decision, and closes it when nothing is
pending.

Decisions are made with the **Promote** workflow (Actions → Promote → Run workflow):

| Action | Does |
|---|---|
| `promote-beta` | approves for beta; stable follows after 48 hours |
| `promote-stable` | approves for stable (never for pre-releases) |
| `hold` / `unhold` | stops or restarts every timer of a build (hold needs a reason) |
| `yank` / `unyank` | withdraws a build or undoes it (needs a reason and the build number) |

The target is a build (`postgres-18.7-build1-macos-arm64`), a build on every platform
(`postgres-18.7-build1`), a version on one or every platform (`postgres-18.7-macos-arm64`,
`postgres-18.7`: its newest build there), or `all-pending` for everything waiting for that step. The
workflow commits the change to `channels.json` as whoever ran it and rebuilds the manifests right
away. `flockrel decide` does the same locally.

## The manifests

`manifest.yml` rebuilds and signs all three after every Release run, every 6 hours (so timers take
effect on time and signatures never expire) and by hand:

```json
{
  "schema": 1,
  "channel": "stable",
  "serial": 1792168157,
  "generated": "2026-10-16T16:29:17Z",
  "expires": "2026-11-15T16:29:17Z",
  "packages": {
    "<package>": {
      "<version>": {
        "<platform>": {
          "build": 2, "url": "https://…", "sha256": "…", "size": 92651566, "published": "…",
          "prerelease": true,
          "lts": true,
          "yanked": { "1": "Crashes on macOS 13; use build 2" }
        }
      }
    }
  }
}
```

`prerelease`, `lts` and `yanked` (yanked builds of that version, build number → reason) only appear
when they apply. `lts` marks a Node.js release nodejs.org lists as LTS: the mirror records it in
`node-<version>.json` on the release, and Flock installs the newest LTS line first. Flock downloads `releases/download/manifest/<manifest>` and `<manifest>.sig` for its
channel and checks them against the public key in [`manifest.pub`](manifest.pub), which it ships
with. It rejects a manifest that doesn't verify, isn't for the channel it asked for (`channel`), has
expired (30 days), or has a lower `serial` than the last one it accepted for that channel. A version
only lists the platforms it was published for; every download is checked against the manifest's
SHA-256. `flockrel verify -pub manifest.pub -channel stable manifest.json manifest.json.sig` does the
same checks.

The signing key is the `MANIFEST_SIGNING_KEY` secret of the `release` environment. To replace it:

```sh
go -C tools/flockrel run . keygen -pub ../../manifest.pub | gh secret set MANIFEST_SIGNING_KEY --env release
```

then commit `manifest.pub` and ship the new public key in Flock.

## Layout

```
versions.json                    what we build: PHP per platform, extensions, FrankenPHP, service lines, manifest expiry, channel timers
channels.json                    channel decisions: baseline, approvals, holds, yanks
tools/flockrel/                  release tooling: plan, manifest (channels, build + sign), verify, keygen
packages/<name>/<platform>/      build script per package and platform
packages/<name>/mirror.sh        download + verify a vendor release (mirrored packages)
packages/<name>/source.sh        download + verify the upstream source (builds, and published for copyleft)
scripts/lib.sh                   download and checksum helpers for the package scripts
scripts/macos/                   static OpenSSL build, relocation of macOS installs (@loader_path)
scripts/windows/                 php-windows-builder setup, extension packs, Windows smoke tests
scripts/publish.sh               upload a package (and its sources) to its release
scripts/ready-issue.sh           keep the Ready for testing issue up to date
scripts/upstream-issues.sh       turn the weekly check's findings into issues
scripts/verify-macos.sh          fails when a Mach-O file links outside macOS or targets macOS > 13
scripts/smoke-*.sh               smoke tests run against every package before it is published
```
