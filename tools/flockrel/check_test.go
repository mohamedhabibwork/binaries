package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type fakeSources struct {
	cycles map[string][]eolCycle
	github map[string][]string
	rcs    map[string]string
}

func (f fakeSources) eolCycles(p string) ([]eolCycle, error)       { return f.cycles[p], nil }
func (f fakeSources) githubVersions(r, _ string) ([]string, error) { return f.github[r], nil }
func (f fakeSources) phpRCs() (map[string]string, error)           { return f.rcs, nil }

func cyc(cycle, released string, eol, lts any) eolCycle {
	e, _ := json.Marshal(eol)
	l, _ := json.Marshal(lts)
	return eolCycle{Cycle: cycle, ReleaseDate: released, EOL: e, LTS: l}
}

func TestCheck(t *testing.T) {
	now := time.Date(2026, 11, 30, 0, 0, 0, 0, time.UTC)
	var v versions
	if err := json.Unmarshal([]byte(`{
	  "php": {"macos": {"minors": ["8.4", "8.5"], "spc": "2.8.5"},
	          "windows": {"minors": ["8.1", "8.4", "8.5"], "extensions": {
	            "from_source": {"igbinary": {"repo": "igbinary/igbinary", "ref": "3.2.16", "refs": {"8.5": "3.2.17RC1"}},
	                            "apcu": {"repo": "krakjoe/apcu", "ref": "v5.1.28"}},
	            "mongodb": "2.5.5"}}},
	  "frankenphp": {"version": "1.13.0", "minors": ["8.4", "8.5"]},
	  "packages": {
	    "mysql": {"lines": ["8.4", "9.7"], "env": {}},
	    "node": {"lines": ["22", "24", "26"]},
	    "redis": {"lines": ["8.4", "8.10"]},
	    "meilisearch": {"lines": ["1"]},
	    "typesense": {"lines": ["30"]},
	    "keycloak": {"lines": ["26.8"], "env": {"JRE_VERSION": "25.0.5+8"}},
	    "postgres": {"lines": ["18"], "env": {"OPENSSL_VERSION": "3.5.9"}}
	  }}`), &v); err != nil {
		t.Fatal(err)
	}
	src := fakeSources{
		cycles: map[string][]eolCycle{
			"php":         {cyc("8.7", "2027-11-25", false, false), cyc("8.6", "2026-11-19", "2030-12-31", false), cyc("8.5", "2025-11-20", "2029-12-31", false), cyc("8.1", "2021-11-25", "2025-12-31", false)},
			"mysql":       {cyc("10.7", "2026-10-01", "2036-01-01", true), cyc("9.8", "2026-07-01", "2026-10-01", false), cyc("8.4", "2024-04-30", "2032-04-30", true)},
			"nodejs":      {cyc("28", "2026-10-20", "2030-04-30", false), cyc("27", "2026-04-20", "2027-06-01", false), cyc("22", "2024-04-24", "2027-04-30", "2024-10-29")},
			"redis":       {cyc("8.12", "2026-10-01", false, false), cyc("8.8", "2026-05-01", false, false)},
			"meilisearch": {cyc("2.0", "2026-10-01", false, false), cyc("1.55", "2026-09-01", false, false), cyc("1.54", "2026-08-01", "2026-09-01", false)},
			"postgresql":  {cyc("18", "2025-09-25", "2030-11-14", false)},
		},
		github: map[string][]string{
			"typesense/typesense":                              {"31.0", "30.2"},
			"keycloak/keycloak":                                {"26.9.0", "26.8.1"},
			"adoptium/temurin25-binaries":                      {"25.0.6", "25.0.5"},
			"php/frankenphp":                                   {"1.14.0", "1.13.0"},
			"crazywhalecc/static-php-cli":                      {"2.8.5"},
			"openssl/openssl":                                  {"4.0.3", "3.5.10", "3.5.9"},
			"xdebug/xdebug":                                    {"3.6.0", "3.5.3"},
			"open-telemetry/opentelemetry-php-instrumentation": {"1.5.0", "1.4.2"},
			"igbinary/igbinary":                                {"3.2.17", "3.2.16"},
			"krakjoe/apcu":                                     {"5.1.28"},
			"mongodb/mongo-php-driver":                         {"2.5.5", "1.21.12"},
		},
		rcs: map[string]string{"8.5.13": "8.5.13RC1", "8.7.0": "8.7.0RC1", "8.6.1": "8.6.1RC1"},
	}
	findings, problems := check(&v, "--custom-url=xdebug:https://xdebug.org/files/xdebug-3.5.3.tgz\n--custom-url=opentelemetry:https://pecl.php.net/get/opentelemetry-1.4.2.tgz", src, now)
	if len(problems) > 0 {
		t.Errorf("problems: %v", problems)
	}
	got := map[string]finding{}
	for _, f := range findings {
		got[f.Title] = f
	}
	want := []string{
		"New release line: PHP 8.6", // released
		"New release line: PHP 8.7", // a release candidate (patch RCs aren't reported)
		"End of life: PHP 8.1",      // only Windows builds it
		"New release line: MySQL 10.7",
		"New release line: Node.js 28",
		"New release line: Redis 8.12",
		"New release line: Meilisearch 2",
		"New release line: Typesense 31",
		"New release line: Keycloak 26.9",
		"Updates available for pinned versions",
	}
	for _, w := range want {
		if _, ok := got[w]; !ok {
			t.Errorf("missing %q", w)
		}
	}
	if len(findings) != len(want) {
		for _, f := range findings {
			t.Logf("got %q", f.Title)
		}
		t.Errorf("%d findings, want %d", len(findings), len(want))
	}
	if b := got["New release line: PHP 8.6"].Body; !strings.Contains(b, "`php.macos.minors`, `php.windows.minors` (check that the extensions") || !strings.Contains(b, "`frankenphp.minors`") {
		t.Errorf("PHP 8.6 body: %s", b)
	}
	if b := got["New release line: PHP 8.7"].Body; !strings.Contains(b, "release candidate phase (8.7.0RC1)") || !strings.Contains(b, "beta channel only") {
		t.Errorf("PHP 8.7 body: %s", b)
	}
	if b := got["End of life: PHP 8.1"].Body; !strings.Contains(b, "since 2025-12-31") || !strings.Contains(b, "from `php.windows.minors` in") {
		t.Errorf("PHP 8.1 body: %s", b)
	}
	pins := got["Updates available for pinned versions"].Body
	for _, row := range []string{
		"| FrankenPHP | 1.13.0 | 1.14.0 |",
		"| OpenSSL | 3.5.9 | 3.5.10 |", // the same line, not 4.0
		"| xdebug (macOS) | 3.5.3 | 3.6.0 |",
		"| opentelemetry (macOS) | 1.4.2 | 1.5.0 |",
		"| igbinary for PHP 8.5 (Windows) | 3.2.17RC1 | 3.2.17 |",
		"| igbinary (Windows) | 3.2.16 | 3.2.17 |",
	} {
		if !strings.Contains(pins, row) {
			t.Errorf("pins lack %q:\n%s", row, pins)
		}
	}
	for _, not := range []string{"static-php-cli", "apcu", "mongodb"} {
		if strings.Contains(pins, "| "+not) {
			t.Errorf("pins list %s, which is current:\n%s", not, pins)
		}
	}
}

