/*
================================================================================
 Portfolio 4a - Document model in PostgreSQL (JSONB) for CareBridge Clinics
================================================================================
 PostgreSQL version of document_store_mongodb.py.

 1. ETL: reshapes 30,000 completed visits (appointment + doctor + diagnoses +
    prescription + lab results + invoice + payments: 8 tables) into ONE JSONB
    "encounter" document per visit - done entirely in SQL, no Python.
 2. Builds a "patients" collection using the subset pattern (last 5 visits).
 3. Creates indexes, runs the same business questions as Portfolio 2, and
    saves EXPLAIN output.

 MongoDB  -> PostgreSQL equivalents used here
   collection                -> table with a single JSONB column (id, doc)
   multikey index on array   -> GIN index (jsonb_path_ops) on the array
   $elemMatch                -> containment operator @>  e.g. labs @> '[{"test":"MPS","flag":"POSITIVE"}]'
   $unwind                   -> jsonb_array_elements()
   $group / $sort / $limit   -> GROUP BY / ORDER BY / LIMIT
   $set on one document      -> doc = doc || '{...}'::jsonb
   explain()                 -> EXPLAIN (ANALYZE, BUFFERS)

 Usage (run from the folder that should receive output/):
   mkdir -p output
   psql -d carebridge -f document_store.sql | tee output/document_store_output.txt

 Requires the Portfolio 1-2 database (schema "clinic").
================================================================================
*/
\set ON_ERROR_STOP on
\pset pager off
\set n_visits 30000

SET search_path TO clinic, public;
SET TIME ZONE 'UTC';            -- documents store timestamps as ISO-8601 UTC strings

\! mkdir -p output

-- ----------------------------------------------------------------------------
-- 0. "Collections": one JSONB document per row
-- ----------------------------------------------------------------------------
DROP SCHEMA IF EXISTS docstore CASCADE;
CREATE SCHEMA docstore;

CREATE TABLE docstore.encounters (
    id   bigint PRIMARY KEY,             -- keep the relational key (appointment_id) for traceability
    doc  jsonb  NOT NULL
);

CREATE TABLE docstore.patients (
    id   text   PRIMARY KEY,             -- hospital_no
    doc  jsonb  NOT NULL
);

-- ----------------------------------------------------------------------------
-- 1. EXTRACT + TRANSFORM + LOAD in one statement
--    Timestamps are written as fixed-format UTC strings ("2024-01-01T07:00:00Z")
--    so they sort and range-compare correctly as text, exactly like ISO dates in
--    a document store.
-- ----------------------------------------------------------------------------
\echo
\echo '=== 1. ETL: 8 relational tables -> 1 encounter document per visit'
\timing on
INSERT INTO docstore.encounters (id, doc)
WITH v AS (
    SELECT a.* FROM appointment a
    WHERE a.status = 'COMPLETED' AND a.appointment_id % 25 = 0     -- systematic 1-in-25 sample across 2024-2026
    ORDER BY a.appointment_id
    LIMIT :n_visits
)
SELECT
  v.appointment_id,
  jsonb_build_object(
    'scheduled_at', to_char(v.scheduled_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'month',        to_char(v.scheduled_at, 'YYYY-MM'),               -- computed pattern: pre-derived reporting key
    'branch',       b.name,
    'reason',       v.reason,
    'patient',      jsonb_build_object(                                -- extended-reference pattern
                        'hospital_no', p.hospital_no,
                        'name',        p.first_name || ' ' || p.last_name,
                        'sex',         p.sex,
                        'dob',         p.date_of_birth),
    'doctor',       jsonb_build_object(
                        'doctor_id',   d.doctor_id,
                        'name',        'Dr ' || d.first_name || ' ' || d.last_name,
                        'department',  dep.name),
    'diagnoses',    COALESCE((
        SELECT jsonb_agg(jsonb_build_object('code', dg.icd10_code, 'description', ic.description,
                                            'primary', dg.is_primary) ORDER BY dg.is_primary DESC, dg.icd10_code)
          FROM diagnosis dg JOIN icd10_code ic ON ic.code = dg.icd10_code
         WHERE dg.appointment_id = v.appointment_id), '[]'::jsonb),
    'prescription', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('medication', m.name, 'strength', m.strength, 'form', m.form,
                                            'dosage', pi.dosage, 'frequency', pi.frequency,
                                            'days', pi.duration_days, 'quantity', pi.quantity))
          FROM prescription pr
          JOIN prescription_item pi USING (prescription_id)
          JOIN medication m USING (medication_id)
         WHERE pr.appointment_id = v.appointment_id), '[]'::jsonb),
    'labs',         COALESCE((
        SELECT jsonb_agg(jsonb_build_object('test', lt.test_code, 'name', lt.name,
                                            'result', lr.result_value, 'flag', lr.flag))
          FROM lab_order lo
          JOIN lab_test lt USING (test_code)
          LEFT JOIN lab_result lr USING (lab_order_id)
         WHERE lo.appointment_id = v.appointment_id), '[]'::jsonb),
    'invoice',      (
        SELECT jsonb_build_object(
                 'invoice_id', i.invoice_id,
                 'status',     i.status,
                 'lines',      COALESCE((SELECT jsonb_agg(jsonb_build_object('description', il.description, 'amount', il.amount) ORDER BY il.line_no)
                                           FROM invoice_line il WHERE il.invoice_id = i.invoice_id), '[]'::jsonb),
                 'payments',   COALESCE((SELECT jsonb_agg(jsonb_build_object('amount', pm.amount, 'method', pm.method,
                                                                             'paid_at', to_char(pm.paid_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) ORDER BY pm.paid_at)
                                           FROM payment pm WHERE pm.invoice_id = i.invoice_id), '[]'::jsonb))
          FROM invoice i WHERE i.appointment_id = v.appointment_id)
  )
