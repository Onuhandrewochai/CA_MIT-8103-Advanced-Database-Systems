/*
================================================================================
 Portfolio 5 - Replication, consistency vs availability, and failover
               for CareBridge Clinics  (psql script version of replication_demo.py)
================================================================================
 Requires the topology from setup_cluster.sh:
     primary :5432    replica1 :5433    replica2 :5434

   A. Topology and read-only standbys
   B. Replication lag (asynchronous)
   C. Stale reads on an async replica vs read-your-writes with remote_apply
   D. Commit latency for each synchronous_commit level
   E. Availability trade-off: synchronous standby goes down -> commits block;
      quorum fixes it
   F. Failover: crash the primary, promote replica1, measure RTO / RPO,
      re-point replica2

 How the Python parts are done in SQL
   several connections       -> dblink (contrib) to reach the other servers
   background thread         -> dblink_send_query() runs a statement on another
                                session while this script keeps working
   commit timing             -> DO blocks with COMMIT inside the loop +
                                clock_timestamp()
   pg_ctl stop/start/promote -> psql \! shell commands

 HOW TO RUN
   Run as the OS user that owns the data directories (pg_ctl needs it), with
   PGBIN and BASE exported to match setup_cluster.sh:

     export PGBIN=/usr/lib/postgresql/16/bin  BASE=$HOME/pg
     mkdir -p output
     psql -h localhost -p 5432 -U postgres -d carebridge -f replication_demo.sql 2>&1 \
         | tee output/replication_demo_output.txt

   (2>&1 matters: the measurements are printed with RAISE NOTICE.)

   If the data directories belong to the postgres OS user:
     sudo -u postgres env PGBIN=... BASE=... psql ... -f replication_demo.sql

 dblink connects to each server as user postgres on localhost without a
 password, as the Python version did. If your pg_hba.conf requires passwords,
 add password=... to the conninfo strings in repl_demo.node below.

 WARNING: section F leaves replica1 as the new primary on :5433 and the old
 primary stopped. Re-run setup_cluster.sh to reset.
================================================================================
*/
\set ON_ERROR_STOP on
\pset pager off
\set VERBOSITY terse

\echo
\echo '=========================================================================================='
\echo 'A. Topology: one primary, two streaming standbys'
\echo '=========================================================================================='

CREATE EXTENSION IF NOT EXISTS dblink;
DROP SCHEMA IF EXISTS repl_demo CASCADE;
CREATE SCHEMA repl_demo;

-- Connection strings for every node. Everything in this schema replicates to
-- the standbys, so it is still available after failover.
CREATE TABLE repl_demo.node (name text PRIMARY KEY, conninfo text NOT NULL);
INSERT INTO repl_demo.node VALUES
  ('primary',  'host=localhost port=5432 dbname=carebridge user=postgres connect_timeout=3'),
  ('replica1', 'host=localhost port=5433 dbname=carebridge user=postgres connect_timeout=3'),
  ('replica2', 'host=localhost port=5434 dbname=carebridge user=postgres connect_timeout=3');

CREATE FUNCTION repl_demo.conn(p_name text) RETURNS text
LANGUAGE sql STABLE AS $$ SELECT conninfo FROM repl_demo.node WHERE name = p_name $$;

-- show_replication(): run on whichever server is currently primary
CREATE VIEW repl_demo.replication_status AS
SELECT application_name, state, sync_state, sync_priority,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication
ORDER BY application_name;

-- Collected measurements (written on the primary, so they replicate too)
CREATE TABLE repl_demo.measure (section text, label text, ms double precision);

ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf() AS config_reloaded;
SELECT pg_sleep(0.5);

CREATE TABLE IF NOT EXISTS clinic.replication_probe (
    id         bigserial PRIMARY KEY,
    note       text,
    written_at timestamptz DEFAULT clock_timestamp()
);
TRUNCATE clinic.replication_probe;
SELECT pg_sleep(1);

SELECT * FROM repl_demo.replication_status;

SELECT n.name                          AS standby,
       r.in_recovery                   AS pg_is_in_recovery,
       to_char(r.appts, 'FM9,999,999') AS appointments_visible
FROM repl_demo.node n,
     LATERAL dblink(n.conninfo,
                    'SELECT pg_is_in_recovery(), count(*) FROM clinic.appointment')
             AS r(in_recovery boolean, appts bigint)
