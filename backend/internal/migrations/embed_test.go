package migrations

import (
	"context"
	"database/sql"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	_ "modernc.org/sqlite" // pure-Go SQLite driver for migration tests
)

// TestMigrations_FilesOrderedSequential pins the migration file contract:
// zero-padded sequence numbers, no duplicates, strictly increasing numbers,
// and lexical order == apply order. Gaps are allowed: the time-tracking
// domain (003_catalog, 004_provenance, 007_upgrade_legacy) was stripped for
// the auth-only relay, leaving its numbers unreused so deployed databases
// keep a consistent history.
func TestMigrations_FilesOrderedSequential(t *testing.T) {
	files, err := listMigrationFiles()
	if err != nil {
		t.Fatalf("listMigrationFiles: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("expected embedded migration files, got none")
	}
	seen := map[string]bool{}
	for i, f := range files {
		if len(f) < 8 || f[3] != '_' || !strings.HasSuffix(f, ".sql") {
			t.Errorf("file %q does not match NNN_name.sql", f)
			continue
		}
		num := f[:3]
		if seen[num] {
			t.Errorf("duplicate migration number %q (%s)", num, f)
		}
		seen[num] = true
		if i > 0 && files[i-1] >= f {
			t.Errorf("files not in lexical order: %q before %q", files[i-1], f)
		}
		if i > 0 && files[i-1][:3] >= num {
			t.Errorf("migration numbers not strictly increasing: %q before %q", files[i-1], f)
		}
	}
	// File count is unbounded (gaps from stripped domains stay unreused);
	// ordering and uniqueness above are the contract.
}

// TestMigrations_AdaptToSQLite pins the minimal dialect surgery: the named
// replacements apply, the DROP INDEX guard survives the blanket strips, and
// ADD COLUMN / DROP COLUMN guards are stripped (SQLite cannot parse them).
func TestMigrations_AdaptToSQLite(t *testing.T) {
	in := "CREATE TABLE t (id UUID PRIMARY KEY, at TIMESTAMPTZ NOT NULL DEFAULT NOW(), f BOOLEAN DEFAULT false, g BOOLEAN DEFAULT true);\n" +
		"ALTER TABLE t ADD COLUMN IF NOT EXISTS c TEXT;\n" +
		"ALTER TABLE t DROP COLUMN IF EXISTS c;\n" +
		"DROP INDEX IF EXISTS idx_t;\n" +
		"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_t ON t (c);\n"
	out := adaptToSQLite(in)

	for _, want := range []string{
		"TEXT PRIMARY KEY",
		"TEXT NOT NULL DEFAULT (datetime('now'))",
		"DEFAULT 0",
		"DEFAULT 1",
		"DROP INDEX IF EXISTS idx_t",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected adapted SQL to contain %q, got:\n%s", want, out)
		}
	}
	for _, gone := range []string{"UUID", "TIMESTAMPTZ", "NOW()", "IF NOT EXISTS", "CONCURRENTLY"} {
		stripped := strings.ReplaceAll(out, "DROP INDEX IF EXISTS", "")
		if strings.Contains(stripped, gone) {
			t.Errorf("expected adapted SQL to drop %q, got:\n%s", gone, out)
		}
	}
	if strings.Contains(out, "%%KEEP_EXISTS%%") {
		t.Error("guard placeholder leaked into adapted SQL")
	}
}

// TestMigrations_StripDOBlocks pins the legacy-upgrade carve-out: DO blocks
// are removed wholesale (PL/pgSQL would not parse on SQLite), plain
// statements around them survive, and an unterminated block never leaks.
func TestMigrations_StripDOBlocks(t *testing.T) {
	in := "ALTER TABLE t ADD COLUMN IF NOT EXISTS c TEXT;\n" +
		"DO $$\nBEGIN\n" +
		"    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'legacy') THEN\n" +
		"        EXECUTE $q$ UPDATE t SET c = '' $q$;\n" +
		"    END IF;\n" +
		"END $$;\n" +
		"DELETE FROM t WHERE c = 'x';\n"
	out := stripDOBlocks(in)
	for _, want := range []string{"ALTER TABLE t ADD COLUMN", "DELETE FROM t"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected stripped SQL to keep %q, got:\n%s", want, out)
		}
	}
	for _, gone := range []string{"DO $$", "information_schema", "EXECUTE", "END $$;"} {
		if strings.Contains(out, gone) {
			t.Errorf("expected stripped SQL to drop %q, got:\n%s", gone, out)
		}
	}
	if got := stripDOBlocks("SELECT 1;\nDO $$\nBEGIN\n"); !strings.Contains(got, "SELECT 1;") || strings.Contains(got, "DO $$") {
		t.Errorf("unterminated DO block must be dropped, kept prefix intact; got:\n%s", got)
	}
}

