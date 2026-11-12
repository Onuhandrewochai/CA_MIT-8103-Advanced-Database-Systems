PORTFOLIO 4 - NOSQL AND ADVANCED DATA MODELS
============================================

Case study: CareBridge Clinics. Two NoSQL models, each applied where it
fits better than the relational design from Portfolio 1. The
relational database stays the SYSTEM OF RECORD; NoSQL serves specific
access patterns (polyglot persistence).

DOCUMENT model
    Product:   MongoDB API
    Used for:  Complete visit record ("encounter") read as one unit;
               flexible clinical fields
    Script:    document_store_mongodb.py
    Evidence:  output/document_store_output.txt,
               output/sample_*.json,
               output/explain_patient_history.json

KEY-VALUE model
    Product:   Redis 7
    Used for:  Cache, slot holds, live queues, real-time counters
    Script:    key_value_redis.py
    Evidence:  output/key_value_output.txt


========================================================================

1. DOCUMENT MODEL (MONGODB)
---------------------------

1.1 Why a document model for clinic encounters?

In Portfolio 1, one visit is spread across 8 TABLES (appointment,
doctor, department, branch, diagnosis, prescription + items, lab order
+ result, invoice + lines + payments). Rebuilding a patient's history
needs 7+ joins. But a visit is written once, almost never changed
after sign-off, and nearly always READ AS A WHOLE (a doctor opens a
past visit; a patient app shows visit summaries). That is the case
where embedding wins: DATA THAT IS ACCESSED TOGETHER IS STORED
TOGETHER.


1.2 Collection design

"encounters" - one document per visit
(sample: output/sample_encounter_document.json):

    {
      "_id": 25, "scheduled_at": "2024-01-01T07:00:00Z", "month": "2024-01",
      "branch": "CareBridge Ikeja", "reason": "...",
      "patient":  { "hospital_no": "CBC-...", "name": "...", "sex": "F", "dob": "..." },
      "doctor":   { "doctor_id": 25, "name": "Dr ...", "department": "..." },
      "diagnoses":    [ { "code": "B54", "description": "Unspecified malaria", "primary": true } ],
      "prescription": [ { "medication": "Artemether/Lumefantrine", "strength": "20/120mg", "quantity": 10, ... } ],
      "labs":         [ { "test": "MPS", "name": "Malaria parasite smear", "result": "Positive", "flag": "POSITIVE" } ],
      "invoice": { "invoice_id": 1, "status": "PAID", "lines": [...], "payments": [...] }
    }

"patients" - profile plus the last 5 visit summaries
(output/sample_patient_document.json).

Design decisions:

  a) Diagnoses, prescription items, labs, invoice EMBEDDED in the
     encounter
       Pattern: Embedding (1-to-few)
       Reason:  Always read with the visit; bounded size (avg 862
                bytes, max 1.2 KB).

  b) Patient & doctor COPIED as small sub-documents, not just IDs
       Pattern: Extended reference
       Reason:  History screen needs the doctor's name without a
                second lookup; these fields rarely change.

  c) Encounters are NOT embedded inside the patient document
       Pattern: Referencing (1-to-many, unbounded)
       Reason:  A frequent attender can have 80+ visits; an
                ever-growing array risks the 16 MB DOCUMENT LIMIT and
                makes every update rewrite a large document.

  d) Patient doc keeps only the LAST 5 visits
       Pattern: Subset pattern
       Reason:  Patient app's home screen in one read; full history
                is a query on encounters.

  e) month: "2025-06" stored at write time
       Pattern: Computed pattern
       Reason:  Monthly reports group on a ready-made key instead of
                computing date parts per document.

  f) vitals, immunisations_given added to a paediatric visit only
       Pattern: Polymorphic / flexible schema
       Reason:  No ALTER TABLE, no sparse NULL columns for
                specialty-specific data.


1.3 Implementation

  1. ETL FROM POSTGRESQL: one SQL statement uses json_build_object /
     json_agg to assemble each visit from the 8 relational tables;
     Python loads 30,000 ENCOUNTERS (a systematic 1-in-25 sample
     across 2024-2026) and 24,035 PATIENTS.

  2. INDEXES (mirror the relational access paths):
       - { "patient.hospital_no": 1, scheduled_at: -1 }
           patient history, newest first
       - { "diagnoses.code": 1, scheduled_at: 1 }
           MULTIKEY index (one entry per array element) for disease
           trends
       - { "labs.test": 1, "labs.flag": 1 }, { month: 1 }

  3. QUERIES (results from output/document_store_output.txt):
       - Patient history:
           find({"patient.hospital_no": ...}).sort({scheduled_at: -1})
           -> whole visits in ONE READ, NO JOINS.
       - Malaria per month (2025):
           $match -> $group on month -> 12 months,
           e.g. ('2025-01', 187) ... ('2025-12', 185).
       - Top medications:
           $unwind: "$prescription" -> $group -> $sort.
       - Positive malaria smears:
           $unwind: "$labs" -> $match -> 555 encounters.

  4. CORRECTNESS CROSS-CHECK: the malaria-by-month result was
     recomputed in PostgreSQL on the same sample -> MATCH. The two
     models give the same answer.


