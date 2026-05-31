#!/bin/sh
set -e

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=postgres}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=supersecretpassword}"

export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

psql -v ON_ERROR_STOP=1 -c "REFRESH MATERIALIZED VIEW mv_daily_fraud_summary;"