// TestMigrations_NoDOBlocksReachSQLite asserts no embedded file feeds
// PL/pgSQL to the SQLite runner: every file's adapted form must be DO-free.
func TestMigrations_NoDOBlocksReachSQLite(t *testing.T) {
	files, err := listMigrationFiles()
	if err != nil {
		t.Fatalf("listMigrationFiles: %v", err)
	}
	for _, f := range files {
		content, err := migrationFiles.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		if adapted := adaptToSQLite(string(content)); strings.Contains(adapted, "DO $$") || strings.Contains(adapted, "EXECUTE") {
			t.Errorf("%s: adapted SQL still contains a DO block", f)
		}
	}
}

// TestMigrations_RunSQLite_Idempotent pins boot idempotency: applying twice
// succeeds, runs each file once, and records every file in schema_migrations.
func TestMigrations_RunSQLite_Idempotent(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer func() { _ = db.Close() }()
	db.SetMaxOpenConns(1)

	ctx := context.Background()
	for round := 1; round <= 2; round++ {
		if err := RunSQLite(ctx, db); err != nil {
			t.Fatalf("RunSQLite round %d: %v", round, err)
		}
	}

	files, err := listMigrationFiles()
	if err != nil {
		t.Fatalf("listMigrationFiles: %v", err)
	}
	var count int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_migrations`).Scan(&count); err != nil {
		t.Fatalf("count schema_migrations: %v", err)
	}
	if count != len(files) {
		t.Errorf("expected %d tracked migrations, got %d", len(files), count)
	}
	for _, f := range files {
		var applied bool
		if err := db.QueryRowContext(ctx, `SELECT true FROM schema_migrations WHERE filename = ?`, f).Scan(&applied); err != nil || !applied {
			t.Errorf("expected %s tracked as applied (err=%v)", f, err)
		}
	}

	// The squashed schema carries the final shape directly: no activities
	// layer, no time-tracking domain (categories/entries/joins were stripped
	// for the auth-only relay); the generic tombstones table stays for future
	// resources.
	for _, table := range []string{"users", "otp_codes", "refresh_tokens", "tombstones", "schema_migrations"} {
		var name string
		if err := db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Errorf("expected table %s: %v", table, err)
		}
	}
	for _, dropped := range []string{"activities", "activity_categories", "categories", "entries", "entry_categories"} {
		var name string
		if err := db.QueryRowContext(ctx, `SELECT name FROM sqlite_master WHERE type='table' AND name=?`, dropped).Scan(&name); err == nil {
			t.Errorf("legacy table %s must not exist, found %q", dropped, name)
		}
	}
}

// TestMigrations_RunPostgres_Idempotent pins the production tracking path:
// two boots skip cleanly and every file is recorded. Gated on TEST_PG_DSN
// (same gate as the parity suite — CI has no Postgres).
func TestMigrations_RunPostgres_Idempotent(t *testing.T) {
	dsn := os.Getenv("TEST_PG_DSN")
	if dsn == "" {
		t.Skip("TEST_PG_DSN not set — skipping PostgreSQL migration test")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	for round := 1; round <= 2; round++ {
		if err := RunPostgres(ctx, pool); err != nil {
			t.Fatalf("RunPostgres round %d: %v", round, err)
		}
	}

	files, err := listMigrationFiles()
	if err != nil {
		t.Fatalf("listMigrationFiles: %v", err)
	}
	var count int
	if err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM schema_migrations`).Scan(&count); err != nil {
		t.Fatalf("count schema_migrations: %v", err)
	}
	if count != len(files) {
		t.Errorf("expected %d tracked migrations, got %d", len(files), count)
	}
}
