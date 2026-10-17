// Command server is the entry point for the Lifio backend API server.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/config"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
	"github.com/antonkosenko/time-of-life/backend/internal/migrations"
	"github.com/antonkosenko/time-of-life/backend/internal/observe"
	"github.com/antonkosenko/time-of-life/backend/internal/server"
)

func main() {
	os.Exit(run())
}

func run() int {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load configuration", "error", err)
		return 1
	}

	slog.Info("configuration loaded",
		"port", cfg.Port,
		"email_backend", cfg.EmailBackend,
		"otp_expiry", cfg.OTPExpiry.String(),
		"otp_max_attempts", cfg.OTPMaxAttempts,
	)

	// Sentry error reporting (observability Stage 0): empty SENTRY_DSN =
	// fully disabled, zero behavior change. Init failure is non-fatal: the
	// server continues without reporting.
	if err := observe.InitSentry(cfg.SentryDSN); err != nil {
		slog.Error("failed to initialize sentry, continuing without error reporting", "error", err)
	} else if observe.SentryEnabled() {
		defer observe.FlushSentry(2 * time.Second)
		slog.Info("sentry error reporting enabled")
	}

	ctx := context.Background()

	store, err := db.NewPostgresStore(ctx, cfg.DatabaseURL)
	if err != nil {
		slog.Error("failed to connect to database", "error", err)
		return 1
	}
	defer func() {
		if err := store.Close(); err != nil {
			slog.Error("failed to close database connection", "error", err)
		}
	}()

	slog.Info("connected to database")

	if err := migrations.RunPostgres(ctx, store.DB()); err != nil {
		slog.Error("failed to run migrations", "error", err)
		return 1
	}

	slog.Info("migrations applied successfully")

	deps := server.NewDefaultDependencies(cfg, store)
	srv := server.New(deps)

	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.Port),
		Handler:      srv,
		ReadTimeout:  cfg.ReadTimeout,
		WriteTimeout: cfg.WriteTimeout,
		IdleTimeout:  cfg.IdleTimeout,
	}

	go func() {
		slog.Info("starting server", "addr", httpServer.Addr)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for shutdown signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit

	slog.Info("shutting down server", "signal", sig.String())

	// Graceful shutdown with timeout
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		slog.Error("server forced to shutdown", "error", err)
		return 1
	}

	slog.Info("server stopped gracefully")
	return 0
}
