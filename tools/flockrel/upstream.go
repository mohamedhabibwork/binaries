package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// latestFuncs find the newest stable upstream version of each release line of a package.
// Lines without a release are left out of the result.
var latestFuncs = map[string]func(lines []string) (map[string]string, error){
	"postgres":    latestPostgres,
	"mariadb":     latestMariaDB,
	"valkey":      latestFromGitHubReleases("valkey-io/valkey"),
	"redis":       latestFromGitHubReleases("redis/redis"),
	"mysql":       latestMySQL,
	"mongodb":     latestMongoDB,
	"meilisearch": latestFromGitHubReleases("meilisearch/meilisearch"),
	"typesense":   latestFromGitHubReleases("typesense/typesense"),
	"rustfs":      latestFromGitHubReleases("rustfs/rustfs"),
	"keycloak":    latestFromGitHubReleases("keycloak/keycloak"),
	"cloudflared": latestFromGitHubReleases("cloudflare/cloudflared"),
	"node":        latestNode,
	"pgvector":    latestFromGitHubTags("pgvector/pgvector"),
	"timescaledb": latestFromGitHubReleases("timescale/timescaledb"),
	"postgis":     latestPostGIS,
	"pgrouting":   latestFromGitHubReleases("pgRouting/pgrouting"),
}

// stableVersion matches plain release versions: 9, 30.2, 8.4.6. Not 9.2.0-rc1, not 1.0.0-alpha.80.
var stableVersion = regexp.MustCompile(`^\d+(\.\d+)*$`)

// newestPerLine picks the highest stable version of each line from candidates.
func newestPerLine(lines, candidates []string) map[string]string {
	out := map[string]string{}
	for _, c := range candidates {
		if !stableVersion.MatchString(c) {
			continue
		}
		for _, line := range lines {
			if inLine(c, line) && (out[line] == "" || cmpVersion(c, out[line]) > 0) {
				out[line] = c
			}
		}
	}
	return out
}

// newMinorRC matches a release candidate of a PHP minor that has no release yet: 8.6.0RC3.
// Patch RCs (8.4.27RC1) don't match: they are replaced by their release two weeks later.
var newMinorRC = regexp.MustCompile(`^\d+\.\d+\.0RC\d+$`)

// versionParts splits a version into its numbers and a pre-release suffix: 8.6.0RC2 → 8.6.0, RC2.
var versionParts = regexp.MustCompile(`^(\d+(?:\.\d+)*)(.*)$`)

// suffixParts splits a pre-release suffix into its name and number: RC2, -rc.2 → rc, 2.
var suffixParts = regexp.MustCompile(`^[-.]?([A-Za-z]*)[-.]?(\d*)$`)

