/*
================================================================================
 Portfolio 4b - Key-value model in PostgreSQL for CareBridge Clinics
================================================================================
 PostgreSQL version of key_value_redis.py. The same four clinic problems:
   1. Cache-aside patient summary          (Redis HASH + EXPIRE)  -> kv.cache
   2. Temporary slot hold (WhatsApp)       (SET NX EX)            -> kv.hold
   3. Live waiting-room queue per doctor   (SORTED SET)           -> kv.queue
   4. Real-time per-branch counters        (HINCRBY)              -> kv.counter

 How the Redis features are reproduced
   in-memory, no durability   -> UNLOGGED tables (no WAL; emptied after a crash,
                                 just like a Redis node without persistence)
   EXPIRE / TTL               -> an expires_at column; reads ignore expired rows;
                                 kv.purge_expired() deletes them (schedule it, e.g. pg_cron)
   SET key value NX EX        -> INSERT ... ON CONFLICT DO UPDATE ... WHERE expired
   Lua compare-and-delete     -> DELETE ... WHERE key = $1 AND owner = $2
   ZADD / ZRANK / ZPOPMIN     -> table + index on (queue_key, score);
                                 ZPOPMIN uses FOR UPDATE SKIP LOCKED
   HINCRBY (atomic)           -> INSERT ... ON CONFLICT DO UPDATE SET value = value + n

 Each Redis command is wrapped in a function with the same name (kv.hgetall,
 kv.zadd, kv.hincrby, ...), so the demo below reads like the Python original.

 Usage (run from the folder that should receive output/):
   mkdir -p output
   psql -d carebridge -f key_value_store.sql | tee output/key_value_output.txt

 The concurrency proofs at the end of this file use pgbench (ships with PostgreSQL).
 Requires the Portfolio 1-2 database (schema "clinic").
================================================================================
*/
\set ON_ERROR_STOP on
\pset pager off
SET search_path TO clinic, public;
SET TIME ZONE 'UTC';

-- ----------------------------------------------------------------------------
-- 0. Key-value "keyspace"
-- ----------------------------------------------------------------------------
DROP SCHEMA IF EXISTS kv CASCADE;          -- = FLUSHDB
CREATE SCHEMA kv;

CREATE UNLOGGED TABLE kv.cache (           -- HASH values with a TTL
    key         text        PRIMARY KEY,
    value       jsonb       NOT NULL,
    expires_at  timestamptz NOT NULL
);

CREATE UNLOGGED TABLE kv.hold (            -- short-lived locks / claims
    key         text        PRIMARY KEY,
    owner       text        NOT NULL,
    expires_at  timestamptz NOT NULL
);

CREATE UNLOGGED TABLE kv.queue (           -- sorted sets
    queue_key   text             NOT NULL,
    member      text             NOT NULL,
    score       double precision NOT NULL,
    PRIMARY KEY (queue_key, member)
);
CREATE INDEX ix_queue_score ON kv.queue (queue_key, score, member);

CREATE UNLOGGED TABLE kv.counter (         -- hash of integer counters
    key         text   NOT NULL,
    field       text   NOT NULL,
    value       bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (key, field)
);

-- ----------------------------------------------------------------------------
-- Redis-style commands
-- clock_timestamp() (not now()) so TTLs stay correct inside long transactions.
-- ----------------------------------------------------------------------------

-- HGETALL key  (expired keys behave as missing)
CREATE FUNCTION kv.hgetall(p_key text) RETURNS jsonb
LANGUAGE sql AS $$
    SELECT value FROM kv.cache WHERE key = p_key AND expires_at > clock_timestamp();
$$;

-- HSET key {...} + EXPIRE key ttl   (one atomic upsert)
CREATE FUNCTION kv.hset_ex(p_key text, p_value jsonb, p_ttl_s int) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO kv.cache (key, value, expires_at)
    VALUES (p_key, p_value, clock_timestamp() + make_interval(secs => p_ttl_s))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at;
$$;

-- DEL key
CREATE FUNCTION kv.del(p_key text) RETURNS int
LANGUAGE sql AS $$
    WITH d AS (DELETE FROM kv.cache WHERE key = p_key RETURNING 1) SELECT count(*)::int FROM d;
$$;