1.4 Trade-offs (what the document model costs)

  - DUPLICATION: the doctor's name lives in every encounter. If it
    changes, either accept that historical visits keep the old name
    (clinically reasonable: it's what was true at the visit) or run
    updateMany.

  - CROSS-DOCUMENT CONSISTENCY: stock deduction across many
    medication records - Portfolio 3's dispensing transaction - is a
    poor fit. MongoDB has multi-document ACID transactions (since
    4.0, on replica sets) but they are costlier than single-document
    atomic writes. STOCK, PAYMENTS AND BOOKINGS STAY IN POSTGRESQL.

  - AD-HOC ANALYTICS across entities (e.g. revenue per department per
    drug) are easier in SQL.


1.5 Environment note (honest disclosure)

MongoDB server binaries and Docker Hub were blocked in the environment
used to build the evidence, so the script was executed against
FERRETDB 1.24, an open-source server that implements the MongoDB wire
protocol (here on a SQLite backend). It reports MongoDB 7.0
compatibility. Consequences:

  - The code is standard pymongo and runs unchanged on MongoDB 6/7 or
    Atlas.

  - FerretDB 1.24 lacks $year and $elemMatch on sub-document fields,
    so the script uses the computed month field and an $unwind
    pipeline (both also valid on MongoDB). The idiomatic $elemMatch
    form is shown in a comment.

  - NO PERFORMANCE CLAIMS ARE MADE FOR THE DOCUMENT STORE. FerretDB's
    SQLite backend does not push filters into indexes (explain()
    shows "filterPushdown": false, SCAN encounters), so timings there
    say nothing about MongoDB. To produce index evidence, run the
    script against MongoDB and check explain("executionStats") for
    IXSCAN and totalDocsExamined approx. equal to nReturned.


========================================================================

2. KEY-VALUE MODEL (REDIS)
--------------------------

1. Front desk repeatedly opens the same patient summary
     Redis:          HASH + EXPIRE 600, CACHE-ASIDE; DEL on update
     Why not just
     PostgreSQL?:    Avoid repeating a 3-table aggregate on every
                     lookup
     Result:         median 1.04 ms (miss) -> 0.075 ms (hit),
                     approx. 14x faster

2. Hold a slot for 2 min while the patient confirms on WhatsApp
     Redis:          SET hold:doctor:57:<slot> desk NX EX 120;
                     owner-only release via Lua compare-and-delete
     Why not just
     PostgreSQL?:    A DB row lock can't outlive a transaction; a
                     "pending" row needs cleanup jobs
     Result:         10 concurrent receptionists -> EXACTLY 1 WINNER;
                     hold expires automatically

3. Waiting-room queue: "You are number 3"
     Redis:          ZADD (score = check-in time), ZRANK, ZPOPMIN
     Why not just
     PostgreSQL?:    O(log n) rank lookups; changes constantly;
                     worthless after today
     Result:         Queue order and positions correct after the
                     doctor calls the next patient

4. Live dashboard tiles (check-ins per branch today)
     Redis:          HINCRBY
     Why not just
     PostgreSQL?:    Thousands of tiny increments would contend for
                     the same rows
     Result:         16 threads x 250 increments -> EXACTLY 1,000 PER
                     BRANCH, no lost updates (single-threaded command
                     execution makes each increment atomic)

Note that (2) is a CONVENIENCE lock. The final guarantee against
double-booking is still the partial unique index in PostgreSQL
(Portfolio 1 / Portfolio 3 scenario 9). If Redis is lost, nothing
incorrect gets committed.


========================================================================

3. SUITABILITY SUMMARY - WHICH MODEL FOR WHICH CAREBRIDGE DATA?
---------------------------------------------------------------

Patients, bookings, stock, invoices, payments
    Best model:  RELATIONAL (PostgreSQL)
    Reason:      Strong constraints, multi-row ACID transactions,
                 ad-hoc SQL reporting

Completed visit records, patient-app history
    Best model:  DOCUMENT (MongoDB)
    Reason:      Read as one aggregate; flexible specialty fields;
                 no joins

Cache, holds, queues, counters
    Best model:  KEY-VALUE (Redis)
    Reason:      Sub-millisecond, TTL-based, ephemeral

Lab-instrument readings, vitals from bedside monitors
    Best model:  WIDE-COLUMN (Cassandra) - not implemented
    Reason:      Very high write rate, time-ordered partitions keyed by
                 (patient_id, day)

Referral networks, infection contact tracing
    Best model:  GRAPH (Neo4j) - not implemented
    Reason:      Variable-depth traversals ("who shared a ward with
                 this TB patient within 2 hops?") that are awkward as
                 recursive SQL


4. HOW TO RUN
-------------

  pip install pymongo redis psycopg2-binary
  export PGUSER=postgres PGHOST=localhost           # Portfolio 1-2 database must exist
  export MONGO_URL=mongodb://localhost:27017/       # MongoDB, Atlas, or FerretDB
  python document_store_mongodb.py
  python key_value_redis.py                         # needs redis-server on :6379
