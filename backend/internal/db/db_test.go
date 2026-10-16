package db

import (
	"context"
	"testing"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/migrations"
)

// setupTestStore creates a new in-memory SQLite store and runs migrations.
func setupTestStore(t *testing.T) *SQLiteStore {
	t.Helper()

	store, err := NewSQLiteStore(":memory:")
	if err != nil {
		t.Fatalf("NewSQLiteStore failed: %v", err)
	}

	ctx := context.Background()
	if err := migrations.RunSQLite(ctx, store.DB()); err != nil {
		_ = store.Close()
		t.Fatalf("RunSQLite failed: %v", err)
	}

	t.Cleanup(func() { _ = store.Close() })

	return store
}

func TestSQLiteStore_UpsertUser_CreatesNewUser(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()
	user, err := store.UpsertUser(ctx, "new@example.com")
	if err != nil {
		t.Fatalf("UpsertUser returned error: %v", err)
	}
	if user.ID == "" {
		t.Fatal("expected non-empty user ID")
	}
	if user.Email != "new@example.com" {
		t.Errorf("expected email %q, got %q", "new@example.com", user.Email)
	}
	if user.EmailVerified {
		t.Error("expected new user to not be verified")
	}
	if user.CreatedAt.IsZero() {
		t.Error("expected non-zero CreatedAt")
	}
}

func TestSQLiteStore_UpsertUser_ReturnsExistingUserOnDuplicateEmail(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user1, err := store.UpsertUser(ctx, "duplicate@example.com")
	if err != nil {
		t.Fatalf("first UpsertUser failed: %v", err)
	}

	user2, err := store.UpsertUser(ctx, "duplicate@example.com")
	if err != nil {
		t.Fatalf("second UpsertUser failed: %v", err)
	}

	if user1.ID != user2.ID {
		t.Errorf("expected same user ID on duplicate upsert: %q vs %q", user1.ID, user2.ID)
	}
	if user1.Email != user2.Email {
		t.Errorf("expected same email: %q vs %q", user1.Email, user2.Email)
	}
}

func TestSQLiteStore_SetUserVerified_MarksUserAsVerified(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "verify@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	if err := store.SetUserVerified(ctx, user.ID); err != nil {
		t.Fatalf("SetUserVerified failed: %v", err)
	}

	updated, err := store.GetUserByID(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetUserByID failed: %v", err)
	}
	if !updated.EmailVerified {
		t.Error("expected user to be verified after SetUserVerified")
	}
}

func TestSQLiteStore_SaveOTPAndGetValidOTP(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "otp-test@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	codeHash := "abc123hash"
	expiresAt := time.Now().Add(10 * time.Minute)

	if err := store.SaveOTP(ctx, user.ID, codeHash, expiresAt, 5); err != nil {
		t.Fatalf("SaveOTP failed: %v", err)
	}

	otp, err := store.GetValidOTP(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetValidOTP failed: %v", err)
	}
	if otp.CodeHash != codeHash {
		t.Errorf("expected code hash %q, got %q", codeHash, otp.CodeHash)
	}
	if otp.UserID != user.ID {
		t.Errorf("expected user ID %q, got %q", user.ID, otp.UserID)
	}
	if otp.Attempts != 0 {
		t.Errorf("expected 0 attempts, got %d", otp.Attempts)
	}
	if otp.MaxAttempts != 5 {
		t.Errorf("expected max attempts 5, got %d", otp.MaxAttempts)
	}
}

func TestSQLiteStore_GetValidOTP_ReturnsErrorForExpiredOTP(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "expired-otp@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	// Save an OTP that expired in the past
	expiresAt := time.Now().Add(-1 * time.Minute)
	if err := store.SaveOTP(ctx, user.ID, "expiredhash", expiresAt, 5); err != nil {
		t.Fatalf("SaveOTP failed: %v", err)
	}

	_, err = store.GetValidOTP(ctx, user.ID)
	if err == nil {
		t.Fatal("expected error for expired OTP, got nil")
	}
}

func TestSQLiteStore_IncrementOTPAttempts_IncrementsCounter(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "attempts@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	expiresAt := time.Now().Add(10 * time.Minute)
	if err := store.SaveOTP(ctx, user.ID, "hash", expiresAt, 5); err != nil {
		t.Fatalf("SaveOTP failed: %v", err)
	}

	otp, err := store.GetValidOTP(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetValidOTP failed: %v", err)
	}

	if err := store.IncrementOTPAttempts(ctx, otp.ID); err != nil {
		t.Fatalf("IncrementOTPAttempts failed: %v", err)
	}

	otp2, err := store.GetValidOTP(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetValidOTP after increment failed: %v", err)
	}
	if otp2.Attempts != 1 {
		t.Errorf("expected 1 attempt, got %d", otp2.Attempts)
	}
}