-- TTL key  (-2 = key does not exist, as in Redis)
CREATE FUNCTION kv.ttl(p_key text) RETURNS int
LANGUAGE sql AS $$
    SELECT COALESCE(
        (SELECT ceil(extract(epoch FROM expires_at - clock_timestamp()))::int
           FROM kv.cache WHERE key = p_key AND expires_at > clock_timestamp()),
        (SELECT ceil(extract(epoch FROM expires_at - clock_timestamp()))::int
           FROM kv.hold  WHERE key = p_key AND expires_at > clock_timestamp()),
        -2);
$$;

-- SET key owner NX EX ttl  -> true if this caller now owns the key.
-- An existing key is only taken over if it has expired. ON CONFLICT is atomic:
-- concurrent callers for the same key queue on the row and exactly one wins.
CREATE FUNCTION kv.set_nx_ex(p_key text, p_owner text, p_ttl_s int) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO kv.hold AS h (key, owner, expires_at)
    VALUES (p_key, p_owner, clock_timestamp() + make_interval(secs => p_ttl_s))
    ON CONFLICT (key) DO UPDATE
        SET owner = EXCLUDED.owner, expires_at = EXCLUDED.expires_at
        WHERE h.expires_at <= clock_timestamp();
    RETURN FOUND;
END $$;

-- GET key (for holds)
CREATE FUNCTION kv.get_hold(p_key text) RETURNS text
LANGUAGE sql AS $$
    SELECT owner FROM kv.hold WHERE key = p_key AND expires_at > clock_timestamp();
$$;

-- Owner-only release (the Redis Lua compare-and-delete): 1 = released, 0 = not owner
CREATE FUNCTION kv.release(p_key text, p_owner text) RETURNS int
LANGUAGE sql AS $$
    WITH d AS (DELETE FROM kv.hold WHERE key = p_key AND owner = p_owner RETURNING 1)
    SELECT count(*)::int FROM d;
$$;

-- ZADD queue {member: score}
CREATE FUNCTION kv.zadd(p_queue text, p_member text, p_score double precision) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO kv.queue (queue_key, member, score) VALUES (p_queue, p_member, p_score)
    ON CONFLICT (queue_key, member) DO UPDATE SET score = EXCLUDED.score;
$$;

-- ZRANGE queue 0 -1
CREATE FUNCTION kv.zrange(p_queue text) RETURNS text[]
LANGUAGE sql AS $$
    SELECT COALESCE(array_agg(member ORDER BY score, member), '{}')
    FROM kv.queue WHERE queue_key = p_queue;
$$;

-- ZRANK queue member  (0-based, NULL if absent)
CREATE FUNCTION kv.zrank(p_queue text, p_member text) RETURNS int
LANGUAGE sql AS $$
    SELECT (SELECT count(*)::int FROM kv.queue q
             WHERE q.queue_key = p_queue AND (q.score, q.member) < (me.score, me.member))
    FROM kv.queue me
    WHERE me.queue_key = p_queue AND me.member = p_member;
$$;

-- ZPOPMIN queue  (SKIP LOCKED: two doctors popping at once never get the same patient)
CREATE FUNCTION kv.zpopmin(p_queue text) RETURNS text
LANGUAGE sql AS $$
    DELETE FROM kv.queue
    WHERE (queue_key, member) = (
        SELECT queue_key, member FROM kv.queue
        WHERE queue_key = p_queue
        ORDER BY score, member
        LIMIT 1
        FOR UPDATE SKIP LOCKED)
    RETURNING member;
$$;

-- ZCARD queue
CREATE FUNCTION kv.zcard(p_queue text) RETURNS int
LANGUAGE sql AS $$
    SELECT count(*)::int FROM kv.queue WHERE queue_key = p_queue;
$$;

-- HINCRBY key field n  (atomic: the upsert row-locks the counter)
CREATE FUNCTION kv.hincrby(p_key text, p_field text, p_n bigint) RETURNS bigint
LANGUAGE sql AS $$
    INSERT INTO kv.counter (key, field, value) VALUES (p_key, p_field, p_n)
    ON CONFLICT (key, field) DO UPDATE SET value = kv.counter.value + EXCLUDED.value
    RETURNING value;
$$;

-- HGETALL for counters
CREATE FUNCTION kv.hgetall_counter(p_key text) RETURNS jsonb
LANGUAGE sql AS $$
    SELECT COALESCE(jsonb_object_agg(field, value ORDER BY field), '{}')
    FROM kv.counter WHERE key = p_key;
$$;