WHERE n.name <> 'primary'
ORDER BY n.name;

-- A write on a standby must fail with 25006
DO $$
DECLARE v_state text; v_msg text;
BEGIN
    PERFORM dblink_exec(repl_demo.conn('replica2'),
                        'INSERT INTO clinic.replication_probe (note) VALUES (''write to standby'')');
    RAISE NOTICE 'write on replica2 unexpectedly succeeded';
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE NOTICE 'write attempted on replica2 -> ERROR %: %', v_state, v_msg;
END $$;


\echo
\echo '=========================================================================================='
\echo 'B. Asynchronous replication lag (time until a committed row is visible on each standby)'
\echo '=========================================================================================='

SELECT dblink_connect('r1', repl_demo.conn('replica1'));
SELECT dblink_connect('r2', repl_demo.conn('replica2'));

-- 50 single-row commits; after each COMMIT, poll both standbys until the row appears
DO $$
DECLARE
    i int; rid bigint; t0 timestamptz; c text;
    lag_r1 double precision[] := '{}'; lag_r2 double precision[] := '{}';
BEGIN
    FOR i IN 1..50 LOOP
        INSERT INTO clinic.replication_probe (note) VALUES ('lag-' || i) RETURNING id INTO rid;
        COMMIT;
        t0 := clock_timestamp();
        FOREACH c IN ARRAY ARRAY['r1', 'r2'] LOOP
            LOOP
                EXIT WHEN EXISTS (SELECT 1 FROM dblink(c, format(
                        'SELECT 1 FROM clinic.replication_probe WHERE id = %s', rid)) AS t(x int));
            END LOOP;
            IF c = 'r1' THEN
                lag_r1 := lag_r1 || extract(epoch FROM clock_timestamp() - t0) * 1000;
            ELSE
                lag_r2 := lag_r2 || extract(epoch FROM clock_timestamp() - t0) * 1000;
            END IF;
        END LOOP;
    END LOOP;
    INSERT INTO repl_demo.measure SELECT 'B', 'replica1', unnest(lag_r1);
    INSERT INTO repl_demo.measure SELECT 'B', 'replica2', unnest(lag_r2);
END $$;

SELECT label                                                                   AS standby,
       count(*)                                                                AS commits,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2)      AS median_visibility_ms,
       round(max(ms)::numeric, 2)                                              AS max_ms
FROM repl_demo.measure WHERE section = 'B' GROUP BY label ORDER BY label;

-- Bulk write (200,000 rows, one transaction) on a second session, sampling lag meanwhile
\echo 'Bulk write (200,000 rows in one transaction) while sampling lag in bytes:'
SELECT dblink_connect('bulk', repl_demo.conn('primary'));
SELECT dblink_send_query('bulk',
    'INSERT INTO clinic.replication_probe (note) SELECT ''bulk'' FROM generate_series(1, 200000)') AS bulk_started;

DO $$
DECLARE peak numeric := 0; cur numeric;
BEGIN
    WHILE dblink_is_busy('bulk') = 1 LOOP
        SELECT max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) INTO cur FROM pg_stat_replication;
        peak := greatest(peak, COALESCE(cur, 0));
        PERFORM pg_sleep(0.02);
    END LOOP;
    RAISE NOTICE 'peak replay lag observed: % KB of WAL', to_char(peak / 1024, 'FM999,999,999');
END $$;

SELECT * FROM dblink_get_result('bulk') AS t(status text);
SELECT dblink_disconnect('bulk');
SELECT pg_sleep(1);
\echo 'after catch-up:'
SELECT * FROM repl_demo.replication_status;


\echo
\echo '=========================================================================================='
\echo 'C. Consistency: stale reads (async) vs read-your-writes (synchronous_commit = remote_apply)'
\echo '=========================================================================================='

ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)';
SELECT pg_reload_conf() AS config_reloaded;
SELECT pg_sleep(0.5);
SELECT * FROM repl_demo.replication_status;

