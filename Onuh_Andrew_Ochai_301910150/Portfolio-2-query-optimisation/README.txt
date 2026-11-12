PORTFOLIO 2 - QUERY PROCESSING AND OPTIMISATION
===============================================

Case study:  CareBridge Clinics (same schema as Portfolio 1).
Environment: PostgreSQL 16.15, default config except where stated,
             2 parallel workers.


1. DATASET
----------

01_generate_data.sql builds a deterministic synthetic dataset
(setseed(0.8103)) with ~5.2 MILLION ROWS / 858 MB:

  Table                            Rows
  -------------------------------  -------------------------------------
  appointment                      1,000,000 (Jan 2024 - Nov 2026)
  prescription                       517,111
  prescription_item                1,208,789
  lab_order / lab_result             318,469 each
  diagnosis / invoice / payment      794,844 each
  patient                            100,000

Visit frequency is deliberately skewed: 20% of visits come from 5,000
"frequent attenders" (chronic and antenatal patients), so the busiest
patient has 80 visits and the average is 10, as in a real clinic.

Output: data_generation_output.txt


BUGS FOUND AND FIXED DURING DEVELOPMENT (DATA VALIDATION MATTERS):

  1. My first generator packed 40 slots/day into each doctor's
     calendar, so all 1M appointments fell inside 7 months of 2023 and
     the 2025 queries returned 0 ROWS, which made the "optimised"
     timings look impossibly good. Checking the row count of every
     query (now saved in each plan file) caught it.

  2. Lab result_value and flag came from two independent random()
     calls, so some results read "Negative" but were flagged
     "POSITIVE". Spotted while inspecting a MongoDB document in
     Portfolio 4; fixed by drawing one random value per row.

  3. A power(random(), 1.6) skew gave patient #1 774 VISITS in 3 years
     (unrealistic); replaced with the frequent-attender mix above.

  4. Identity gaps: the rejected test inserts in Portfolio 1 consumed
     patient_id 1-2, so hard-coded 1 + n IDs broke FK checks. The
     generator now offsets from min(patient_id). Sequences are not
     gap-free, by design.


2. METHOD
---------

benchmark.py runs each of the eight workload queries in 02_queries.sql
with EXPLAIN (ANALYZE, BUFFERS): one warm-up run, then SEVEN TIMED
RUNS, MEDIAN REPORTED. It is run three times:

  1. Baseline - only the PK / UNIQUE indexes from Portfolio 1.

  2. + Indexes - 03_indexes.sql, each index chosen after reading the
     baseline plan.

  3. + Tuning / materialised views -
     04_tuning_and_materialised_views.sql, chosen after reading the
     stage-2 plans.

Every plan (text) and the first result rows are saved in plans/ as
Qn_baseline.txt, Qn_optimised.txt, Qn_tuned.txt.

Re-run everything with: ./run_benchmark.sh


3. RESULTS
----------

See the chart image: performance_chart.png

Timings are medians in milliseconds.

  Query                                    Baseline  +Indexes  +Tuning/MV  Speed-up        Buffers
                                               (ms)      (ms)        (ms)                  baseline -> final
  ---------------------------------------  --------  --------  ----------  --------------  -----------------
  Q1 Patient history by hospital no.          68.60      0.30        0.28  242x            11,909 -> 448
  Q2 Doctor's day sheet                       35.52      0.02        0.02  1,480x          11,432 -> 35
  Q3 Same as Q2 but non-sargable              34.39      6.97      12.40*  3-5x            11,465 -> 8,368
     date(col) = ...
  Q4 Malaria cases / month (2025)            133.61    111.30        0.01  14,846x (MV)    15,734 -> 3
  Q5 Top medications, last month             130.42    123.61       45.68  3x              14,094 -> 62,447
  Q6 Patient surname-prefix search            28.66      1.74        1.74  16x             1,566 -> 1,573
  Q7 Invoice balance (view)                   26.93      0.02        0.02  1,347x          7,437 -> 12
  Q8 Branch revenue / month (2025)           551.77    527.16        0.04  13,458x (MV)    24,816 -> 2

  * Q3's stage-3 median is measurement noise: the plan and the buffer
    count (8,368) are identical to stage 2, and the single-run
    EXPLAIN ANALYZE saved in plans/Q3_tuned.txt shows 5.5 ms. Medians
    of 7 runs still vary on a shared machine, so read sub-10 ms
    differences cautiously.

Raw numbers: results.csv, results.md, timings_*.json


4. ANALYSIS
-----------

4.1 Selective OLTP lookups (Q1, Q2, Q7) - indexes are the answer

Q2 baseline (from plans/Q2_baseline.txt):

    Parallel Seq Scan on appointment a  (actual time=19.929..30.302 rows=3 loops=3)
      Filter: (scheduled_at >= '2025-06-10' AND scheduled_at < '2025-06-11' AND doctor_id = 57)
      Rows Removed by Filter: 333331
    Execution Time: 36.651 ms

