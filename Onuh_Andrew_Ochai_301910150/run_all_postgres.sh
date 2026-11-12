#!/usr/bin/env bash
# Rebuilds the CareBridge database from scratch (Portfolios 1-3).
# Usage: PGUSER=postgres PGHOST=localhost ./run_all_postgres.sh
set -euo pipefail
cd "$(dirname "$0")"
dropdb --if-exists carebridge && createdb carebridge
psql -d carebridge -v ON_ERROR_STOP=1 -q -f portfolio-1-database-design/01_schema.sql
psql -d carebridge -q -f portfolio-1-database-design/02_reference_data.sql
psql -d carebridge -v ON_ERROR_STOP=1 -f portfolio-2-query-optimisation/01_generate_data.sql
