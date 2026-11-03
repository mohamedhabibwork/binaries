# Smoke-tests a service package on Windows the way Flock runs it: unpack (dropping a single
# top-level folder, as Flock does), initialise a data directory, start on 127.0.0.1, talk to it
# with its own client, shut down. With $env:SIGNER_WINDOWS set, the main executable must carry a valid
# Authenticode signature whose subject matches that regex (the vendor's, for mirrored packages).
# Valkey has its own, more thorough test: scripts/smoke-valkey.ps1.
# Usage: scripts/windows/smoke-service.ps1 -Package <name> -Archive <zip>
param(
    [Parameter(Mandatory)] [string] $Package,
    [Parameter(Mandatory)] [string] $Archive
)
$ErrorActionPreference = 'Stop'

$tmp = Join-Path $env:RUNNER_TEMP "smoke-$Package"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
$D = Join-Path $tmp 'pkg'
# Forward slashes: MySQL, MariaDB and MongoDB all accept them, and they need no escaping.
$data = (Join-Path $tmp 'data') -replace '\\', '/'
New-Item -ItemType Directory -Force $D, $data | Out-Null
$results = [System.Collections.Generic.List[string]]::new()
$failed = $false

function Check([string] $name, [scriptblock] $test) {
    # Printed as it starts, so a check that hangs shows up in the log.
    Write-Output "$(Get-Date -Format HH:mm:ss) $name"
    try { $r = & $test; $results.Add("| $name | ✓ $r |") }
    catch { $results.Add("| $name | ✗ $($_.Exception.Message) |"); $script:failed = $true }
}
# Arguments go in as one array: passed loose to a PowerShell function, -h127.0.0.1 and
# --version would be taken apart as PowerShell's own parameter syntax.
function Invoke-Native([string] $exe, [string[]] $arguments) {
    $out = & $exe @arguments 2>&1 | Out-String
    if ($LASTEXITCODE) { throw "exit $LASTEXITCODE`: $($out.Trim() | Select-Object -Last 1)" }
    $out.Trim()
}
function Wait-Port([int] $port, $proc, [string] $log) {
    for ($i = 0; $i -lt 300; $i++) {
        $c = [System.Net.Sockets.TcpClient]::new()
        try { $c.Connect('127.0.0.1', $port); return } catch { Start-Sleep -Milliseconds 200 } finally { $c.Dispose() }
        if ($proc.HasExited) { break }
    }
    $tail = if (Test-Path $log) { (Get-Content $log -Tail 5) -join ' / ' } else { '' }
    throw "nothing listening on $port`: $tail"
}
function Wait-Http([string] $url) {
    for ($i = 0; $i -lt 300; $i++) {
        try { return Invoke-RestMethod $url -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 200 }
    }
    throw "$url did not answer"
}
function Start-Server([string] $exe, [string[]] $arguments) {
    Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput "$tmp/out.log" -RedirectStandardError "$tmp/err.log"
}
function Stop-Server($proc) {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    $proc.WaitForExit(10000) | Out-Null
}

# Windows' own tar (bsdtar, unpacks zip): GNU tar from Git would take D:\... for a remote host.
& "$env:SystemRoot/System32/tar.exe" -xf $Archive -C $D
if ($LASTEXITCODE) { throw "could not unpack $Archive" }
$entries = @(Get-ChildItem $D)
if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $D = $entries[0].FullName }
$results.Add("| package | $(Split-Path -Leaf $Archive) |")

if ($env:SIGNER_WINDOWS) {
    $main = @{ mysql = 'bin/mysqld.exe'; mongodb = 'bin/mongod.exe'; node = 'node.exe' }[$Package]
    Check "Authenticode signature of $main" {
        $sig = Get-AuthenticodeSignature (Join-Path $D $main)
        if ($sig.Status -ne 'Valid') { throw "status $($sig.Status)" }
        if ($sig.SignerCertificate.Subject -notmatch $env:SIGNER_WINDOWS) { throw "signed by $($sig.SignerCertificate.Subject)" }
        $sig.SignerCertificate.Subject
    }
}