Reading 1,000,000 rows to return 8. After
CREATE INDEX idx_appt_doctor_time ON appointment (doctor_id, scheduled_at):

    Index Scan using idx_appt_doctor_time on appointment a  (actual time=0.002..0.004 rows=8 loops=1)
      Index Cond: ((doctor_id = 57) AND (scheduled_at >= ...) AND (scheduled_at < ...))
    Execution Time: 0.017 ms

COLUMN ORDER MATTERS: equality column (doctor_id) first, range column
(scheduled_at) second, so the B-tree descends straight to doctor 57
and walks only that day's leaf entries.

Why didn't the Portfolio 1 partial unique index
(doctor_id, scheduled_at) WHERE status <> 'CANCELLED' help? The query
has no status predicate, so the planner can't prove the partial index
contains every row it needs. A partial index is only usable when the
query's WHERE clause implies the index predicate.

Q7 shows that FOREIGN KEYS ARE NOT AUTOMATICALLY INDEXED IN
POSTGRESQL: the invoice_balance view sums payment by invoice_id, and
without idx_payment_invoice that is a full scan of 794k payments for
one invoice. The same index also speeds up the over-payment trigger
from Portfolio 1.


4.2 Sargability (Q3 vs Q2)

Q3 asks the same question as Q2 but writes
date(scheduled_at AT TIME ZONE 'Africa/Lagos') = '2025-06-10'.
Wrapping the column in a function hides it from the index:

    Recheck Cond: (doctor_id = 57)
    Filter: (date((scheduled_at AT TIME ZONE 'Africa/Lagos')) = '2025-06-10')
    Rows Removed by Filter: 8325

Only the doctor_id prefix is usable, so all 8,333 of that doctor's
appointments are fetched and filtered: ~6-7 MS VS 0.02 MS for the
half-open range in Q2 (approx. 350x slower). Fix: rewrite as a range
(preferred), or build an expression index on the exact expression.


4.3 Expression index (Q6)

WHERE lower(last_name) LIKE 'okonk%' can't use a plain index on
last_name. idx_patient_name_search ON patient
(lower(last_name) text_pattern_ops, lower(first_name)) matches the
expression exactly; text_pattern_ops makes LIKE 'prefix%' indexable
whatever the database collation. 16x faster. Buffers stay ~1,570
because the ~1,700 matching patients are physically scattered across
almost every heap page; the gain comes from not evaluating lower() on
100,000 rows.


4.4 Low-selectivity analytics (Q4, Q5, Q8) - indexes are NOT the answer

After stage 2 these were still slow (111 ms, 124 ms, 527 ms). The
plans show why: malaria (B54) is ~20% of all diagnoses, and a full
year is ~35% of all appointments. Fetching that many rows through an
index costs more random I/O than a sequential scan, so the planner
CORRECTLY kept Parallel Seq Scan + Hash Join. Stage 3 used two
different tools:

  - COST-MODEL TUNING (Q5): random_page_cost defaults to 4.0, which
    models spinning disks. On SSD storage (and with the data cached)
    random reads cost almost the same as sequential reads, so it was
    set to 1.1. The planner then switched Q5 from a seq scan of 1.2M
    prescription_item rows to a nested loop over the 15.5k
    prescriptions in range using the PK index: 124 -> 46 ms. Buffer
    hits went UP (62k) because the nested loop revisits the same
    cached index pages, yet time went down. Buffer count is not the
    same as cost when pages are in memory.

  - MATERIALISED VIEWS (Q4, Q8): pre-aggregated mv_monthly_diagnosis
    and mv_branch_monthly_revenue reduce each report to reading a few
    dozen rows (0.01-0.04 ms). Each has a unique index so it can be
    REFRESH ... CONCURRENTLY without blocking readers.

    TRADE-OFF: results are only as fresh as the last refresh. That
    suits monthly management reports. It is NOT used for Q7 (cashier
    balance), which must be exact, so Q7 stays a normal view backed by
    an index.


4.5 Cost of indexing

The ten secondary indexes add ~138 MB (largest: idx_appt_doctor_time
and idx_appt_patient_time, 30 MB each), and every INSERT into
appointment now updates five B-trees. idx_rx_item_medication (8 MB)
wasn't used by any query in this workload, so it is a candidate to
drop. pg_stat_user_indexes.idx_scan = 0 over a representative period
is the evidence to look for before removing it.


5. HOW TO REPRODUCE
-------------------

  pip install psycopg2-binary matplotlib
  export PGUSER=postgres PGHOST=localhost
  ./run_benchmark.sh        # rebuilds DB, runs all three stages, writes results + chart

Timings will differ on other hardware; the RELATIVE improvements and
the plan shapes should be the same.
