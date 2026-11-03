#!/usr/bin/env bash
# Smoke-tests a service package on macOS or Linux the way Flock runs it: unpack (dropping a single
# top-level folder, as Flock does), initialise a data directory, start on 127.0.0.1, talk to it
# with its own client, shut down. With SIGNER_MACOS set, the main binary must carry a valid code
# signature whose authority matches that regex (SIGNER_MACOS in versions.json) (the vendor's, for mirrored packages).
# Usage: scripts/smoke-service.sh <package> <archive>
set -uo pipefail

PKG="${1:?usage: smoke-service.sh <package> <archive>}"
ARCHIVE="${2:?usage: smoke-service.sh <package> <archive>}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
tmp="$(mktemp -d)"
D="$tmp/pkg"
data="$tmp/data"
mkdir -p "$D" "$data"
failed=0

ok() { echo "✓ $*" | tee -a "$summary"; }
fail() { echo "✗ $*" | tee -a "$summary"; failed=1; }
check() { local name="$1"; shift; if out="$("$@" 2>&1)"; then ok "$name"; else fail "$name: $(tail -5 <<<"$out")"; fi; }
wait_port() {
  for _ in $(seq 1 150); do (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
wait_http() {
  for _ in $(seq 1 150); do curl -fs "$1" >/dev/null && return 0; sleep 0.2; done
  return 1
}
stop() { kill "$1" 2>/dev/null; for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done; kill -9 "$1"; return 1; }

tar -C "$D" -xzf "$ARCHIVE"
# Flock drops a single top-level folder (mysql-8.4.6-macos15-arm64/, node-v22…/).
entries=("$D"/*)
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then D="${entries[0]}"; fi
echo "### $PKG: $(basename "$ARCHIVE")" | tee -a "$summary"

if [[ -n "${SIGNER_MACOS:-}" && "$(uname)" == Darwin ]]; then
  case "$PKG" in mysql) main=bin/mysqld ;; mongodb) main=bin/mongod ;; node) main=bin/node ;; *) main="" ;; esac
  if codesign --verify --strict "$D/$main" 2>/dev/null \
     && authority="$(codesign -dvv "$D/$main" 2>&1 | sed -n 's/^Authority=//p' | head -1)" \
     && grep -Eq "$SIGNER_MACOS" <<<"$authority"; then
    ok "code signature: $authority"
  else
    fail "code signature of $main: $(codesign -dvv "$D/$main" 2>&1 | grep -E 'Authority|not signed' | head -2)"
  fi
fi

case "$PKG" in
  postgres)
    check "initdb" "$D/bin/initdb" -D "$data" -U postgres --auth=trust -E UTF8 --locale=C
    "$D/bin/postgres" -D "$data" -p 54329 -c listen_addresses=127.0.0.1 -k "$tmp" >"$tmp/log" 2>&1 &
    pid=$!
    wait_port 54329 || fail "postgres did not start: $(tail -5 "$tmp/log")"
    psql=("$D/bin/psql" -h 127.0.0.1 -p 54329 -U postgres -v ON_ERROR_STOP=1 -At)
    check "query: $("${psql[@]}" -c 'select version()' 2>&1)" "${psql[@]}" -c 'select 1'
    check "contrib extensions (pgcrypto, uuid-ossp, pg_trgm, hstore, citext)" "${psql[@]}" \
      -c 'create extension pgcrypto; create extension "uuid-ossp"; create extension pg_trgm; create extension hstore; create extension citext' \
      -c "select digest('flock', 'sha256'), uuid_generate_v4(), gen_random_uuid(), similarity('flock', 'block'), 'a=>1'::hstore, 'A'::citext = 'a'"
    # Extensions build against the package with its own pg_config (PGXS), into a folder of their
    # own, and load from there through symlinks, the way Flock links them.
    mkdir -p "$tmp/hello" "$tmp/custom"
    printf '#include "postgres.h"\n#include "fmgr.h"\nPG_MODULE_MAGIC;\nPG_FUNCTION_INFO_V1(hello);\nDatum hello(PG_FUNCTION_ARGS) { PG_RETURN_INT32(42); }\n' >"$tmp/hello/hello.c"
    printf "default_version = '1.0'\nmodule_pathname = '\$libdir/hello'\nrelocatable = true\n" >"$tmp/hello/hello.control"
    printf "CREATE FUNCTION hello() RETURNS int AS 'MODULE_PATHNAME' LANGUAGE C;\n" >"$tmp/hello/hello--1.0.sql"
    printf 'MODULES = hello\nEXTENSION = hello\nDATA = hello--1.0.sql\nPGXS := $(shell $(PG_CONFIG) --pgxs)\ninclude $(PGXS)\n' >"$tmp/hello/Makefile"
    check "PGXS build" bash -c "make -C '$tmp/hello' PG_CONFIG='$D/bin/pg_config' && make -C '$tmp/hello' install PG_CONFIG='$D/bin/pg_config' pkglibdir='$tmp/custom/lib' datadir='$tmp/custom'"
    lib="$("$D/bin/pg_config" --pkglibdir)" share="$("$D/bin/pg_config" --sharedir)"
    for f in "$tmp"/custom/lib/* "$tmp"/custom/extension/*; do
      [[ "$f" == */lib/* ]] && ln -s "$f" "$lib/" || ln -s "$f" "$share/extension/"
    done
    hello() { [[ "$("${psql[@]}" -c 'create extension hello' -c 'select hello()' | tail -1)" == 42 ]]; }
    check "extension built with PGXS" hello
    check "createdb" "$D/bin/createdb" -h 127.0.0.1 -p 54329 -U postgres flock
    check "pg_dump | pg_restore" bash -c "'$D/bin/pg_dump' -h 127.0.0.1 -p 54329 -U postgres -Fc postgres >'$tmp/dump' && '$D/bin/pg_restore' -l '$tmp/dump' >/dev/null"
    check "pg_ctl stop" "$D/bin/pg_ctl" stop -D "$data" -m fast
    ;;

  mariadb | mysql)
    if [[ "$PKG" == mariadb ]]; then
      check "install-db" "$D/scripts/mariadb-install-db" --no-defaults --basedir="$D" --datadir="$data" \
        --auth-root-authentication-method=normal --skip-test-db
      server="$D/bin/mariadbd"; client="$D/bin/mariadb"; admin="$D/bin/mariadb-admin"; extra=()
    else
      check "initialize" "$D/bin/mysqld" --no-defaults --initialize-insecure --basedir="$D" --datadir="$data"
      server="$D/bin/mysqld"; client="$D/bin/mysql"; admin="$D/bin/mysqladmin"; extra=(--mysqlx=OFF)
    fi
    "$server" --no-defaults --basedir="$D" --datadir="$data" --port=33069 --bind-address=127.0.0.1 \
      --socket="$tmp/sql.sock" ${extra[@]+"${extra[@]}"} >"$tmp/log" 2>&1 &
    pid=$!
    wait_port 33069 || fail "server did not start: $(tail -5 "$tmp/log")"
    sql=("$client" --no-defaults -h127.0.0.1 -P33069 -uroot)
    check "query: $("${sql[@]}" -N -e 'select version()' 2>/dev/null)" "${sql[@]}" \
      -e 'create database flock; create table flock.t (id int primary key, v json) engine=innodb; insert into flock.t values (1, json_object("a", 1)); select * from flock.t'
    check "shutdown" "$admin" --no-defaults -h127.0.0.1 -P33069 -uroot shutdown
    wait "$pid"
    ;;

  mongodb)
    check "mongod --version" "$D/bin/mongod" --version
    "$D/bin/mongod" --dbpath "$data" --port 27029 --bind_ip 127.0.0.1 --nounixsocket >"$tmp/log" 2>&1 &
    pid=$!
    if wait_port 27029; then ok "mongod accepts connections"; else fail "mongod did not start: $(tail -5 "$tmp/log")"; fi
    check "stop" stop "$pid"
    ;;

  redis | valkey)
    "$D/$PKG-server" --port 63799 --bind 127.0.0.1 --dir "$data" --daemonize no --appendonly yes >"$tmp/log" 2>&1 &
    pid=$!
    wait_port 63799 || fail "$PKG-server did not start: $(tail -5 "$tmp/log")"
    cli=("$D/$PKG-cli" -p 63799)
    check "version: $("$D/$PKG-server" --version)" test "$("${cli[@]}" PING)" = PONG
    check "SET/GET" bash -c "'$D/$PKG-cli' -p 63799 SET flock works >/dev/null && test \"\$('$D/$PKG-cli' -p 63799 GET flock)\" = works"
    check "BGSAVE" "${cli[@]}" BGSAVE
    sleep 1
    check "SHUTDOWN" bash -c "'$D/$PKG-cli' -p 63799 SHUTDOWN; true"
    wait "$pid"
    ;;

  meilisearch)
    "$D/meilisearch" --db-path "$data/data.ms" --http-addr 127.0.0.1:7709 --env development --no-analytics >"$tmp/log" 2>&1 &
    pid=$!
    if wait_http http://127.0.0.1:7709/health; then ok "health: $(curl -s http://127.0.0.1:7709/version)"; else fail "meilisearch did not start: $(tail -5 "$tmp/log")"; fi
    check "index a document" curl -fs -X POST http://127.0.0.1:7709/indexes/flock/documents -H 'Content-Type: application/json' -d '[{"id":1,"name":"flock"}]'
    check "stop" stop "$pid"
    ;;

  typesense)
    "$D/typesense-server" --data-dir "$data" --api-key=flock --api-address=127.0.0.1 --api-port=8199 \
      --peering-address=127.0.0.1 --peering-port=8198 --enable-cors >"$tmp/log" 2>&1 &
    pid=$!
    for _ in $(seq 1 150); do curl -fs http://127.0.0.1:8199/health | grep -q '"ok":true' && break; sleep 0.2; done
    if curl -fs http://127.0.0.1:8199/health | grep -q '"ok":true'; then ok "health"; else fail "typesense did not become healthy: $(tail -5 "$tmp/log")"; fi
    check "create a collection" curl -fs -X POST http://127.0.0.1:8199/collections -H 'X-TYPESENSE-API-KEY: flock' \
      -d '{"name":"flock","fields":[{"name":"name","type":"string"}]}'
    check "stop" stop "$pid"
    ;;

  rustfs)
    # Upstream's macOS build links Homebrew's liblzma by absolute path; Flock falls back to /usr/lib.
    DYLD_FALLBACK_LIBRARY_PATH=/usr/lib "$D/rustfs" server --address 127.0.0.1:9109 \
      --access-key rustfsadmin --secret-key rustfsadmin "$data" >"$tmp/log" 2>&1 &
    pid=$!
    if wait_port 9109; then ok "rustfs listens: HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9109/)"; else fail "rustfs did not start: $(tail -5 "$tmp/log")"; fi
    check "stop" stop "$pid"
    ;;

  keycloak)
    # Runs Java as Flock does (internal/catalog/kinds.go), from folders with a space like
    # "Application Support". A first start rebuilds Keycloak and exits with 10 to be relaunched,
    # which Flock's supervisor does.
    home="$tmp/with space"; kc_data="$tmp/kc data"
    mv "$D" "$home"; mkdir -p "$kc_data"
    kc_start() {
      KC_BOOTSTRAP_ADMIN_USERNAME=admin KC_BOOTSTRAP_ADMIN_PASSWORD=admin "$home/jre/bin/java" \
        -Xms64m -Xmx512m -XX:MaxMetaspaceSize=256m -XX:+ExitOnOutOfMemoryError -XX:+UseG1GC -Dfile.encoding=UTF-8 \
        --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
        --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --enable-native-access=ALL-UNNAMED \
        -Djava.util.concurrent.ForkJoinPool.common.threadFactory=io.quarkus.bootstrap.forkjoin.QuarkusForkJoinWorkerThreadFactory \
        -Djava.util.logging.manager=org.jboss.logmanager.LogManager -Dpicocli.disable.closures=true -Djava.awt.headless=true \
        "-Dkc.home.dir=$home" "-Djboss.server.config.dir=$home/conf" "-Dkeycloak.theme.dir=$home/themes" "-Dkc.db-url-path=$kc_data" \
        -cp "$home/lib/quarkus-run.jar" io.quarkus.bootstrap.runner.QuarkusEntryPoint \
        start-dev --http-host=127.0.0.1 --http-port=8189 --http-management-port=8190 --health-enabled=true "--db-url-properties=;WRITE_DELAY=0" >>"$tmp/log" 2>&1 &
      pid=$!
    }
    kc_ready() {
      for _ in $(seq 1 1200); do
        curl -fs http://127.0.0.1:8190/health/ready >/dev/null && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
          wait "$pid"; [[ $? == 10 ]] || return 1
          kc_start
        fi
        sleep 0.2
      done
      return 1
    }
    check "java: $("$home/jre/bin/java" -version 2>&1 | head -1)" "$home/jre/bin/java" -version
    kc_start
    if kc_ready; then ok "keycloak is ready"; else fail "keycloak did not start: $(tail -20 "$tmp/log")"; fi
    token="$(curl -fs -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
      http://127.0.0.1:8189/realms/master/protocol/openid-connect/token | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
    check "admin login" test -n "$token"
    check "create a realm" curl -fs -X POST http://127.0.0.1:8189/admin/realms -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' -d '{"realm":"flock","enabled":true}'
    check "binds to 127.0.0.1 only" bash -c '! curl -fs -m 2 "http://$(ipconfig getifaddr en0 2>/dev/null || hostname -I | cut -d" " -f1):8189/" >/dev/null'
    # Killed, as on Windows, where Flock has no graceful way to stop it.
    kill -9 "$pid"; wait "$pid" 2>/dev/null
    check "database is outside the package" test -n "$(find "$kc_data" -name '*.mv.db' -print -quit)"
    kc_start
    if kc_ready; then ok "restarts after being killed"; else fail "keycloak did not restart: $(tail -20 "$tmp/log")"; fi
    check "the realm survived" curl -fs http://127.0.0.1:8189/realms/flock
    check "stops gracefully" stop "$pid"
    ;;

  cloudflared)
    # Flock needs --allowed-mail (protected quick tunnels): without it a share would be unprotected.
    check "$("$D/cloudflared" --version 2>&1 | head -1)" "$D/cloudflared" --version
    check "has --allowed-mail" bash -c '"$1" tunnel --help 2>&1 | grep -q -- --allowed-mail' _ "$D/cloudflared"
    ;;

  node)
    check "node $("$D/bin/node" --version)" "$D/bin/node" -e 'require("crypto").createHash("sha256").update("x").digest("hex")'
    # npm starts with #!/usr/bin/env node: the package's node has to come first on PATH.
    check "npm $(PATH="$D/bin:$PATH" "$D/bin/npm" --version 2>&1)" env PATH="$D/bin:$PATH" "$D/bin/npm" --version
    ;;

  *) fail "no smoke test for $PKG" ;;
esac

exit $failed
