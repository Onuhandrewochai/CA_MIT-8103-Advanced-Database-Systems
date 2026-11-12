#!/usr/bin/env bash
# =====================================================================================
# Portfolio 5 — builds a local 5-node PostgreSQL 16 topology for CareBridge Clinics
#
#   :5432  primary        (existing server holding the carebridge database)
#   :5433  replica1       streaming replica  (will become SYNCHRONOUS)
#   :5434  replica2       streaming replica  (asynchronous, e.g. reporting / DR site)
#   :5441  shard_a        independent server — holds hash partition 0 of appointments
#   :5442  shard_b        independent server — holds hash partition 1 of appointments
#
# Run as the OS user that owns the PostgreSQL data directories (e.g. `postgres`).
#   BASE=/path/to/pg PRIMARY_DATA=$BASE/primary ./setup_cluster.sh
# =====================================================================================
set -euo pipefail
PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
BASE=${BASE:-$HOME/pg}
PRIMARY_DATA=${PRIMARY_DATA:-$BASE/primary}
export PGHOST=localhost PGUSER=postgres

echo "== 1. Configure the primary for replication"
psql -p 5432 -d postgres -v ON_ERROR_STOP=1 <<'SQL'
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET wal_keep_size = '512MB';
ALTER SYSTEM SET hot_standby = on;
ALTER SYSTEM SET synchronous_standby_names = '';          -- start fully asynchronous
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator-demo-pw';
  END IF;
END $$;
SQL
# Allow the replication role (scram-sha-256 in real deployments)
grep -q "replicator" "$PRIMARY_DATA/pg_hba.conf" || \
  echo "host replication replicator 127.0.0.1/32 scram-sha-256" >> "$PRIMARY_DATA/pg_hba.conf"
"$PGBIN/pg_ctl" -D "$PRIMARY_DATA" -l "$BASE/primary.log" -w restart -m fast >/dev/null

echo "== 2. Clone two streaming replicas with pg_basebackup (-R writes standby.signal + primary_conninfo)"
for n in 1 2; do
  port=$((5432 + n)); dir="$BASE/replica$n"
  "$PGBIN/pg_ctl" -D "$dir" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$dir"
  psql -p 5432 -d postgres -qc "SELECT pg_drop_replication_slot('replica${n}_slot') FROM pg_replication_slots WHERE slot_name='replica${n}_slot'" >/dev/null
  "$PGBIN/pg_basebackup" -h localhost -p 5432 -U replicator -D "$dir" \
       -X stream -R -C -S "replica${n}_slot" -c fast
  # give each standby its own port and a name the primary can refer to
  echo "port = $port" >> "$dir/postgresql.auto.conf"
  sed -i "s/primary_conninfo = '/primary_conninfo = 'application_name=replica$n /" "$dir/postgresql.auto.conf"
  "$PGBIN/pg_ctl" -D "$dir" -l "$BASE/replica$n.log" -w start >/dev/null
  echo "   replica$n up on :$port"
done

echo "== 3. Two independent shard servers"
for s in a b; do
  port=$([ $s = a ] && echo 5441 || echo 5442); dir="$BASE/shard_$s"
  "$PGBIN/pg_ctl" -D "$dir" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$dir"
  "$PGBIN/initdb" -D "$dir" -A trust -U postgres >/dev/null
  "$PGBIN/pg_ctl" -D "$dir" -o "-p $port" -l "$BASE/shard_$s.log" -w start >/dev/null
  echo "   shard_$s up on :$port"
done

echo "== Topology"
psql -p 5432 -d postgres -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication ORDER BY 1"
for p in 5433 5434; do psql -p $p -d postgres -Atc "SELECT ':$p in recovery (read-only standby) = ' || pg_is_in_recovery()"; done
