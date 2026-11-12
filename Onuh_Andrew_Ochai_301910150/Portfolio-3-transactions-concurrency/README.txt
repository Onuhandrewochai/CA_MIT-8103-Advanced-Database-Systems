PORTFOLIO 3 - TRANSACTIONS AND CONCURRENCY
==========================================

Case study: CareBridge Clinics. Concurrency problems in a clinic are
not academic: two pharmacists dispensing from the same stock, two
receptionists booking the same doctor, two cashiers taking the same
bill.


FILES
-----

01_procedures.sql
    dispense_prescription() - all-or-nothing dispensing; locks drug
    rows in a fixed order.

transactions_demo.py
    Runs 10 scenarios using 2-3 REAL CONCURRENT POSTGRESQL SESSIONS.
    Blocking statements run in a thread so a MONITOR session can
    observe the lock wait in pg_stat_activity.

output/transactions_log.txt
    Full timestamped log of one run (evidence).

Run:
    psql -d carebridge -f 01_procedures.sql && python transactions_demo.py

or, for one scenario:
    python transactions_demo.py 7


HOW POSTGRESQL HANDLES CONCURRENCY (BACKGROUND)
-----------------------------------------------

PostgreSQL uses MVCC (MULTI-VERSION CONCURRENCY CONTROL): an UPDATE
writes a new row version, and each transaction reads from a SNAPSHOT,
so READERS NEVER BLOCK WRITERS AND WRITERS NEVER BLOCK READERS.
Writers on the SAME ROW do block each other. The second writer waits
on the first's transaction ID (wait_event = transactionid in the log).
What happens after the wait depends on the isolation level:

READ COMMITTED (default)
    Snapshot taken:   per STATEMENT
    After waiting:    re-reads the new row version and carries on

REPEATABLE READ
    Snapshot taken:   once per TRANSACTION
    After waiting:    aborts with
                      40001 could not serialize access due to
                      concurrent update

SERIALIZABLE (SSI)
    Snapshot taken:   once per transaction + tracks read/write
                      dependencies
    After waiting:    as REPEATABLE READ, PLUS aborts dangerous
                      read-write cycles (write skew)


SCENARIOS AND RESULTS
---------------------

1.  Dispense a 2-drug prescription
    Concept:  COMMIT, atomicity
    Result:   Stock 100 -> 94 and 100 -> 80, two audit rows and
              dispensed_at all committed together.

2.  Dispense when 2nd drug has too little stock
    Concept:  ROLLBACK, atomicity, consistency (CHECK)
    Result:   23514 check constraint -> ROLLBACK; drug 1 stock still
              100, 0 audit rows, not marked dispensed.

3.  Register patient, try a taken slot, book next slot
    Concept:  SAVEPOINT (partial rollback)
    Result:   23505 uq_doctor_active_slot -> ROLLBACK TO SAVEPOINT;
              patient kept, next slot booked, 1 commit.

4.  Two pharmacists read stock then write stock = value
    Concept:  LOST UPDATE anomaly
    Result:   Final stock 80, should be 74: one dispensing silently
              vanished.

4b. Same, with SELECT ... FOR UPDATE
    Concept:  Pessimistic row locking
    Result:   T2 BLOCKS (monitor shows it waiting) until T1 commits,
              then reads 94 -> final 74 (correct).

4c. Same, with SET stock = stock - n
    Concept:  Atomic in-place update
    Result:   T2 waits, re-reads under READ COMMITTED -> 74 (correct;
              simplest fix).

5.  Read stock twice while another session updates it
    Concept:  NON-REPEATABLE READ
    Result:   READ COMMITTED: 100 then 40;
              REPEATABLE READ: 100 then 100 (stable snapshot).

6.  Both at REPEATABLE READ update same drug
    Concept:  First-updater-wins
    Result:   T2 gets 40001 ... concurrent update, rolls back,
              RETRIES -> 74 (correct).

7.  Two on-call doctors at one branch both sign off
    (rule: at least 1 must stay on call)
    Concept:  WRITE SKEW
    Result:   REPEATABLE READ: both commit -> 0 ON CALL (INVARIANT
              BROKEN).
              SERIALIZABLE: T2 gets 40001 ... read/write dependencies
              -> 1 on call (correct).

8.  Two pharmacists lock drugs 1,2 and 2,1
    Concept:  DEADLOCK
    Result:   Detector fires after deadlock_timeout (500 ms):
              T1 40P01 deadlock detected, T2 commits.

9.  Two receptionists book same doctor & slot concurrently
    Concept:  Unique index as a concurrency control
    Result:   T2 WAITS on T1's uncommitted row, then 23505 -> exactly
              1 booking.

10. Two cashiers each take the full NGN 12,500
    Concept:  Trigger + FOR UPDATE
    Result:   T2 blocked, then "Over-payment ... already paid 12500"
              -> balance 0, status PAID, no double charge.


KEY LOG EXCERPT - WRITE SKEW (SCENARIO 7)

    --- both transactions at REPEATABLE READ
    [T1] SELECT count(*) ... on_call  -> [(2,)]      [T2] SELECT count(*) ... on_call -> [(2,)]
    [T1] UPDATE doctor SET on_call = FALSE WHERE doctor_id = 3
    [T2] UPDATE doctor SET on_call = FALSE WHERE doctor_id = 7
    [T1] COMMIT   [T2] COMMIT
    [CHECK] doctors on call at branch 4 = 0 -> INVARIANT BROKEN (write skew)
    --- both transactions at SERIALIZABLE
    ...
    [T1] COMMIT
    [T2] ERROR 40001 could not serialize access due to read/write dependencies among transactions
    [CHECK] doctors on call at branch 4 = 1 -> invariant holds

Why REPEATABLE READ can't catch this: the two transactions update
DIFFERENT ROWS, so there is no write-write conflict. Each made a
decision based on a read that the other one invalidated. Only
SERIALIZABLE's dependency tracking (Serializable Snapshot Isolation)
detects the cycle.


DESIGN DECISIONS THIS PORTFOLIO LED TO
--------------------------------------

  1. STOCK DEDUCTION USES stock_qty = stock_qty - n, never
     read-then-write in application code (scenario 4c). The
     CHECK (stock_qty >= 0) makes overselling impossible even under
     concurrency.

  2. FIXED LOCK ORDERING in dispense_prescription()
     (ORDER BY medication_id) prevents the deadlock in scenario 8.
     Two prescriptions sharing drugs always lock them in the same
     order.

  3. DOUBLE-BOOKING IS PREVENTED DECLARATIVELY by the partial unique
     index from Portfolio 1 (scenario 9). This is safer than "SELECT
     to check, then INSERT", which has a race window under any
     isolation below SERIALIZABLE.

  4. PAYMENTS lock the parent invoice row inside the trigger
     (scenario 10), serialising cashiers per invoice only, not
     globally.

  5. RULES SPANNING SEVERAL ROWS (on-call coverage) run at
     SERIALIZABLE with a retry loop on SQLSTATE 40001. Retrying is
     required: an SSI abort is normal behaviour, not a bug.

  6. DEFAULT STAYS READ COMMITTED for ordinary OLTP. It is cheapest,
     and the patterns above make it safe for the hot paths.


EVIDENCE
--------

  - Full log: output/transactions_log.txt (160 lines, one complete
    run).

  - Every blocking case includes a [MONITOR] line taken from
    pg_stat_activity while the second session was actually waiting
    (Lock/transactionid).

  - Run it yourself and screenshot your terminal for the LMS
    submission.