// cmpVersion compares dotted numeric versions: 8.4.10 > 8.4.9, 8.10 > 8.4, with a pre-release
// before its release: 8.6.0alpha1 < 8.6.0RC2 < 8.6.0RC10 < 8.6.0.
func cmpVersion(a, b string) int {
	ma, mb := versionParts.FindStringSubmatch(a), versionParts.FindStringSubmatch(b)
	if ma == nil || mb == nil {
		return strings.Compare(a, b)
	}
	as, bs := strings.Split(ma[1], "."), strings.Split(mb[1], ".")
	for i := 0; i < max(len(as), len(bs)); i++ {
		var x, y int
		if i < len(as) {
			x, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			y, _ = strconv.Atoi(bs[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	switch sa, sb := ma[2], mb[2]; {
	case sa == sb:
		return 0
	case sa == "":
		return 1
	case sb == "":
		return -1
	}
	pa, pb := suffixParts.FindStringSubmatch(ma[2]), suffixParts.FindStringSubmatch(mb[2])
	if pa == nil || pb == nil {
		return strings.Compare(ma[2], mb[2])
	}
	if c := strings.Compare(strings.ToLower(pa[1]), strings.ToLower(pb[1])); c != 0 {
		return c // alpha < beta < rc
	}
	x, _ := strconv.Atoi(pa[2])
	y, _ := strconv.Atoi(pb[2])
	if x != y {
		if x < y {
			return -1
		}
		return 1
	}
	return 0
}

// latestFromGitHubReleases uses the published, non-prerelease releases of a GitHub repository,
// tagged <version> or v<version>.
func latestFromGitHubReleases(repo string) func([]string) (map[string]string, error) {
	return func(lines []string) (map[string]string, error) {
		var rels []release
		if err := getJSON("https://api.github.com/repos/"+repo+"/releases?per_page=100", &rels); err != nil {
			return nil, err
		}
		var tags []string
		for _, r := range rels {
			if !r.Draft && !r.Prerelease {
				tags = append(tags, strings.TrimPrefix(r.TagName, "v"))
			}
		}
		return newestPerLine(lines, tags), nil
	}
}

// latestFromGitHubTags uses the tags of a GitHub repository (<version> or v<version>), for
// projects that tag releases without publishing GitHub releases (pgvector).
func latestFromGitHubTags(repo string) func([]string) (map[string]string, error) {
	return func(lines []string) (map[string]string, error) {
		var tags []struct {
			Name string `json:"name"`
		}
		if err := getJSON("https://api.github.com/repos/"+repo+"/tags?per_page=100", &tags); err != nil {
			return nil, err
		}
		var vs []string
		for _, t := range tags {
			vs = append(vs, strings.TrimPrefix(t.Name, "v"))
		}
		return newestPerLine(lines, vs), nil
	}
}

// latestPostgres reads postgresql.org's list of majors and their latest minor.
func latestPostgres(lines []string) (map[string]string, error) {
	var majors []struct {
		Major       string `json:"major"`
		LatestMinor string `json:"latestMinor"`
	}
	if err := getJSON("https://www.postgresql.org/versions.json", &majors); err != nil {
		return nil, err
	}
	var all []string
	for _, m := range majors {
		all = append(all, m.Major+"."+m.LatestMinor)
	}
	return newestPerLine(lines, all), nil
}

// latestMariaDB asks the MariaDB downloads API for the newest release of each line.
func latestMariaDB(lines []string) (map[string]string, error) {
	out := map[string]string{}
	for _, line := range lines {
		var r struct {
			Releases map[string]struct {
				ReleaseStatus string `json:"release_status"`
			} `json:"releases"`
		}
		if err := getJSON("https://downloads.mariadb.org/rest-api/mariadb/"+line+"/latest/", &r); err != nil {
			return nil, err
		}
		var vs []string
		for v := range r.Releases {
			vs = append(vs, v)
		}
		for l, v := range newestPerLine([]string{line}, vs) {
			out[l] = v
		}
	}
	return out, nil
}

// latestMySQL uses the release tags of Oracle's GitHub mirror (mysql-8.4.6). The mirror job
// fails, and is retried the next day, when a tag is pushed before its binaries are out.
func latestMySQL(lines []string) (map[string]string, error) {
	out := map[string]string{}
	for _, line := range lines {
		var refs []struct {
			Ref string `json:"ref"`
		}
		if err := getJSON("https://api.github.com/repos/mysql/mysql-server/git/matching-refs/tags/mysql-"+line+".", &refs); err != nil {
			return nil, err
		}
		var vs []string
		for _, r := range refs {
			vs = append(vs, strings.TrimPrefix(r.Ref, "refs/tags/mysql-"))
		}
		for l, v := range newestPerLine([]string{line}, vs) {
			out[l] = v
		}
	}
	return out, nil
}

// latestMongoDB reads MongoDB's full list of releases.
func latestMongoDB(lines []string) (map[string]string, error) {
	var r struct {
		Versions []struct {
			Version           string `json:"version"`
			ProductionRelease bool   `json:"production_release"`
		} `json:"versions"`
	}
	if err := getJSON("https://downloads.mongodb.org/full.json", &r); err != nil {
		return nil, err
	}
	var vs []string
	for _, v := range r.Versions {
		if v.ProductionRelease {
			vs = append(vs, v.Version)
		}
	}
	return newestPerLine(lines, vs), nil
}

// latestNode reads nodejs.org's release index; lines are majors.
func latestNode(lines []string) (map[string]string, error) {
	var rels []struct {
		Version string `json:"version"`
	}
	if err := getJSON("https://nodejs.org/dist/index.json", &rels); err != nil {
		return nil, err
	}
	var vs []string
	for _, r := range rels {
		vs = append(vs, strings.TrimPrefix(r.Version, "v"))
	}
	return newestPerLine(lines, vs), nil
}

// latestVersions returns the newest version of every line of a package. Lines it can't find a
// release for (a typo in versions.json, an upstream API that changed or is down) are reported
// as problems, so one unreachable upstream doesn't hold back every other package.
func latestVersions(name string, p pkgConfig) (vers []string, problems []string) {
	found, err := latestFuncs[name](p.Lines)
	if err != nil {
		return nil, []string{fmt.Sprintf("%s: %v", name, err)}
	}
	for _, line := range p.Lines {
		if v, ok := found[line]; ok {
			vers = append(vers, v)
		} else {
			problems = append(problems, fmt.Sprintf("%s: no release found for line %s", name, line))
		}
	}
	return vers, problems
}

// latestPostGIS reads the source releases on download.osgeo.org (postgis-3.6.4.tar.gz).
func latestPostGIS(lines []string) (map[string]string, error) {
	page, err := getText("https://download.osgeo.org/postgis/source/")
	if err != nil {
		return nil, err
	}
	var vs []string
	for _, m := range regexp.MustCompile(`postgis-(\d+\.\d+\.\d+)\.tar\.gz"`).FindAllStringSubmatch(page, -1) {
		vs = append(vs, m[1])
	}
	return newestPerLine(lines, vs), nil
}
