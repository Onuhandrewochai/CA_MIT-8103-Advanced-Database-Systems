-- =====================================================================================
-- Portfolio 5 — horizontal sharding of appointments across two PostgreSQL servers
-- Coordinator: database carebridge_dist on :5432.  Shards: :5441 (shard_a), :5442 (shard_b)
-- Technique: declarative HASH partitioning where each partition is a FOREIGN TABLE
-- (postgres_fdw) living on another server — the same idea Citus automates.
-- Shard key: patient_id -> all of one patient's visits are co-located on one shard,
-- so the most common query (patient history) touches exactly one server.
-- Run:  psql -p 5432 -d postgres -f 01_sharding.sql
-- =====================================================================================
\set ON_ERROR_STOP on
DROP DATABASE IF EXISTS carebridge_dist;
CREATE DATABASE carebridge_dist;
\c carebridge_dist

-- ---- create the physical tables on each shard server (psql \connect switches servers)
\connect "port=5441 dbname=postgres host=localhost"
DROP TABLE IF EXISTS appointment_p0;
CREATE TABLE appointment_p0 (
    appointment_id BIGINT PRIMARY KEY, patient_id INT NOT NULL, doctor_id INT NOT NULL,
    branch_id SMALLINT NOT NULL, scheduled_at TIMESTAMPTZ NOT NULL, status VARCHAR(12) NOT NULL
);
CREATE INDEX ON appointment_p0 (patient_id, scheduled_at DESC);

\connect "port=5442 dbname=postgres host=localhost"
DROP TABLE IF EXISTS appointment_p1;
CREATE TABLE appointment_p1 (
    appointment_id BIGINT PRIMARY KEY, patient_id INT NOT NULL, doctor_id INT NOT NULL,
    branch_id SMALLINT NOT NULL, scheduled_at TIMESTAMPTZ NOT NULL, status VARCHAR(12) NOT NULL
);
CREATE INDEX ON appointment_p1 (patient_id, scheduled_at DESC);

-- ---- coordinator
\connect "port=5432 dbname=carebridge_dist host=localhost"
CREATE EXTENSION postgres_fdw;
CREATE SERVER shard_a FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5441', dbname 'postgres', fetch_size '10000', use_remote_estimate 'true');
CREATE SERVER shard_b FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5442', dbname 'postgres', fetch_size '10000', use_remote_estimate 'true');
CREATE USER MAPPING FOR postgres SERVER shard_a OPTIONS (user 'postgres');
CREATE USER MAPPING FOR postgres SERVER shard_b OPTIONS (user 'postgres');

CREATE TABLE appointment (
    appointment_id BIGINT NOT NULL, patient_id INT NOT NULL, doctor_id INT NOT NULL,
    branch_id SMALLINT NOT NULL, scheduled_at TIMESTAMPTZ NOT NULL, status VARCHAR(12) NOT NULL
) PARTITION BY HASH (patient_id);

CREATE FOREIGN TABLE appointment_s0 PARTITION OF appointment
    FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard_a OPTIONS (table_name 'appointment_p0');
CREATE FOREIGN TABLE appointment_s1 PARTITION OF appointment
    FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard_b OPTIONS (table_name 'appointment_p1');

-- Small reference table replicated to the coordinator (a "reference table" in Citus terms)
CREATE TABLE branch (branch_id SMALLINT PRIMARY KEY, name TEXT);
INSERT INTO branch VALUES (1,'CareBridge Ikeja'),(2,'CareBridge Lekki'),(3,'CareBridge Yaba'),(4,'CareBridge Abeokuta');
