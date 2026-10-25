package apple

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/observe"
	"github.com/antonkosenko/shunik/backend/internal/recovery"
)

// alertAfterAttempts / alertAfterAge escalate a stuck job to the operator
// (structured error log = the actionable monitoring hook; alerting tails the
// logs). The job itself is never dropped: completion within 24h is the
// target, escalation for repair is the failure mode.
const (
	alertAfterAttempts = 20
	alertAfterAge      = 24 * time.Hour
)

// Worker drains the durable Apple-revocation outbox: it exclusively claims
// due jobs, decrypts the sealed refresh credential, revokes it with Apple,
// and removes the sealed material on acknowledged completion. Restart-safe:
// claims carry a lease, failures reschedule with bounded backoff, and no
// code path drops unresolved work as success. Revocation is idempotent
// (Apple's 200 covers already-invalid tokens), so a handler's inline
// post-purge attempt racing a worker claim converges on the same end state.
type Worker struct {
	store  db.Store
	client Client
	keys   *recovery.Keyring
	logger *slog.Logger
	// PollInterval paces RunOnce when started via Start.
	PollInterval time.Duration
}

// NewWorker builds a revocation worker. A nil client or keyring leaves the
// worker inert (RunOnce logs once and claims nothing): jobs wait for a
// configured deploy rather than failing in a loop. This is also the rollback
// story — hiding the deletion control never orphans pending work.
func NewWorker(store db.Store, client Client, keys *recovery.Keyring, logger *slog.Logger, pollInterval time.Duration) *Worker {
	if pollInterval <= 0 {
		pollInterval = time.Minute
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Worker{store: store, client: client, keys: keys, logger: logger, PollInterval: pollInterval}
}

// unavailableWarned suppresses the per-poll unconfigured warning to one line
// per process; the condition itself persists until configured.
var unavailableWarned = false

// RunOnce claims and processes a single due job. It returns (false, nil)
// when nothing is due. A claimed job always ends claimed-resolved: completed
// on acknowledgment, rescheduled otherwise.
func (w *Worker) RunOnce(ctx context.Context) (bool, error) {
	if w.client == nil || w.keys == nil {
		if !unavailableWarned {
			unavailableWarned = true
			w.logger.Warn("apple revocation worker unconfigured; pending jobs wait for Apple deployment")
		}
		return false, nil
	}
	job, err := w.store.ClaimRevocationJob(ctx, time.Now())
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	w.processClaimed(ctx, job)
	return true, nil
}

// processClaimed revokes one claimed job: decrypt, revoke, complete-or-fail.
// Decryption and Apple failures reschedule with bounded backoff and never
// delete the sealed material.
func (w *Worker) processClaimed(ctx context.Context, job db.RevocationJob) {
	plain, err := w.keys.Open(job.SealedRefresh, VaultAAD(job.AuthLineage, job.AuthTime))
	if err != nil {
		w.fail(ctx, job, "decrypt sealed apple credential: "+err.Error())
		return
	}
	if err := w.client.RevokeToken(ctx, string(plain)); err != nil {
		w.fail(ctx, job, "apple revoke: "+err.Error())
		return
	}
	// Acknowledged completion (Apple's 200 covers already-invalid tokens):
	// remove the sealed material immediately.
	if err := w.store.CompleteRevocationJob(ctx, job.ID); err != nil {
		w.logger.Error("apple revocation completed but job removal failed",
			"job_id", job.ID, "error", err)
		return
	}
	w.logger.Info("apple revocation completed", "job_id", job.ID)
}

// fail records the failure, reschedules with bounded backoff, and escalates
// stuck jobs to the operator.
func (w *Worker) fail(ctx context.Context, job db.RevocationJob, msg string) {
	next := time.Now().Add(RetryAfter(job.Attempts))
	if err := w.store.FailRevocationJob(ctx, job.ID, msg, next); err != nil {
		w.logger.Error("apple revocation job failure could not be rescheduled",
			"job_id", job.ID, "error", err)
		return
	}
	age := time.Since(job.CreatedAt)
	if job.Attempts >= alertAfterAttempts || age >= alertAfterAge {
		observe.ReportBackground("apple-revocation-stuck", errors.New(msg), map[string]string{
			"job_id":   job.ID,
			"attempts": strconv.Itoa(job.Attempts),
			"age":      age.String(),
		})
		w.logger.Error("apple revocation job needs operator repair",
			"job_id", job.ID, "attempts", job.Attempts, "age", age.String(),
			"client_id", job.ClientID, "last_error", msg)
		return
	}
	w.logger.Warn("apple revocation attempt failed; rescheduled",
		"job_id", job.ID, "attempts", job.Attempts, "next_attempt_at", next)
}

// Start drains due jobs until ctx is done. It returns when the context ends.
func (w *Worker) Start(ctx context.Context) {
	ticker := time.NewTicker(w.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, err := w.RunOnce(ctx); err != nil {
				w.logger.Error("apple revocation worker error", "error", err)
			}
		}
	}
}
