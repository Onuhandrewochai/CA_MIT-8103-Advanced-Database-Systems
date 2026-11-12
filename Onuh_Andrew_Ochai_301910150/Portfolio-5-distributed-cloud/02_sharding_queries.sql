-- =====================================================================================
-- Portfolio 5 — evidence that rows are routed to shards and queries are pruned / pushed down
-- Run after loading data:  psql -p 5432 -d carebridge_dist -f 02_sharding_queries.sql
-- =====================================================================================
\echo '== Row distribution (seen from the coordinator)'
SELECT tableoid::regclass AS partition, count(*) AS rows FROM appointment GROUP BY 1 ORDER BY 1;

\echo '== Same counts read DIRECTLY on each shard server'
\connect "port=5441 dbname=postgres host=localhost"
SELECT 'shard_a :5441' AS server, count(*) FROM appointment_p0;
\connect "port=5442 dbname=postgres host=localhost"
SELECT 'shard_b :5442' AS server, count(*) FROM appointment_p1;
\connect "port=5432 dbname=carebridge_dist host=localhost"

\echo '== Q1 single-shard query: patient history. Shard key in WHERE -> partition pruning -> ONE remote scan'
EXPLAIN (VERBOSE, COSTS OFF)
SELECT appointment_id, scheduled_at, status FROM appointment
WHERE patient_id = 4321 ORDER BY scheduled_at DESC LIMIT 20;
SELECT appointment_id, scheduled_at, status FROM appointment
WHERE patient_id = 4321 ORDER BY scheduled_at DESC LIMIT 5;

\echo '== Q2a scatter-gather, DEFAULT settings: both shards scanned, every matching row shipped to the coordinator'
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT branch_id, count(*) FROM appointment
WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01' GROUP BY branch_id;

\echo '== Q2b same query with enable_partitionwise_aggregate = on: aggregation split per shard, but PG16 postgres_fdw'
\echo '        cannot push PARTIAL aggregates, so rows are still shipped (branch_id is not the shard key)'
SET enable_partitionwise_aggregate = on;
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT branch_id, count(*) FROM appointment
WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01' GROUP BY branch_id;
\echo '== Q2c GROUP BY the shard key (patient_id): FULL aggregate pushdown, each shard runs GROUP BY itself'
EXPLAIN (ANALYZE, VERBOSE, COSTS OFF)
SELECT patient_id, count(*) AS visits FROM appointment
WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01'
GROUP BY patient_id ORDER BY visits DESC LIMIT 5;
RESET enable_partitionwise_aggregate;

SELECT b.name, count(*) AS visits_2025
FROM appointment a JOIN branch b USING (branch_id)
WHERE a.scheduled_at >= '2025-01-01' AND a.scheduled_at < '2026-01-01'
GROUP BY b.name ORDER BY 1;

\echo '== Q3 an INSERT is routed to the correct shard by hash(patient_id)'
INSERT INTO appointment VALUES (9000001, 4321, 57, 2, '2026-12-02 10:00+01', 'BOOKED');
SELECT tableoid::regclass AS landed_on, appointment_id, patient_id FROM appointment WHERE appointment_id = 9000001 AND patient_id = 4321;
DELETE FROM appointment WHERE appointment_id = 9000001 AND patient_id = 4321;