-- Housekeeping: remove expired keys (Redis does this itself; here, schedule it)
CREATE FUNCTION kv.purge_expired() RETURNS int
LANGUAGE sql AS $$
    WITH a AS (DELETE FROM kv.cache WHERE expires_at <= clock_timestamp() RETURNING 1),
         b AS (DELETE FROM kv.hold  WHERE expires_at <= clock_timestamp() RETURNING 1)
    SELECT ((SELECT count(*) FROM a) + (SELECT count(*) FROM b))::int;
$$;


-- ============================================================================
\echo
\echo '=== 1. Cache-aside: patient summary (jsonb value with 10-minute TTL)'
-- ============================================================================

-- Cache-aside read: try the cache, on a miss run the 3-table aggregate and populate.
CREATE FUNCTION kv.get_patient_summary(p_hosp_no text, OUT data jsonb, OUT status text)
LANGUAGE plpgsql AS $$
DECLARE
    k text := 'patient:' || p_hosp_no || ':summary';
BEGIN
    data := kv.hgetall(k);
    IF data IS NOT NULL THEN
        status := 'HIT';
        RETURN;
    END IF;

    SELECT jsonb_build_object(
             'hospital_no',     p.hospital_no,
             'name',            p.first_name || ' ' || p.last_name,
             'blood_group',     p.blood_group,
             'visits',          count(a.*),
             'last_visit',      max(a.scheduled_at)::date,
             'diagnosis_codes', (SELECT string_agg(DISTINCT dg.icd10_code, ',')
                                   FROM appointment a2 JOIN diagnosis dg USING (appointment_id)
                                  WHERE a2.patient_id = p.patient_id))
      INTO data
      FROM patient p LEFT JOIN appointment a ON a.patient_id = p.patient_id
     WHERE p.hospital_no = p_hosp_no
     GROUP BY p.patient_id;

    PERFORM kv.hset_ex(k, data, 600);
    status := 'MISS';
END $$;

-- 200 misses then 200 hits, timed individually; medians reported
CREATE TEMP TABLE timings (kind text, ms double precision);

DO $$
DECLARE
    i int; t0 timestamptz; s text; hn text;
BEGIN
    FOR i IN 1..200 LOOP
        hn := format('CBC-%s', lpad(i::text, 7, '0'));
        t0 := clock_timestamp();
        SELECT status INTO s FROM kv.get_patient_summary(hn);
        INSERT INTO timings VALUES ('MISS', extract(epoch FROM clock_timestamp() - t0) * 1000);
        ASSERT s = 'MISS', 'expected MISS for ' || hn;
    END LOOP;
    FOR i IN 1..200 LOOP
        hn := format('CBC-%s', lpad(i::text, 7, '0'));
        t0 := clock_timestamp();
        SELECT status INTO s FROM kv.get_patient_summary(hn);
        INSERT INTO timings VALUES ('HIT', extract(epoch FROM clock_timestamp() - t0) * 1000);
        ASSERT s = 'HIT', 'expected HIT for ' || hn;
    END LOOP;
END $$;

SELECT kind                                                              AS lookup,
       count(*)                                                          AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 3) AS median_ms
FROM timings GROUP BY kind ORDER BY kind DESC;

SELECT round(( (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) FROM timings WHERE kind = 'MISS')
             / (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) FROM timings WHERE kind = 'HIT'))::numeric, 1)
       AS hit_speedup_x;

SELECT kv.hgetall('patient:CBC-0000001:summary') AS "HGETALL patient:CBC-0000001:summary";
SELECT kv.ttl('patient:CBC-0000001:summary')     AS ttl_remaining_s;

-- Invalidation on write: when the patient's record changes, delete the key
SELECT kv.del('patient:CBC-0000001:summary') AS keys_deleted;
SELECT status AS next_read_after_del FROM kv.get_patient_summary('CBC-0000001');   -- MISS: fresh from the tables


-- ============================================================================
\echo
\echo '=== 2. Slot hold: claim-if-free with auto-expiry (SET NX EX 120 equivalent)'
-- ============================================================================
\set slot_key 'hold:doctor:57:2026-12-01T09:00'

-- 10 receptionists try to claim the same slot (sequential here; see the pgbench
-- proof at the end of the file for 10 truly concurrent sessions)
SELECT desk, kv.set_nx_ex(:'slot_key', desk, 120) AS claimed
FROM (SELECT 'desk-' || g AS desk FROM generate_series(0, 9) g) d;

SELECT kv.get_hold(:'slot_key') AS owner, kv.ttl(:'slot_key') AS ttl_s;