func TestReleaseVersion(t *testing.T) {
	for _, c := range []struct{ tag, prefix, want string }{
		{"jdk-25.0.5+8", "jdk-", "25.0.5"}, // Temurin: the build after the + isn't part of the version
		{"v1.2.3", "", "1.2.3"},
		{"openssl-3.5.9", "openssl-", "3.5.9"},
		{"26.8.1", "", "26.8.1"},
		{"9.2.0-rc1", "", ""},
		{"nightly", "", ""},
	} {
		if got := releaseVersion(c.tag, c.prefix); got != c.want {
			t.Errorf("releaseVersion(%q, %q) = %q, want %q", c.tag, c.prefix, got, c.want)
		}
	}
}

func TestEOLCycle(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		eol  any
		want bool
	}{{"2026-05-31", true}, {"2026-06-01", true}, {"2026-06-02", false}, {true, true}, {false, false}} {
		if _, got := cyc("x", "", c.eol, false).eolSince(now); got != c.want {
			t.Errorf("eol %v: %v, want %v", c.eol, got, c.want)
		}
	}
	if !cyc("22", "", false, "2024-10-29").isLTS() || cyc("23", "", false, false).isLTS() || !cyc("8.4", "", false, true).isLTS() {
		t.Error("isLTS")
	}
}
