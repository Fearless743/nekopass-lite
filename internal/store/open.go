package store

import (
	"context"
	_ "embed"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schema string

const CurrentSchemaVersion = 1

func CheckSchema(ctx context.Context, p *pgxpool.Pool) error {
	var version int
	if err := p.QueryRow(ctx, "SELECT max(version) FROM schema_version").Scan(&version); err != nil || version != CurrentSchemaVersion {
		return errors.New("database schema missing or unsupported; run -mode migrate")
	}
	return nil
}

func Open(ctx context.Context, url string) (*pgxpool.Pool, error) {
	p, err := pgxpool.New(ctx, url)
	if err != nil {
		// pgx parsing errors may quote the entire DSN, including its password.
		return nil, errors.New("invalid PostgreSQL connection configuration; check NEKOPASS_DATABASE_URL")
	}
	if err = p.Ping(ctx); err != nil {
		p.Close()
		return nil, errors.New("cannot connect to PostgreSQL; check database availability and connection configuration")
	}
	return p, nil
}

// Migrate installs the current schema on an empty database. This build does not
// upgrade databases created by older releases; recreate the database instead.
func Migrate(ctx context.Context, p *pgxpool.Pool) error {
	var installed bool
	if err := p.QueryRow(ctx, "SELECT to_regclass('public.schema_version') IS NOT NULL").Scan(&installed); err != nil {
		return err
	}
	tx, err := p.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(734291)"); err != nil {
		return err
	}
	if installed {
		var version int
		if err = tx.QueryRow(ctx, "SELECT max(version) FROM schema_version").Scan(&version); err != nil {
			return err
		}
		if version != CurrentSchemaVersion {
			return errors.New("unsupported database schema; recreate the database with this release")
		}
		return tx.Commit(ctx)
	}
	if _, err = tx.Exec(ctx, schema); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