FROM v
JOIN patient p      ON p.patient_id      = v.patient_id
JOIN doctor d       ON d.doctor_id       = v.doctor_id
JOIN department dep ON dep.department_id = d.department_id
JOIN branch b       ON b.branch_id       = v.branch_id;
\timing off

SELECT to_char(count(*), 'FM999,999') AS encounter_documents_loaded FROM docstore.encounters;

-- ----------------------------------------------------------------------------
-- 2. patients "collection" - subset pattern: profile + last 5 visit summaries
-- ----------------------------------------------------------------------------
\echo
\echo '=== 2. patients collection (subset pattern: last 5 visits embedded)'
INSERT INTO docstore.patients (id, doc)
SELECT hospital_no,
       ((array_agg(patient))[1] - 'hospital_no')
       || jsonb_build_object(
            'visit_count',   count(*),
            'recent_visits', jsonb_agg(summary ORDER BY scheduled_at) FILTER (WHERE rn <= 5))
FROM (
    SELECT e.doc->'patient'->>'hospital_no' AS hospital_no,
           e.doc->'patient'                 AS patient,
           e.doc->>'scheduled_at'           AS scheduled_at,
           jsonb_build_object(
               'encounter_id', e.id,
               'date',         e.doc->>'scheduled_at',
               'doctor',       e.doc->'doctor'->>'name',
               'diagnoses',    (SELECT COALESCE(jsonb_agg(dx->'code'), '[]'::jsonb)
                                  FROM jsonb_array_elements(e.doc->'diagnoses') dx)) AS summary,
           row_number() OVER (PARTITION BY e.doc->'patient'->>'hospital_no'
                              ORDER BY e.doc->>'scheduled_at' DESC)              AS rn
    FROM docstore.encounters e
) s
GROUP BY hospital_no;

SELECT to_char(count(*), 'FM999,999') AS patient_documents_loaded FROM docstore.patients;

-- Sample documents written to output/
-- prefer a visit that has both labs and a prescription (falls back to the richest one available)
SELECT id AS sample_id
FROM docstore.encounters
ORDER BY (jsonb_array_length(doc->'labs') > 0)::int
       + (jsonb_array_length(doc->'prescription') > 0)::int DESC,
         id
LIMIT 1 \gset