-- Write on the primary, then read IMMEDIATELY from a standby; count misses
CREATE PROCEDURE repl_demo.stale_test(p_level text, p_conn text, p_n int DEFAULT 200)
LANGUAGE plpgsql AS $$
DECLARE i int; rid bigint; stale int := 0;
BEGIN
    PERFORM set_config('synchronous_commit', p_level, false);
    FOR i IN 1..p_n LOOP
        INSERT INTO clinic.replication_probe (note) VALUES ('ryw') RETURNING id INTO rid;
        COMMIT;
        IF NOT EXISTS (SELECT 1 FROM dblink(p_conn, format(
                'SELECT 1 FROM clinic.replication_probe WHERE id = %s', rid)) AS t(x int)) THEN
            stale := stale + 1;
        END IF;
    END LOOP;
    PERFORM set_config('synchronous_commit', 'on', false);
    RAISE NOTICE 'write on primary (synchronous_commit = %), read IMMEDIATELY from %: stale reads = %/%',
                 rpad(p_level, 12), rpad(p_conn, 2), stale, p_n;
END $$;

\echo 'r2 = async replica2, r1 = synchronous replica1'
CALL repl_demo.stale_test('local',        'r2');
CALL repl_demo.stale_test('remote_apply', 'r1');


\echo
\echo '=========================================================================================='
\echo 'D. Commit latency by synchronous_commit level (replica1 is the synchronous standby)'
\echo '=========================================================================================='

DO $$
DECLARE
    lvl text; i int; t0 timestamptz;
    ts double precision[];
BEGIN
    FOREACH lvl IN ARRAY ARRAY['off', 'local', 'remote_write', 'on', 'remote_apply'] LOOP
        PERFORM set_config('synchronous_commit', lvl, false);
        ts := '{}';
        FOR i IN 1..300 LOOP
            t0 := clock_timestamp();
            INSERT INTO clinic.replication_probe (note) VALUES ('latency');
            COMMIT;
            ts := ts || extract(epoch FROM clock_timestamp() - t0) * 1000;
        END LOOP;
        PERFORM set_config('synchronous_commit', 'on', false);
        INSERT INTO repl_demo.measure SELECT 'D', lvl, unnest(ts);
        COMMIT;
    END LOOP;
END $$;

SELECT label                                                              AS synchronous_commit,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 3) AS median_commit_ms
FROM repl_demo.measure WHERE section = 'D'
GROUP BY label
ORDER BY array_position(ARRAY['off','local','remote_write','on','remote_apply'], label);
\echo '(single machine, so network latency is ~0; across availability zones each sync level adds a round trip)'


\echo
\echo '=========================================================================================='
\echo 'E. Availability trade-off: the only synchronous standby fails'
\echo '=========================================================================================='

SELECT dblink_disconnect('r1');
\! "$PGBIN/pg_ctl" -D "$BASE/replica1" stop -m fast
\echo 'replica1 stopped'