func TestSQLiteStore_MarkOTPExhausted_MarksOTPAsExhausted(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "exhausted@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	expiresAt := time.Now().Add(10 * time.Minute)
	if err := store.SaveOTP(ctx, user.ID, "hash", expiresAt, 5); err != nil {
		t.Fatalf("SaveOTP failed: %v", err)
	}

	otp, err := store.GetValidOTP(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetValidOTP failed: %v", err)
	}

	if err := store.MarkOTPExhausted(ctx, otp.ID); err != nil {
		t.Fatalf("MarkOTPExhausted failed: %v", err)
	}

	_, err = store.GetValidOTP(ctx, user.ID)
	if err == nil {
		t.Fatal("expected error for exhausted OTP, got nil")
	}
}

func TestSQLiteStore_SaveRefreshTokenAndGetRefreshToken(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "refresh@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	tokenHash := "test-refresh-token-hash-123"
	deviceID := "device-001"

	if err := store.SaveRefreshToken(ctx, user.ID, tokenHash, deviceID); err != nil {
		t.Fatalf("SaveRefreshToken failed: %v", err)
	}

	stored, err := store.GetRefreshToken(ctx, tokenHash)
	if err != nil {
		t.Fatalf("GetRefreshToken failed: %v", err)
	}
	if stored.TokenHash != tokenHash {
		t.Errorf("expected token hash %q, got %q", tokenHash, stored.TokenHash)
	}
	if stored.UserID != user.ID {
		t.Errorf("expected user ID %q, got %q", user.ID, stored.UserID)
	}
	if stored.DeviceID != deviceID {
		t.Errorf("expected device ID %q, got %q", deviceID, stored.DeviceID)
	}
	if stored.Revoked {
		t.Error("expected token to not be revoked")
	}
}

func TestSQLiteStore_RevokeRefreshToken_MarksTokenAsRevoked(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "revoke@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	tokenHash := "token-to-revoke"
	if err := store.SaveRefreshToken(ctx, user.ID, tokenHash, ""); err != nil {
		t.Fatalf("SaveRefreshToken failed: %v", err)
	}

	stored, err := store.GetRefreshToken(ctx, tokenHash)
	if err != nil {
		t.Fatalf("GetRefreshToken failed: %v", err)
	}

	if err := store.RevokeRefreshToken(ctx, stored.ID); err != nil {
		t.Fatalf("RevokeRefreshToken failed: %v", err)
	}

	updated, err := store.GetRefreshToken(ctx, tokenHash)
	if err != nil {
		t.Fatalf("GetRefreshToken after revoke failed: %v", err)
	}
	if !updated.Revoked {
		t.Error("expected token to be revoked")
	}
}

func TestSQLiteStore_RevokeAllUserSessions_RevokesAllTokens(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "sessions@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	if err := store.SaveRefreshToken(ctx, user.ID, "token-1", ""); err != nil {
		t.Fatalf("SaveRefreshToken 1 failed: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, user.ID, "token-2", ""); err != nil {
		t.Fatalf("SaveRefreshToken 2 failed: %v", err)
	}

	if err := store.RevokeAllUserSessions(ctx, user.ID); err != nil {
		t.Fatalf("RevokeAllUserSessions failed: %v", err)
	}

	t1, err := store.GetRefreshToken(ctx, "token-1")
	if err != nil {
		t.Fatalf("GetRefreshToken token-1 failed: %v", err)
	}
	if !t1.Revoked {
		t.Error("expected token-1 to be revoked")
	}

	t2, err := store.GetRefreshToken(ctx, "token-2")
	if err != nil {
		t.Fatalf("GetRefreshToken token-2 failed: %v", err)
	}
	if !t2.Revoked {
		t.Error("expected token-2 to be revoked")
	}
}

func TestSQLiteStore_GetUserByID_ReturnsCorrectUser(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "byid@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	fetched, err := store.GetUserByID(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetUserByID failed: %v", err)
	}
	if fetched.ID != user.ID {
		t.Errorf("expected ID %q, got %q", user.ID, fetched.ID)
	}
	if fetched.Email != user.Email {
		t.Errorf("expected email %q, got %q", user.Email, fetched.Email)
	}
}

func TestSQLiteStore_GetUserByID_ReturnsErrorForNonexistentUser(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	_, err := store.GetUserByID(ctx, "nonexistent-id")
	if err == nil {
		t.Fatal("expected error for nonexistent user, got nil")
	}
}

func TestSQLiteStore_GetUserByEmail_ReturnsCorrectUser(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "byemail@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	fetched, err := store.GetUserByEmail(ctx, "byemail@example.com")
	if err != nil {
		t.Fatalf("GetUserByEmail failed: %v", err)
	}
	if fetched.ID != user.ID {
		t.Errorf("expected ID %q, got %q", user.ID, fetched.ID)
	}
	if fetched.Email != "byemail@example.com" {
		t.Errorf("expected email %q, got %q", "byemail@example.com", fetched.Email)
	}
}

func TestSQLiteStore_GetUserByEmail_ReturnsErrorForNonexistentEmail(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	_, err := store.GetUserByEmail(ctx, "nonexistent@example.com")
	if err == nil {
		t.Fatal("expected error for nonexistent email, got nil")
	}
}

