package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

// runCheck looks upstream for what versions.json doesn't cover yet and writes the findings
// (scripts/upstream-issues.sh turns them into issues; nothing here changes what we build):
//
//	line  a release line newer than the newest one we build (MySQL and MariaDB: LTS lines only,
//	      Node.js: even majors only; never pre-releases)
//	eol   a line we build that has reached its end of life (endoflife.date)
//	pins  versions pinned in versions.json or a build script with a newer stable release
func runCheck(args []string) error {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	versionsPath := fs.String("versions", "versions.json", "versions file")
	buildSh := fs.String("php-build", "packages/php/macos/build.sh", "PHP macOS build script (pins xdebug and opentelemetry)")
	out := fs.String("out", "findings.json", "where to write the findings")
	fs.Parse(args)

	v, err := loadVersions(*versionsPath)
	if err != nil {
		return err
	}
	script, err := os.ReadFile(*buildSh)
	if err != nil {
		return err
	}
	findings, problems := check(v, string(script), liveSources{}, time.Now().UTC())
	for _, p := range problems {
		fmt.Fprintf(os.Stderr, "::warning::%s\n", p)
	}
	for _, f := range findings {
		fmt.Fprintf(os.Stderr, "%-5s %s\n", f.Kind, f.Title)
	}
	data, err := json.MarshalIndent(findings, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(*out, append(data, '\n'), 0o644)
}

// finding is one issue to be: Title identifies it (an issue with the same title, open or closed,
// is the same finding).
type finding struct {
	Kind  string `json:"kind"` // line, eol, pins
	Title string `json:"title"`
	Body  string `json:"body"`
}

// eolCycle is a release line on endoflife.date. EOL and LTS are a date, true or false.
type eolCycle struct {
	Cycle       string          `json:"cycle"`
	ReleaseDate string          `json:"releaseDate"`
	EOL         json.RawMessage `json:"eol"`
	LTS         json.RawMessage `json:"lts"`
}

// eolSince returns when the cycle reached its end of life, if it has by now.
func (c eolCycle) eolSince(now time.Time) (string, bool) {
	var date string
	if json.Unmarshal(c.EOL, &date) == nil {
		t, err := time.Parse(time.DateOnly, date)
		return date, err == nil && !now.Before(t)
	}
	var b bool
	return "", json.Unmarshal(c.EOL, &b) == nil && b
}

func (c eolCycle) isLTS() bool {
	var b bool
	if json.Unmarshal(c.LTS, &b) == nil {
		return b
	}
	var date string // the date it became (or becomes) LTS
	return json.Unmarshal(c.LTS, &date) == nil && date != ""
}

// sources is where check looks; tests replace it.
type sources interface {
	eolCycles(product string) ([]eolCycle, error)
	githubVersions(repo, tagPrefix string) ([]string, error) // stable versions, prefix and "v" removed
	phpRCs() (map[string]string, error)                      // php.net's release candidates: "8.6.0" → "8.6.0RC3"
}

type liveSources struct{}

func (liveSources) phpRCs() (map[string]string, error) { return phpRCs() }

func (liveSources) eolCycles(product string) ([]eolCycle, error) {
	var cycles []eolCycle
	return cycles, getJSON("https://endoflife.date/api/"+product+".json", &cycles)
}

// releaseVersion is the stable version a release tag names ("" for none), without the tag's prefix,
// a "v" or a build after a + (Temurin's jdk-25.0.5+8 is 25.0.5).
func releaseVersion(tag, prefix string) string {
	s, _, _ := strings.Cut(strings.TrimPrefix(strings.TrimPrefix(tag, prefix), "v"), "+")
	if !stableVersion.MatchString(s) {
		return ""
	}
	return s
}

// githubVersions uses a repository's published releases, or its tags when it publishes none.
func (liveSources) githubVersions(repo, prefix string) ([]string, error) {
	var rels []release
	if err := getJSON("https://api.github.com/repos/"+repo+"/releases?per_page=100", &rels); err != nil {
		return nil, err
	}
	var names []string
	for _, r := range rels {
		if !r.Draft && !r.Prerelease {
			names = append(names, r.TagName)
		}
	}
	if len(names) == 0 {
		var tags []struct {
			Name string `json:"name"`
		}
		if err := getJSON("https://api.github.com/repos/"+repo+"/tags?per_page=100", &tags); err != nil {
			return nil, err
		}
		for _, t := range tags {
			names = append(names, t.Name)
		}
	}
	var out []string
	for _, n := range names {
		if s := releaseVersion(n, prefix); s != "" {
			out = append(out, s)
		}
	}
	return out, nil
}

// lineSources: where each package's release lines are listed upstream.
var lineSources = map[string]struct {
	eol        string // endoflife.date product
	github     string // or GitHub releases (no end-of-life data)
	ltsOnly    bool
	evenMajors bool
}{
	"postgres":    {eol: "postgresql"},
	"mariadb":     {eol: "mariadb", ltsOnly: true},
	"mysql":       {eol: "mysql", ltsOnly: true},
	"mongodb":     {eol: "mongodb"},
	"redis":       {eol: "redis"},
	"valkey":      {eol: "valkey"},
	"node":        {eol: "nodejs", evenMajors: true},
	"meilisearch": {eol: "meilisearch"},
	"typesense":   {github: "typesense/typesense"},
	"rustfs":      {github: "rustfs/rustfs"},
	"keycloak":    {github: "keycloak/keycloak"},
	"cloudflared": {github: "cloudflare/cloudflared"},
	"pgvector":    {github: "pgvector/pgvector"},
	"timescaledb": {github: "timescale/timescaledb"},
	"postgis":     {github: "postgis/postgis"},
	"pgrouting":   {github: "pgRouting/pgrouting"},
}

var displayNames = map[string]string{
	"php": "PHP", "postgres": "PostgreSQL", "mariadb": "MariaDB", "mysql": "MySQL", "mongodb": "MongoDB",
	"redis": "Redis", "valkey": "Valkey", "node": "Node.js", "meilisearch": "Meilisearch",
	"typesense": "Typesense", "rustfs": "RustFS", "keycloak": "Keycloak", "cloudflared": "cloudflared", "pgvector": "pgvector",
	"timescaledb": "TimescaleDB", "postgis": "PostGIS", "pgrouting": "pgRouting",
}

// truncate cuts a version to the parts a line has: (1.54, 1) → 1, (8.10.2, 2) → 8.10.
func truncate(version string, parts int) string {
	p := strings.Split(version, ".")
	if len(p) > parts {
		p = p[:parts]
	}
	return strings.Join(p, ".")
}

func newestOf(vs []string) string {
	best := ""
	for _, v := range vs {
		if best == "" || cmpVersion(v, best) > 0 {
			best = v
		}
	}
	return best
}

// check returns the findings, and problems (sources that couldn't be read) to warn about.
func check(v *versions, phpBuildScript string, src sources, now time.Time) (findings []finding, problems []string) {
	today := now.Format(time.DateOnly)

	// lineFindings reports, for one product, lines newer than the newest a config builds and lines
	// that reached their end of life: one finding per line, listing the configs it concerns (PHP
	// has three: macOS, Windows, FrankenPHP; the services one each). rcs are lines that only have
	// a release candidate so far, with its version.
	lineFindings := func(name string, configs []lineConfig, cycles []eolCycle, upstream []string, rcs map[string]string, ltsOnly, evenMajors bool) {
		var all []string
		for _, c := range configs {
			all = append(all, c.lines...)
		}
		if len(all) == 0 {
			return
		}
		parts := len(strings.Split(all[0], "."))
		candidates := map[string]bool{}
		for _, c := range cycles {
			if c.ReleaseDate > today || (ltsOnly && !c.isLTS()) || !stableVersion.MatchString(c.Cycle) {
				continue
			}
			candidates[truncate(c.Cycle, parts)] = true
		}
		for _, u := range upstream {
			candidates[truncate(u, parts)] = true
		}
		var newLines []string
		for l := range candidates {
			major := strings.Split(l, ".")[0]
			if evenMajors && len(major) > 0 && (major[len(major)-1]-'0')%2 == 1 {
				continue
			}
			newLines = append(newLines, l)
		}
		sort.Slice(newLines, func(i, j int) bool { return cmpVersion(newLines[i], newLines[j]) < 0 })
		for _, l := range newLines {
			var missing []string
			for _, c := range configs {
				if len(c.lines) > 0 && !slicesContains(c.lines, l) && cmpVersion(l, newestOf(c.lines)) > 0 {
					missing = append(missing, c.where+c.note)
				}
			}
			if len(missing) == 0 {
				continue
			}
			if rc := rcs[l]; rc != "" {
				findings = append(findings, finding{Kind: "line", Title: fmt.Sprintf("New release line: %s %s", name, l),
					Body: fmt.Sprintf("%s %s is in its release candidate phase (%s): add `%s` to %s in versions.json to build "+
						"its release candidates. They go to the beta channel only, never to stable; the release itself replaces "+
						"them and starts in the experimental channel, to promote once you've tried it in Flock.\n\n"+
						"Close this issue to skip the line; it won't be reported again.", name, l, rc, l, strings.Join(missing, ", "))})
				continue
			}
			findings = append(findings, finding{Kind: "line", Title: fmt.Sprintf("New release line: %s %s", name, l),
				Body: fmt.Sprintf("%s %s is out and not built yet: add `%s` to %s in versions.json, test it on a branch, "+
					"and promote it once you've tried it in Flock (it starts in the experimental channel).\n\n"+
					"Close this issue to skip the line; it won't be reported again.", name, l, l, strings.Join(missing, ", "))})
		}
		for _, c := range cycles {
			var in []string
			for _, cfg := range configs {
				if slicesContains(cfg.lines, c.Cycle) {
					in = append(in, cfg.where)
				}
			}
			if len(in) == 0 {
				continue // also a coarser line (Meilisearch 1), which doesn't end with one of its minors
			}
			if since, ok := c.eolSince(now); ok {
				when := ""
				if since != "" {
					when = " (since " + since + ")"
				}
				findings = append(findings, finding{Kind: "eol", Title: fmt.Sprintf("End of life: %s %s", name, c.Cycle),
					Body: fmt.Sprintf("%s %s no longer gets updates upstream%s. We still build its last release; remove `%s` "+
						"from %s in versions.json to stop offering it, or close this issue to keep it (it won't be "+
						"reported again).", name, c.Cycle, when, c.Cycle, strings.Join(in, ", "))})
			}
		}
	}

	// PHP: macOS, Windows and FrankenPHP each list their minors.
	// A new minor is reported from its first release candidate on (patch RCs are left out).
	if cycles, err := src.eolCycles("php"); err != nil {
		problems = append(problems, "php: "+err.Error())
	} else {
		rcs := map[string]string{}
		var upstream []string
		if all, err := src.phpRCs(); err != nil {
			problems = append(problems, "php release candidates: "+err.Error())
		} else {
			for _, rc := range all {
				if newMinorRC.MatchString(rc) {
					rcs[minorOf(rc)] = rc
					upstream = append(upstream, minorOf(rc))
				}
			}
		}
		for _, c := range cycles {
			if c.ReleaseDate != "" && c.ReleaseDate <= today {
				delete(rcs, c.Cycle) // released meanwhile
			}
		}
		lineFindings("PHP", []lineConfig{
			{"`php.macos.minors`", v.PHP.MacOS.Minors, ""},
			{"`php.windows.minors`", v.PHP.Windows.Minors, " (check that the extensions in `php.windows.extensions` support it)"},
			{"`frankenphp.minors`", v.FrankenPHP.Minors, ""},
		}, cycles, upstream, rcs, false, false)
	}
	for _, pkg := range v.packageNames() {
		s, ok := lineSources[pkg]
		if !ok {
			problems = append(problems, pkg+": no upstream source for release lines")
			continue
		}
		var cycles []eolCycle
		var upstream []string
		var err error
		if s.eol != "" {
			cycles, err = src.eolCycles(s.eol)
		} else {
			upstream, err = src.githubVersions(s.github, "")
		}
		if err != nil {
			problems = append(problems, pkg+": "+err.Error())
			continue
		}
		name := displayNames[pkg]
		if name == "" {
			name = pkg
		}
		lineFindings(name, []lineConfig{{fmt.Sprintf("`packages.%s.lines`", pkg), v.Packages[pkg].Lines, ""}}, cycles, upstream, nil, s.ltsOnly, s.evenMajors)
	}

	// Pinned versions: one finding listing everything with a newer stable release.
	type pin struct{ name, current, repo, prefix, where, sameLine string }
	pins := []pin{
		{"FrankenPHP", v.FrankenPHP.Version, "php/frankenphp", "", "`frankenphp.version` (then raise `frankenphp.*.build`)", ""},
		{"static-php-cli", v.PHP.MacOS.SPC, "crazywhalecc/static-php-cli", "", "`php.macos.spc` (then raise `php.macos.build` and `frankenphp.macos.build`)", ""},
	}
	if cmake := envPin(v, "CMAKE_VERSION"); cmake != "" {
		pins = append(pins, pin{"CMake", cmake, "Kitware/CMake", "", "`CMAKE_VERSION` of the PostgreSQL extensions (macOS builds only; no rebuild needed)", ""})
	}
	for _, lib := range []struct{ name, key, repo, prefix string }{
		{"GEOS", "GEOS_VERSION", "libgeos/geos", ""},
		{"PROJ", "PROJ_VERSION", "OSGeo/PROJ", ""},
		{"libxml2", "LIBXML2_VERSION", "GNOME/libxml2", "v"},
		{"Boost", "BOOST_VERSION", "boostorg/boost", "boost-"},
	} {
		if current := envPin(v, lib.key); current != "" {
			pins = append(pins, pin{lib.name, current, lib.repo, lib.prefix, "`" + lib.key + "` of postgis or pgrouting (then raise their macOS and Linux `build`)", ""})
		}
	}
	if jre := envPin(v, "JRE_VERSION"); jre != "" {
		version, _, _ := strings.Cut(jre, "+")
		pins = append(pins, pin{"Temurin JRE (Keycloak)", version, "adoptium/temurin" + truncate(version, 1) + "-binaries", "jdk-",
			"`JRE_VERSION` of keycloak, with Temurin's build after the + (then raise its `build`)", ""})
	}
	if ossl := opensslPin(v); ossl != "" {
		pins = append(pins, pin{"OpenSSL", ossl, "openssl/openssl", "openssl-", "`OPENSSL_VERSION` of postgres and mariadb (then raise their macOS and Linux `build`)", truncate(ossl, 2)})
	}
	for _, ext := range []struct{ name, repo string }{{"xdebug", "xdebug/xdebug"}, {"opentelemetry", "open-telemetry/opentelemetry-php-instrumentation"}} {
		if m := regexp.MustCompile(ext.name + `-([0-9.]+)\.tgz`).FindStringSubmatch(phpBuildScript); m != nil {
			pins = append(pins, pin{ext.name + " (macOS)", m[1], ext.repo, "", "`packages/php/macos/build.sh` (then raise `php.macos.build` and `frankenphp.macos.build`)", ""})
		}
	}
	exts := v.PHP.Windows.Extensions
	for _, name := range sortedKeys(exts.FromSource) {
		e := exts.FromSource[name]
		pins = append(pins, pin{name + " (Windows)", strings.TrimPrefix(e.Ref, "v"), e.Repo, "", "`php.windows.extensions.from_source." + name + ".ref` (then raise `php.windows.extensions.build`)", ""})
	}
	if exts.MongoDB != "" {
		pins = append(pins, pin{"mongodb (Windows)", exts.MongoDB, "mongodb/mongo-php-driver", "", "`php.windows.extensions.mongodb` (then raise `php.windows.extensions.build`)", ""})
	}
	var rows []string
	for _, p := range pins {
		vs, err := src.githubVersions(p.repo, p.prefix)
		if err != nil {
			problems = append(problems, p.name+": "+err.Error())
			continue
		}
		if p.sameLine != "" {
			var in []string
			for _, x := range vs {
				if inLine(x, p.sameLine) {
					in = append(in, x)
				}
			}
			vs = in
		}
		if n := newestOf(vs); n != "" && cmpVersion(n, p.current) > 0 {
			rows = append(rows, fmt.Sprintf("| %s | %s | %s | %s |", p.name, p.current, n, p.where))
		}
	}
	// A pre-release pinned for one minor (igbinary RC for PHP 8.5): reported once it has a stable release.
	for _, name := range sortedKeys(exts.FromSource) {
		e := exts.FromSource[name]
		for _, minor := range sortedKeys(e.Refs) {
			ref := strings.TrimPrefix(e.Refs[minor], "v")
			if stableVersion.MatchString(ref) {
				continue
			}
			base := regexp.MustCompile(`^[0-9.]+[0-9]`).FindString(ref) // 3.2.17RC1 → 3.2.17
			vs, err := src.githubVersions(e.Repo, "")
			if err != nil {
				problems = append(problems, name+": "+err.Error())
				continue
			}
			if n := newestOf(vs); n != "" && cmpVersion(n, base) >= 0 {
				rows = append(rows, fmt.Sprintf("| %s for PHP %s (Windows) | %s | %s | `php.windows.extensions.from_source.%s.refs.%s` (then raise `php.windows.extensions.build`) |", name, minor, e.Refs[minor], n, name, minor))
			}
		}
	}
	if len(rows) > 0 {
		findings = append(findings, finding{Kind: "pins", Title: "Updates available for pinned versions",
			Body: "These are pinned to a version, and upstream has a newer stable release:\n\n" +
				"| What | Pinned | Newest | Where |\n|---|---|---|---|\n" + strings.Join(rows, "\n") + "\n\n" +
				"Updating means changing the version, raising the build number (so the published versions are rebuilt " +
				"with it; rebuilds start in the experimental channel) and testing on a branch. This list is updated " +
				"weekly; close the issue to skip these updates, it reopens when another one comes."})
	}
	return findings, problems
}

// opensslPin is the OpenSSL version the macOS builds link statically (the same for every package).
func opensslPin(v *versions) string {
	for _, pkg := range v.packageNames() {
		if o := v.Packages[pkg].Env["OPENSSL_VERSION"]; o != "" {
			return o
		}
	}
	return ""
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// lineConfig is one list of release lines in versions.json and where it is.
type lineConfig struct {
	where string
	lines []string
	note  string // added when a new line is missing here
}

func slicesContains(s []string, x string) bool {
	for _, e := range s {
		if e == x {
			return true
		}
	}
	return false
}

// envPin is the first package's value of an env setting that several packages pin alike.
func envPin(v *versions, key string) string {
	for _, pkg := range v.packageNames() {
		if value := v.Packages[pkg].Env[key]; value != "" {
			return value
		}
	}
	return ""
}