-- A second session on the primary tries to commit while the only sync standby is down
SELECT dblink_connect('blocked', repl_demo.conn('primary'));
SELECT pid AS blocked_pid FROM dblink('blocked', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT clock_timestamp() AS t_block_start \gset
SELECT dblink_send_query('blocked',
    'INSERT INTO clinic.replication_probe (note) VALUES (''during-outage'')') AS commit_sent;
SELECT pg_sleep(3);

SELECT 'COMMIT still waiting after 3 s' AS observation, wait_event_type, wait_event, state
FROM pg_stat_activity WHERE pid = :blocked_pid;

SELECT pg_cancel_backend(:blocked_pid) AS cancel_sent;
SELECT pg_sleep(0.5);
-- The cancelled session receives the server WARNING
--   "canceling wait for synchronous replication due to user request
--    DETAIL: The transaction has already committed locally, but might not have
--    been replicated to the standby."
-- (dblink does not relay WARNINGs; the text is also in the primary's server log.)
-- The proof is the result below: the statement reports INSERT 0 1, not an error -
-- cancelling the wait did NOT roll the row back.
SELECT * FROM dblink_get_result('blocked', false) AS t(status text);
SELECT round(extract(epoch FROM clock_timestamp() - :'t_block_start'::timestamptz)::numeric, 1)
       AS cancelled_after_s;
SELECT dblink_disconnect('blocked');

SELECT count(*) AS during_outage_rows_on_primary,
       'committed LOCALLY but was not confirmed by a standby' AS meaning
FROM clinic.replication_probe WHERE note = 'during-outage';

-- Fix: quorum commit - any one of the two standbys may acknowledge
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (replica1, replica2)';
SELECT pg_reload_conf() AS config_reloaded;
SELECT pg_sleep(0.5);

DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    INSERT INTO clinic.replication_probe (note) VALUES ('quorum');
    COMMIT;
    RAISE NOTICE 'switched to quorum ''ANY 1 (replica1, replica2)'' -> commit succeeded in % ms (replica2 acknowledged)',
                 round((extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric, 2);
END $$;
SELECT * FROM repl_demo.replication_status;

\! "$PGBIN/pg_ctl" -D "$BASE/replica1" -l "$BASE/replica1.log" -w start
SELECT pg_sleep(2);
\echo 'replica1 restarted and caught up:'
SELECT * FROM repl_demo.replication_status;


\echo
\echo '=========================================================================================='
\echo 'F. Failover: primary crashes, replica1 is promoted'
\echo '=========================================================================================='

ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)';
SELECT pg_reload_conf() AS config_reloaded;
SELECT pg_sleep(0.5);
SET synchronous_commit = on;

INSERT INTO clinic.replication_probe (note) VALUES ('last-commit-before-crash')
RETURNING id AS last_id \gset
\echo 'committed row id' :last_id '(synchronous) - then simulate a crash with pg_ctl stop -m immediate'

SELECT dblink_disconnect('r2');

-- Move this psql session to replica1 BEFORE the crash (the primary is about to die)
\c carebridge postgres localhost 5433
\set VERBOSITY terse
SELECT clock_timestamp() AS t_crash \gset

\! "$PGBIN/pg_ctl" -D "$BASE/primary" stop -m immediate

DO $$
BEGIN
    PERFORM dblink_connect('dead', repl_demo.conn('primary'));
    RAISE NOTICE 'primary still reachable?!';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'primary unreachable: connection refused';
END $$;

\! "$PGBIN/pg_ctl" -D "$BASE/replica1" promote -w

-- Wait until replica1 has left recovery, then write to it
DO $$
BEGIN
    WHILE pg_is_in_recovery() LOOP
        PERFORM pg_sleep(0.05);
    END LOOP;
END $$;
INSERT INTO clinic.replication_probe (note) VALUES ('first-write-on-new-primary');

SELECT round(extract(epoch FROM clock_timestamp() - :'t_crash'::timestamptz)::numeric, 2)
       AS rto_seconds_excluding_failure_detection;
\echo 'replica1 (:5433) is now primary and has accepted a write'

SELECT :last_id AS last_sync_commit_id,
       EXISTS (SELECT 1 FROM clinic.replication_probe WHERE id = :last_id) AS present_on_new_primary,
       'RPO = 0 transactions lost' AS meaning;

SELECT ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int AS wal_timeline_on_new_primary,
       'was 1; promotion starts a new timeline so old and new histories cannot be confused' AS note;

\echo 'replica2 still follows the dead primary; re-point it at the new primary:'
\c carebridge postgres localhost 5434
ALTER SYSTEM SET primary_conninfo = 'host=localhost port=5433 user=replicator application_name=replica2';
ALTER SYSTEM SET primary_slot_name = '';
\! "$PGBIN/pg_ctl" -D "$BASE/replica2" -l "$BASE/replica2.log" -w restart -m fast

\c carebridge postgres localhost 5433
\set VERBOSITY terse
DO $$
DECLARE i int;
BEGIN
    FOR i IN 1..100 LOOP
        EXIT WHEN EXISTS (SELECT 1 FROM pg_stat_replication WHERE state = 'streaming');
        PERFORM pg_sleep(0.1);
    END LOOP;
END $$;
\echo 'new primary''s pg_stat_replication:'
SELECT application_name, state FROM pg_stat_replication;

SELECT pg_sleep(1);
SELECT r.n = 1 AS replica2_sees_post_failover_write
FROM dblink(repl_demo.conn('replica2'),
            'SELECT count(*) FROM clinic.replication_probe WHERE note = ''first-write-on-new-primary''')
     AS r(n bigint);

\echo 'The old primary must NOT simply be restarted (split brain / diverged WAL): rebuild it with pg_rewind or pg_basebackup.'