func TestSQLiteStore_GetRefreshToken_ReturnsErrorForNonexistentToken(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	_, err := store.GetRefreshToken(ctx, "nonexistent-token-hash")
	if err == nil {
		t.Fatal("expected error for nonexistent token, got nil")
	}
}

func TestSQLiteStore_RevokeAllUserSessions_OnlyRevokesSpecifiedUser(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user1, err := store.UpsertUser(ctx, "user1@example.com")
	if err != nil {
		t.Fatalf("UpsertUser user1 failed: %v", err)
	}
	user2, err := store.UpsertUser(ctx, "user2@example.com")
	if err != nil {
		t.Fatalf("UpsertUser user2 failed: %v", err)
	}

	if err := store.SaveRefreshToken(ctx, user1.ID, "user1-token", ""); err != nil {
		t.Fatalf("SaveRefreshToken user1 failed: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, user2.ID, "user2-token", ""); err != nil {
		t.Fatalf("SaveRefreshToken user2 failed: %v", err)
	}

	if err := store.RevokeAllUserSessions(ctx, user1.ID); err != nil {
		t.Fatalf("RevokeAllUserSessions failed: %v", err)
	}

	t1, err := store.GetRefreshToken(ctx, "user1-token")
	if err != nil {
		t.Fatalf("GetRefreshToken user1-token failed: %v", err)
	}
	if !t1.Revoked {
		t.Error("expected user1's token to be revoked")
	}

	t2, err := store.GetRefreshToken(ctx, "user2-token")
	if err != nil {
		t.Fatalf("GetRefreshToken user2-token failed: %v", err)
	}
	if t2.Revoked {
		t.Error("expected user2's token to NOT be revoked")
	}
}

func TestSQLiteStore_GetValidOTP_ReturnsLatestOTP(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	user, err := store.UpsertUser(ctx, "latest-otp@example.com")
	if err != nil {
		t.Fatalf("UpsertUser failed: %v", err)
	}

	expiresAt := time.Now().Add(10 * time.Minute)

	if err := store.SaveOTP(ctx, user.ID, "first-hash", expiresAt, 5); err != nil {
		t.Fatalf("SaveOTP first failed: %v", err)
	}

	time.Sleep(10 * time.Millisecond)

	if err := store.SaveOTP(ctx, user.ID, "second-hash", expiresAt, 5); err != nil {
		t.Fatalf("SaveOTP second failed: %v", err)
	}

	otp, err := store.GetValidOTP(ctx, user.ID)
	if err != nil {
		t.Fatalf("GetValidOTP failed: %v", err)
	}
	if otp.CodeHash != "second-hash" {
		t.Errorf("expected latest OTP hash %q, got %q", "second-hash", otp.CodeHash)
	}
}

func TestSQLiteStore_UpsertUserByAppleSubject_CreatesVerifiedUser(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()
	user, err := store.UpsertUserByAppleSubject(ctx, "apple-sub-1", "relay@privaterelay.appleid.com")
	if err != nil {
		t.Fatalf("UpsertUserByAppleSubject failed: %v", err)
	}
	if user.ID == "" {
		t.Fatal("expected non-empty user ID")
	}
	if user.Email != "relay@privaterelay.appleid.com" {
		t.Errorf("expected relay email, got %q", user.Email)
	}
	if !user.EmailVerified {
		t.Error("expected Apple user to be email-verified")
	}
}

func TestSQLiteStore_UpsertUserByAppleSubject_IdempotentKeepsEmail(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()

	first, err := store.UpsertUserByAppleSubject(ctx, "apple-sub-2", "real@example.com")
	if err != nil {
		t.Fatalf("first upsert failed: %v", err)
	}

	// Second sign-in with the same sub but no email — must reuse the same user
	// and keep the originally stored email.
	second, err := store.UpsertUserByAppleSubject(ctx, "apple-sub-2", "")
	if err != nil {
		t.Fatalf("second upsert failed: %v", err)
	}
	if second.ID != first.ID {
		t.Errorf("expected same user ID: %q vs %q", first.ID, second.ID)
	}
	if second.Email != "real@example.com" {
		t.Errorf("expected original email retained, got %q", second.Email)
	}
	if !second.EmailVerified {
		t.Error("expected email_verified to remain true")
	}
}

func TestSQLiteStore_UpsertUserByAppleSubject_DistinctSubjects(t *testing.T) {
	store := setupTestStore(t)

	ctx := context.Background()
	u1, err := store.UpsertUserByAppleSubject(ctx, "sub-a", "a@example.com")
	if err != nil {
		t.Fatalf("upsert a failed: %v", err)
	}
	u2, err := store.UpsertUserByAppleSubject(ctx, "sub-b", "b@example.com")
	if err != nil {
		t.Fatalf("upsert b failed: %v", err)
	}
	if u1.ID == u2.ID {
		t.Error("expected distinct users for distinct Apple subjects")
	}
}