switch ($Package) {
    'postgres' {
        $bin = Join-Path $D 'bin'
        # initdb creates the data directory itself: on one that exists it fails to set permissions.
        Remove-Item -Recurse -Force $data
        Check 'initdb' { Invoke-Native "$bin/initdb.exe" @('-D', $data, '-U', 'postgres', '--auth=trust', '-E', 'UTF8', '--locale=C') | Out-Null }
        # Through pg_ctl: the runner is an administrator, and postgres.exe refuses to run as one;
        # pg_ctl starts it with administrator rights dropped.
        # Not through Invoke-Native: the server pg_ctl starts inherits its output handles, so
        # capturing them waits as long as the server runs. Wait for pg_ctl itself only.
        Check 'start (pg_ctl)' {
            $ctl = Start-Process -FilePath "$bin/pg_ctl.exe" -PassThru -NoNewWindow `
                -ArgumentList 'start', '-w', '-t', '60', '-D', $data, '-l', "$tmp/server.log", '-o', '"-p 54329 -c listen_addresses=127.0.0.1"' `
                -RedirectStandardOutput "$tmp/pg_ctl.out" -RedirectStandardError "$tmp/pg_ctl.err"
            if (-not $ctl.WaitForExit(90000)) { throw 'pg_ctl start did not return' }
            if ($ctl.ExitCode) { throw "pg_ctl start: exit $($ctl.ExitCode): $((Get-Content "$tmp/pg_ctl.err", "$tmp/server.log" -ErrorAction SilentlyContinue) -join ' / ')" }
            Wait-Port 54329 $ctl "$tmp/server.log"
        }
        $psql = @('-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At')
        Check 'query' { Invoke-Native "$bin/psql.exe" ($psql + @('-c', 'select version()')) }
        Check 'contrib extensions (pgcrypto, pg_trgm, hstore, citext)' {
            Invoke-Native "$bin/psql.exe" ($psql + @('-c', 'create extension pgcrypto; create extension pg_trgm; create extension hstore; create extension citext',
                '-c', "select encode(digest('flock', 'sha256'), 'hex'), gen_random_uuid(), similarity('flock', 'block'), 'a=>1'::hstore, 'A'::citext = 'a'")) | Out-Null
        }
        Check 'headers and import library for extensions' {
            $server = (Invoke-Native "$bin/pg_config.exe" @('--includedir-server')).Trim()
            $libdir = (Invoke-Native "$bin/pg_config.exe" @('--libdir')).Trim()
            foreach ($f in (Join-Path $server 'postgres.h'), (Join-Path $server 'fmgr.h'), (Join-Path $libdir 'postgres.lib')) {
                if (-not (Test-Path $f)) { throw "no $f" }
            }
        }
        Check 'createdb' { Invoke-Native "$bin/createdb.exe" @('-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', 'flock') }
        Check 'pg_dump | pg_restore' {
            Invoke-Native "$bin/pg_dump.exe" @('-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-Fc', '-f', "$tmp/dump", 'postgres')
            Invoke-Native "$bin/pg_restore.exe" @('-l', "$tmp/dump") | Out-Null
        }
        Check 'pg_ctl stop' { Invoke-Native "$bin/pg_ctl.exe" @('stop', '-D', $data, '-m', 'fast') | Out-Null }
    }
    { $_ -in 'mysql', 'mariadb' } {
        $bin = Join-Path $D 'bin'
        if ($Package -eq 'mariadb') {
            # mariadb-install-db creates the data directory itself.
            Remove-Item -Recurse -Force $data
            Check 'install-db' {
                Invoke-Native "$bin/mariadb-install-db.exe" @("--datadir=$data") | Out-Null
                if (-not (Test-Path "$data/mysql")) { throw 'no system tables in the data directory' }
            }
            $server = "$bin/mariadbd.exe"; $client = "$bin/mariadb.exe"; $admin = "$bin/mariadb-admin.exe"
            $serverArgs = @('--no-defaults', "--basedir=$D", "--datadir=$data")
        } else {
            Check 'initialize' { Invoke-Native "$bin/mysqld.exe" @('--no-defaults', '--initialize-insecure', "--basedir=$D", "--datadir=$data") | Out-Null }
            $server = "$bin/mysqld.exe"; $client = "$bin/mysql.exe"; $admin = "$bin/mysqladmin.exe"
            $serverArgs = @('--no-defaults', "--basedir=$D", "--datadir=$data", '--mysqlx=OFF')
        }
        $p = Start-Server $server ($serverArgs + @('--port=33069', '--bind-address=127.0.0.1'))
        Check 'start' { Wait-Port 33069 $p "$tmp/err.log" }
        $sql = @('--no-defaults', '-h127.0.0.1', '-P33069', '-uroot')
        Check 'query' {
            Invoke-Native $client ($sql + @('-e', 'create database flock; create table flock.t (id int primary key, v json) engine=innodb; insert into flock.t values (1, json_object(''a'', 1))')) | Out-Null
            # The last line: MariaDB 11.4+ clients warn about TLS verification first.
            ((Invoke-Native $client ($sql + @('-N', '-e', 'select version()'))) -split "`n")[-1].Trim()
        }
        Check 'shutdown' { Invoke-Native $admin ($sql + @('shutdown')) | Out-Null; if (-not $p.WaitForExit(30000)) { throw 'did not exit' } }
    }
    'mongodb' {
        Check 'version' { ((Invoke-Native "$D/bin/mongod.exe" @('--version')) -split "
")[0] }
        $p = Start-Server "$D/bin/mongod.exe" @('--dbpath', $data, '--port', '27029', '--bind_ip', '127.0.0.1')
        Check 'accepts connections' { Wait-Port 27029 $p "$tmp/out.log" }
        Stop-Server $p
    }
    'meilisearch' {
        $p = Start-Server "$D/meilisearch.exe" @('--db-path', "$data/data.ms", '--http-addr', '127.0.0.1:7709', '--env', 'development', '--no-analytics')
        Check 'health' { Wait-Http 'http://127.0.0.1:7709/health' | Out-Null; (Invoke-RestMethod 'http://127.0.0.1:7709/version').pkgVersion }
        Check 'index a document' {
            Invoke-RestMethod -Method Post 'http://127.0.0.1:7709/indexes/flock/documents' -ContentType 'application/json' -Body '[{"id":1,"name":"flock"}]' | Out-Null
        }
        Stop-Server $p
    }
    'rustfs' {
        $p = Start-Server "$D/rustfs.exe" @('server', '--address', '127.0.0.1:9109', '--access-key', 'rustfsadmin', '--secret-key', 'rustfsadmin', $data)
        Check 'listens' { Wait-Port 9109 $p "$tmp/err.log" }
        Stop-Server $p
    }
    'keycloak' {
        # Runs Java as Flock does (internal/catalog/kinds.go), from folders with a space. A first
        # start rebuilds Keycloak and exits for a relaunch, which Flock's supervisor does. Stopping
        # kills the process, as on Windows Flock has no graceful way, and the data has to survive it.
        $home_ = Join-Path $tmp 'with space'
        $kcData = Join-Path $tmp 'kc data'
        Move-Item $D $home_
        New-Item -ItemType Directory -Force $kcData | Out-Null
        $h = $home_ -replace '\\', '/'
        $kd = $kcData -replace '\\', '/'
        $env:KC_BOOTSTRAP_ADMIN_USERNAME = 'admin'
        $env:KC_BOOTSTRAP_ADMIN_PASSWORD = 'admin'
        $kcArgs = @('-Xms64m', '-Xmx512m', '-XX:MaxMetaspaceSize=256m', '-XX:+ExitOnOutOfMemoryError', '-XX:+UseG1GC', '-Dfile.encoding=UTF-8',
            '--add-opens=java.base/java.util=ALL-UNNAMED', '--add-opens=java.base/java.util.concurrent=ALL-UNNAMED',
            '--add-opens=java.base/java.security=ALL-UNNAMED', '--add-opens=java.base/java.lang=ALL-UNNAMED', '--enable-native-access=ALL-UNNAMED',
            '-Djava.util.concurrent.ForkJoinPool.common.threadFactory=io.quarkus.bootstrap.forkjoin.QuarkusForkJoinWorkerThreadFactory',
            '-Djava.util.logging.manager=org.jboss.logmanager.LogManager', '-Dpicocli.disable.closures=true', '-Djava.awt.headless=true',
            "-Dkc.home.dir=$h", "-Djboss.server.config.dir=$h/conf", "-Dkeycloak.theme.dir=$h/themes", "-Dkc.db-url-path=$kd",
            '-cp', "$home_\lib\quarkus-run.jar", 'io.quarkus.bootstrap.runner.QuarkusEntryPoint',
            'start-dev', '--http-host=127.0.0.1', '--http-port=8189', '--http-management-port=8190', '--health-enabled=true', '--db-url-properties=;WRITE_DELAY=0') | ForEach-Object { '"' + $_ + '"' }
        function Start-Keycloak { Start-Server "$home_/jre/bin/java.exe" $kcArgs }
        function Wait-Keycloak($first) {
            $proc = $first
            for ($i = 0; $i -lt 480; $i++) {
                try { Invoke-RestMethod 'http://127.0.0.1:8190/health/ready' -TimeoutSec 2 | Out-Null; return $proc } catch { Start-Sleep -Milliseconds 500 }
                if ($proc.HasExited) { $proc = Start-Keycloak }
            }
            throw "keycloak did not get ready: $((Get-Content "$tmp/out.log" -Tail 20) -join ' / ')"
        }
        $p = Start-Keycloak
        Check 'ready' { $script:p = Wait-Keycloak $p }
        Check 'admin login, create a realm' {
            $t = Invoke-RestMethod -Method Post 'http://127.0.0.1:8189/realms/master/protocol/openid-connect/token' -Body @{ grant_type = 'password'; client_id = 'admin-cli'; username = 'admin'; password = 'admin' }
            Invoke-RestMethod -Method Post 'http://127.0.0.1:8189/admin/realms' -Headers @{ Authorization = "Bearer $($t.access_token)" } -ContentType 'application/json' -Body '{"realm":"flock","enabled":true}' | Out-Null
        }
        Stop-Server $p
        Check 'database is outside the package' { if (-not (Get-ChildItem $kcData -Recurse -Filter '*.mv.db')) { throw 'no database file' } }
        $p = Start-Keycloak
        Check 'restarts after being killed' { $script:p = Wait-Keycloak $p }
        Check 'the realm survived' { Invoke-RestMethod 'http://127.0.0.1:8189/realms/flock' | Out-Null }
        Stop-Server $p
    }
    'cloudflared' {
        # Flock needs --allowed-mail (protected quick tunnels): without it a share would be unprotected.
        Check 'cloudflared' { ((Invoke-Native "$D/cloudflared.exe" @('--version')) -split "`n")[0] }
        Check 'has --allowed-mail' { if (-not ((Invoke-Native "$D/cloudflared.exe" @('tunnel', '--help')) -match '--allowed-mail')) { throw 'no --allowed-mail' } }
    }
    'node' {
        Check 'node' { Invoke-Native "$D/node.exe" @('-e', 'console.log(process.version, require(''crypto'').createHash(''sha256'').update(''x'').digest(''hex'').length)') }
        Check 'npm' { Invoke-Native "$D/npm.cmd" @('--version') }
    }
    'php' {
        $php = Join-Path $D 'php.exe'
        Check 'php' { ((Invoke-Native $php @('-n', '-v')) -split "`n")[0] }
        Check 'thread safe' { $zts = Invoke-Native $php @('-n', '-r', 'echo PHP_ZTS;'); if ($zts -ne '1') { throw "PHP_ZTS is $zts" } }
        Check 'php-cgi' { ((Invoke-Native (Join-Path $D 'php-cgi.exe') @('-n', '-v')) -split "`n")[0] }
        # The bundled extensions Laravel apps load: compiled in (zip, up to PHP 8.1) or a DLL in
        # ext/ (gd was php_gd2.dll before PHP 8.0).
        $exts = 'curl', 'fileinfo', 'gd', 'intl', 'mbstring', 'openssl', 'pdo_mysql', 'pdo_pgsql', 'pdo_sqlite', 'sodium', 'zip'
        Check 'bundled extensions' {
            $builtin = (Invoke-Native $php @('-n', '-m')) -split "`r?`n"
            $flags = @('-n', '-d', "extension_dir=$(Join-Path $D 'ext')")
            foreach ($e in $exts) {
                if ($builtin -contains $e) { continue }
                if ($e -eq 'gd' -and -not (Test-Path (Join-Path $D 'ext/php_gd.dll'))) { $e = 'gd2' }
                $flags += @('-d', "extension=$e")
            }
            $out = Invoke-Native $php ($flags + @('-r', 'echo implode(",", get_loaded_extensions());'))
            if ($out -match 'Warning|Unable to load') { throw $out }
            $missing = $exts | Where-Object { $out -notmatch "(^|,)$_(,|$)" }
            if ($missing) { throw "not loaded: $($missing -join ', ')" }
            "$($exts.Count) loaded"
        }
    }
    default { $results.Add("| $Package | ✗ no smoke test |"); $failed = $true }
}

$table = @("### $Package", '', '| check | result |', '|---|---|') + $results
$table | Write-Output
if ($env:GITHUB_STEP_SUMMARY) { $table | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { exit 1 }
