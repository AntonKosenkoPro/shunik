package db

import (
	"strings"
	"testing"
)

func TestBlobKeyScheme(t *testing.T) {
	cases := []struct{ in, want string }{
		{"report.pdf", "report.pdf"},
		{"../../etc/passwd", "passwd"},
		{"/abs/path/Strange Name (1).PDF", "StrangeName1.PDF"},
		{"a/b/c/d.png", "d.png"},
		{"", "file"},
		{".", "file"},
		{"???", "file"},
		{"ok_name-1.2.txt", "ok_name-1.2.txt"},
	}
	for _, c := range cases {
		if got := sanitizeBlobFilename(c.in); got != c.want {
			t.Errorf("sanitizeBlobFilename(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	long := strings.Repeat("a", 200) + ".txt"
	if got := sanitizeBlobFilename(long); len(got) != 100 {
		t.Errorf("expected truncation to 100, got %d (%q)", len(got), got)
	}
	if got := blobKeyFor("hh-1", "doc-1", "../x.pdf"); got != "h/hh-1/d/doc-1/x.pdf" {
		t.Errorf("unexpected blob key scheme: %q", got)
	}
}
