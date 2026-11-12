MIT 8103 ADVANCED DATABASE SYSTEMS - PRACTICAL PORTFOLIO
========================================================

Student:    Fadaini Oluwaseun Michael
Programme:  Master of Information Technology
Session:    2026/2027, First Semester


CASE STUDY: CAREBRIDGE CLINICS
------------------------------

A simulated chain of four outpatient clinics (Ikeja, Lekki, Yaba,
Abeokuta) with an in-house pharmacy, diagnostic laboratory and billing.

Users:
    Front-desk officers, doctors, pharmacists, lab scientists,
    cashiers, management

Major data:
    Patients, doctors, branches, departments, appointments, ICD-10
    diagnoses, medications & stock, prescriptions, lab
    orders/results, invoices, payments

Key operations:
    - Register patient
    - Book appointment without double-booking
    - Diagnose
    - Prescribe & dispense (stock)
    - Lab results
    - Invoice & payment without over-payment
    - Patient history
    - Disease-trend & revenue reports

The same case study is used in all five portfolios.


REPOSITORY STRUCTURE
--------------------

    advanced-database-portfolio/
    |-- portfolio-1-database-design/           ERD, 3NF/BCNF schema (17 tables), constraints, normalisation
    |-- portfolio-2-query-optimisation/        5.2M-row dataset, 8 workload queries, EXPLAIN ANALYZE, indexes, MVs
    |-- portfolio-3-transactions-concurrency/  10 concurrent-session scenarios (commit, rollback, anomalies, fixes)
    |-- portfolio-4-nosql/                     MongoDB document model + Redis key-value model
    |-- portfolio-5-distributed-cloud/         streaming replication, sync/async, failover, hash sharding, cloud design
    |-- run_all_postgres.sh                    rebuilds the PostgreSQL database (Portfolios 1-2)
    |-- requirements.txt
    `-- README.md

Each folder has its own README explaining what was built, how it was
tested, and what the results mean.


HEADLINE RESULTS
----------------

1. Design
     17-table schema in 3NF/BCNF; partial unique index stops doctor
     double-booking; trigger blocks over-payment; 5 invalid inserts
     each rejected by the correct constraint.

2. Optimisation
     Selective lookups 240-1,480x FASTER with targeted composite /
     expression indexes; low-selectivity reports gained little from
     indexes (planner correctly kept seq scans) and were fixed with
     random_page_cost tuning (Q5: 3x) and materialised views
     (Q4, Q8: >13,000x).

3. Transactions
     Lost update (stock 80 instead of 74) reproduced and fixed two
     ways; write skew breaks an on-call rule under REPEATABLE READ and
     is prevented under SERIALIZABLE; deadlock detected; concurrent
     double-booking and double-payment both prevented.

4. NoSQL
     30,000 visits migrated from 8 relational tables into single
     MongoDB documents; malaria trend result MATCHES POSTGRESQL
     EXACTLY; Redis cache 14x faster than the DB, atomic slot holds,
     live queues, counters with no lost updates.

5. Distributed
     5-server topology; 200/200 stale reads on async replica vs 0/200
     with remote_apply; sync-standby outage blocks commits until
     quorum ANY 1 is used; crash failover with RPO = 0; 1M
     appointments hash-sharded on patient_id across two servers with
     pruning and aggregate pushdown shown in plans.


TECHNOLOGY
----------

  - PostgreSQL 16.15
  - Python 3 (psycopg2, pymongo, redis, matplotlib)
  - Redis 7.0
  - MongoDB wire protocol (executed on FerretDB 1.24, see Portfolio 4
    section 1.5)
  - Graphviz


REPRODUCE
---------

  pip install -r requirements.txt
  export PGUSER=postgres PGHOST=localhost
  ./run_all_postgres.sh                                          # Portfolio 1 + data
  cd portfolio-2-query-optimisation && ./run_benchmark.sh && cd ..
  psql -d carebridge -f portfolio-3-transactions-concurrency/01_procedures.sql
  python portfolio-3-transactions-concurrency/transactions_demo.py
  python portfolio-4-nosql/document_store_mongodb.py              # needs MongoDB on :27017
  python portfolio-4-nosql/key_value_redis.py                     # needs Redis on :6379
  # Portfolio 5: see portfolio-5-distributed-cloud/README.md (creates extra servers)


ACADEMIC INTEGRITY & AI USE
---------------------------

See the AI Use Declaration in the LMS documentation. All sources are
listed in each portfolio README.