-- Safe release: only the owner may release it
SELECT kv.release(:'slot_key', 'desk-x') AS release_by_wrong_desk,
       kv.release(:'slot_key', 'desk-0') AS release_by_owner;

\echo 'On confirmation the booking is INSERTed into clinic.appointment, where'
\echo 'uq_doctor_active_slot is still the final guarantee against double-booking.'


-- ============================================================================
\echo
\echo '=== 3. Waiting-room queue per doctor (sorted set, score = check-in time)'
-- ============================================================================
\set qkey 'queue:doctor:57:2026-11-11'

SELECT count(*) AS patients_checked_in
FROM (SELECT kv.zadd(:'qkey', member, 1762848000 + offset_s)
      FROM (VALUES ('CBC-0000012', 0), ('CBC-0004321', 95), ('CBC-0000777', 140),
                   ('CBC-0009001', 310), ('CBC-0000450', 420)) AS c(member, offset_s)) s;

SELECT kv.zrange(:'qkey') AS "ZRANGE 0 -1";
SELECT kv.zrank(:'qkey', 'CBC-0000777') + 1 AS "CBC-0000777 position in line";

SELECT kv.zpopmin(:'qkey') AS doctor_calls_next;
SELECT kv.zcard(:'qkey') AS now_waiting,
       kv.zrank(:'qkey', 'CBC-0000777') + 1 AS "CBC-0000777 is now number";
-- Queues are per day (the date is in the key); a nightly
-- DELETE FROM kv.queue WHERE queue_key LIKE '%:<yesterday>' replaces EXPIRE 86400.


-- ============================================================================
\echo
\echo '=== 4. Real-time dashboard counters (atomic HINCRBY)'
-- ============================================================================
\set day '2026-11-11'

-- 4 front desks per branch x 250 check-ins each (sequential here; see pgbench below)
SELECT count(kv.hincrby('stats:' || :'day' || ':checkins', b.name, 1)) AS increments_applied
FROM branch b, generate_series(1, 4) desk, generate_series(1, 250) n;

SELECT kv.hgetall_counter('stats:' || :'day' || ':checkins') AS checkins_per_branch;

SELECT kv.hincrby('stats:' || :'day' || ':diagnoses', 'B54', 37) AS b54,
       kv.hincrby('stats:' || :'day' || ':diagnoses', 'I10', 12) AS i10;
SELECT kv.hgetall_counter('stats:' || :'day' || ':diagnoses') AS diagnoses_today;


-- ============================================================================
\echo
\echo '=== Keyspace summary'
-- ============================================================================
SELECT 'cache' AS kind, count(*) AS keys FROM kv.cache
UNION ALL SELECT 'hold',    count(*) FROM kv.hold
UNION ALL SELECT 'queue',   count(DISTINCT queue_key) FROM kv.queue
UNION ALL SELECT 'counter', count(DISTINCT key) FROM kv.counter;

SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) AS kv_storage_used
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'kv' AND c.relkind = 'r';


/* ============================================================================
 CONCURRENCY PROOFS (optional, run from a shell with pgbench)
 psql runs one session, so the demos above are sequential. These pgbench runs
 open many real sessions at once against the functions above.

 (a) 10 receptionists race for one slot -> exactly 1 winner
     Save as hold_race.sql:
         SELECT kv.set_nx_ex('hold:doctor:57:2026-12-02T09:00', 'desk-' || :client_id, 120);
     Run:
         pgbench -n -c 10 -j 10 -t 1 -f hold_race.sql carebridge
         psql -d carebridge -c "SELECT * FROM kv.hold WHERE key = 'hold:doctor:57:2026-12-02T09:00'"
     Expected: one row, one owner.

 (b) 16 front desks x 250 check-ins (4 desks per branch) -> exactly 1000 per branch
     Save as checkins.sql:
         SELECT kv.hincrby('stats:concurrent:checkins',
                           (SELECT name FROM clinic.branch ORDER BY branch_id OFFSET (:client_id % 4) LIMIT 1), 1);
     Run:
         pgbench -n -c 16 -j 16 -t 250 -f checkins.sql carebridge
         psql -d carebridge -c "SELECT kv.hgetall_counter('stats:concurrent:checkins')"
     Expected: every branch = 1000, no lost updates.

 Trade-off vs Redis: every increment here takes a row lock and goes through the
 PostgreSQL executor, so a hot counter row serialises its writers. Redis's
 single-threaded in-memory commands are much faster for very hot counters; the
 PostgreSQL version is correct but best kept to moderate write rates.
============================================================================ */
