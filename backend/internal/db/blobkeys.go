package db

import (
	"path"
	"strings"
)

// blobKeyFor builds the fixed blob-key scheme shared by all backends:
// h/<householdID>/d/<docID>/<safe>. One implementation so pg and sqlite
// can never diverge. S3 keys are opaque strings ("/" and ".." have no
// traversal meaning), but the sanitized tail keeps the console readable.
func blobKeyFor(householdID, docID, filename string) string {
	return "h/" + householdID + "/d/" + docID + "/" + sanitizeBlobFilename(filename)
}

// sanitizeBlobFilename strips a client filename to a safe blob-key tail:
// path.Base, keep [A-Za-z0-9._-], truncate to 100, fallback "file".
func sanitizeBlobFilename(name string) string {
	base := path.Base(name)
	if base == "" || base == "." || base == "/" {
		return "file"
	}
	var b strings.Builder
	for _, r := range base {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-' {
			b.WriteRune(r)
		}
	}
	s := b.String()
	if len(s) > 100 {
		s = s[:100]
	}
	if s == "" {
		return "file"
	}
	return s
}
