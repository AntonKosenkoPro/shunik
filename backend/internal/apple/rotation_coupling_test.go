package apple

// Rotation-coupling pin: subject-fence digests derive from
// ACCOUNT_STATUS_SECRET through SubjectDigestKey with a single active key
// and no previous-key fallback. Rotating the secret therefore re-keys every
// digest — pending revocation jobs become invisible to the signup fence
// until the table drains, which is why rotation is drain-first by procedure
// (see .env.example and the operations runbook). These tests pin the
// coupling so no future change can silently assume rotation safety.

import (
	"testing"
)

func TestSubjectDigest_RotationRekeysFence(t *testing.T) {
	oldKey := SubjectDigestKey([]byte("status-secret-v1-at-least-32-bytes!"))
	sameKey := SubjectDigestKey([]byte("status-secret-v1-at-least-32-bytes!"))
	newKey := SubjectDigestKey([]byte("status-secret-v2-at-least-32-bytes!"))

	if SubjectDigest(oldKey, "sub") != SubjectDigest(sameKey, "sub") {
		t.Fatal("same secret must derive a stable digest (rotation-stable within a key)")
	}
	if SubjectDigest(oldKey, "sub") == SubjectDigest(newKey, "sub") {
		t.Fatal("rotated secret must re-key the digest: old pending jobs are invisible under the new key")
	}
	if SubjectDigest(newKey, "sub") == SubjectDigest(newKey, "other") {
		t.Fatal("digests must separate subjects")
	}
}