\pset tuples_only on
\pset format unaligned
\o output/sample_encounter_document.json
SELECT jsonb_pretty(jsonb_build_object('_id', id) || doc) FROM docstore.encounters WHERE id = :sample_id;
\o output/sample_patient_document.json
SELECT jsonb_pretty(jsonb_build_object('_id', id) || doc)
FROM docstore.patients WHERE (doc->>'visit_count')::int >= 3 ORDER BY id LIMIT 1;
\o
\pset format aligned
\pset tuples_only off
\echo 'Sample documents written to output/sample_*.json'

-- ----------------------------------------------------------------------------
-- 3. INDEXES (mirroring the relational access paths)
-- ----------------------------------------------------------------------------
\echo
\echo '=== 3. Indexes'
-- patient history, newest first  (MongoDB: { "patient.hospital_no": 1, scheduled_at: -1 })
CREATE INDEX ix_patient_time ON docstore.encounters
    ((doc->'patient'->>'hospital_no'), (doc->>'scheduled_at') DESC);

-- diagnosis codes inside an array (MongoDB multikey index -> PostgreSQL GIN)
CREATE INDEX ix_dx ON docstore.encounters USING gin ((doc->'diagnoses') jsonb_path_ops);

-- lab test + flag inside an array (GIN containment gives $elemMatch semantics)
CREATE INDEX ix_labs ON docstore.encounters USING gin ((doc->'labs') jsonb_path_ops);

-- monthly reporting key
CREATE INDEX ix_month ON docstore.encounters ((doc->>'month'));

ANALYZE docstore.encounters;
ANALYZE docstore.patients;

SELECT indexname FROM pg_indexes WHERE schemaname = 'docstore' AND tablename = 'encounters' ORDER BY indexname;

-- patient with the longest history
SELECT id AS hosp_no FROM docstore.patients
ORDER BY (doc->>'visit_count')::int DESC, id LIMIT 1 \gset

-- ----------------------------------------------------------------------------
-- 4. QUERIES - the same business questions as Portfolio 2
-- ----------------------------------------------------------------------------
\timing on

\echo
\echo '=== Q1: patient history -> whole visits from ONE table read, no joins'
\echo 'patient:' :hosp_no
SELECT left(doc->>'scheduled_at', 10)                                  AS date,
       doc->'doctor'->>'name'                                          AS doctor,
       doc->'doctor'->>'department'                                    AS department,
       doc->>'branch'                                                  AS branch,
       jsonb_path_query_array(doc, '$.diagnoses[*].code')              AS dx,
       jsonb_path_query_array(doc, '$.prescription[*].medication')     AS rx,
       jsonb_path_query_array(doc, '$.labs[*] ? (@.flag != null) .flag') AS lab_flags
FROM docstore.encounters
WHERE doc->'patient'->>'hospital_no' = :'hosp_no'
ORDER BY doc->>'scheduled_at' DESC
LIMIT 20;

\echo
\echo '=== Q2: malaria (B54) cases by month, 2025 (sample)'
SELECT doc->>'month' AS month, count(*) AS cases
FROM docstore.encounters
WHERE doc->'diagnoses' @> '[{"code": "B54"}]'
  AND doc->>'scheduled_at' >= '2025-01-01T00:00:00Z'
  AND doc->>'scheduled_at' <  '2026-01-01T00:00:00Z'
GROUP BY 1
ORDER BY 1;

\echo
\echo '=== Q3: top medications by units (sample)  [$unwind -> jsonb_array_elements]'
SELECT item->>'medication'               AS medication,
       sum((item->>'quantity')::int)     AS units,
       count(*)                          AS scripts
FROM docstore.encounters e,
     jsonb_array_elements(e.doc->'prescription') AS item
GROUP BY 1
ORDER BY units DESC
LIMIT 5;

\echo
\echo '=== Q4: encounters with a POSITIVE malaria smear (sample)  [$elemMatch -> @>]'
-- @> matches when ONE array element has BOTH test = MPS and flag = POSITIVE,
-- which is exactly MongoDB's $elemMatch behaviour - and it can use the GIN index.
SELECT count(*) AS encounters
FROM docstore.encounters
WHERE doc->'labs' @> '[{"test": "MPS", "flag": "POSITIVE"}]';

\timing off

-- ----------------------------------------------------------------------------
-- 5. Cross-check: the document model must give the same answer as the relational one
-- ----------------------------------------------------------------------------
\echo
\echo '=== Cross-check vs relational tables for Q2'
WITH doc_result AS (
    SELECT doc->>'month' AS month, count(*) AS cases
    FROM docstore.encounters
    WHERE doc->'diagnoses' @> '[{"code": "B54"}]'
      AND doc->>'scheduled_at' >= '2025-01-01T00:00:00Z'
      AND doc->>'scheduled_at' <  '2026-01-01T00:00:00Z'
    GROUP BY 1
),
rel_result AS (
    SELECT to_char(a.scheduled_at, 'YYYY-MM') AS month, count(*) AS cases
    FROM appointment a JOIN diagnosis d USING (appointment_id)
    WHERE a.status = 'COMPLETED' AND a.appointment_id % 25 = 0 AND d.icd10_code = 'B54'
      AND a.scheduled_at >= '2025-01-01' AND a.scheduled_at < '2026-01-01'
      AND a.appointment_id IN (SELECT id FROM docstore.encounters)      -- same sample as the documents
    GROUP BY 1
)
SELECT CASE WHEN NOT EXISTS (SELECT * FROM doc_result EXCEPT SELECT * FROM rel_result)
             AND NOT EXISTS (SELECT * FROM rel_result EXCEPT SELECT * FROM doc_result)
            THEN 'MATCH' ELSE 'DIFFERENT' END AS cross_check;

-- ----------------------------------------------------------------------------
-- 6. EXPLAIN evidence (real PostgreSQL, so index use is genuine evidence)
-- ----------------------------------------------------------------------------
\o output/explain_patient_history.txt
EXPLAIN (ANALYZE, BUFFERS)
SELECT doc FROM docstore.encounters
WHERE doc->'patient'->>'hospital_no' = :'hosp_no'
ORDER BY doc->>'scheduled_at' DESC
LIMIT 20;
\o output/explain_positive_malaria.txt
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM docstore.encounters
WHERE doc->'labs' @> '[{"test": "MPS", "flag": "POSITIVE"}]';
\o
\echo
\echo 'EXPLAIN output saved to output/explain_patient_history.txt and output/explain_positive_malaria.txt'

-- ----------------------------------------------------------------------------
-- 7. Schema flexibility: a paediatrics visit carries fields other visits don't need
-- ----------------------------------------------------------------------------
\echo
\echo '=== Schema flexibility: add vitals + immunisations to ONE encounter, no ALTER TABLE'
UPDATE docstore.encounters
SET doc = doc || '{"vitals": {"weight_kg": 14.2, "temp_c": 38.6, "muac_cm": 14.5},
                   "immunisations_given": ["Measles 2", "Vitamin A"]}'::jsonb
WHERE id = :sample_id;

SELECT id, doc->'vitals' AS vitals, doc->'immunisations_given' AS immunisations_given
FROM docstore.encounters WHERE id = :sample_id;

SELECT count(*) FILTER (WHERE doc ? 'vitals')        AS docs_with_vitals,
       count(*) FILTER (WHERE NOT doc ? 'vitals')    AS docs_without_vitals
FROM docstore.encounters;

-- ----------------------------------------------------------------------------
-- 8. Document size check
--    PostgreSQL limits one JSONB value to ~255 MB, but large documents are TOASTed
--    and every update rewrites the whole value - the same reason visits are NOT
--    embedded inside the patient document.
-- ----------------------------------------------------------------------------
\echo
\echo '=== Encounter document size (first 2,000 documents)'
SELECT round(avg(octet_length(doc::text)))  AS avg_bytes_as_json,
       max(octet_length(doc::text))         AS max_bytes_as_json,
       round(avg(pg_column_size(doc)))      AS avg_bytes_stored_jsonb
FROM (SELECT doc FROM docstore.encounters ORDER BY id LIMIT 2000) s;

SELECT pg_size_pretty(pg_total_relation_size('docstore.encounters')) AS encounters_table_plus_indexes;
