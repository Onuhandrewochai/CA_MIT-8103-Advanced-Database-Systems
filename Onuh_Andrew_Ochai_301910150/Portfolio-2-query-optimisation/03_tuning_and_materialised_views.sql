-- =====================================================================
-- Portfolio 2 — optimisation iteration 2 (after reading the plans from iteration 1)
-- Finding: Q4, Q5 and Q8 are LOW-SELECTIVITY analytical queries. Indexes alone barely helped
-- (or the planner correctly ignored them) because they touch 20-35% of a large table.
-- =====================================================================


SET search_path TO clinic;

-- (1) Planner cost tuning. random_page_cost defaults to 4.0, which models spinning disks.
--     On SSD/NVMe (and when the working set is cached) random reads cost ~ the same as sequential,
--     so 1.1 is the commonly recommended value. Effect: Q5 switches from Seq Scan + Hash Join
--     on prescription_item (1.2M rows) to Nested Loop + PK index lookups.
ALTER DATABASE carebridge SET random_page_cost = 1.1;

-- (2) Pre-aggregation for the dashboard queries (refreshed nightly / after bulk loads).
CREATE MATERIALIZED VIEW mv_monthly_diagnosis AS
SELECT dg.icd10_code, date_trunc('month', a.scheduled_at) AS month, count(*) AS cases
FROM diagnosis dg
JOIN appointment a ON a.appointment_id = dg.appointment_id
GROUP BY dg.icd10_code, 2;
CREATE UNIQUE INDEX ON mv_monthly_diagnosis (icd10_code, month);

CREATE MATERIALIZED VIEW mv_branch_monthly_revenue AS
SELECT a.branch_id, date_trunc('month', pay.paid_at) AS month, sum(pay.amount) AS revenue, count(*) AS payments
FROM payment pay
JOIN invoice i     ON i.invoice_id = pay.invoice_id
JOIN appointment a ON a.appointment_id = i.appointment_id
GROUP BY a.branch_id, 2;
CREATE UNIQUE INDEX ON mv_branch_monthly_revenue (branch_id, month);   -- needed for REFRESH ... CONCURRENTLY

-- Refresh without blocking readers (schedule with cron / pg_cron):
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_diagnosis;
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_branch_monthly_revenue;
-- Trade-off: results are as fresh as the last refresh (acceptable for monthly management reports,
-- NOT acceptable for the cashier balance in Q7, which therefore stays a normal view).

ANALYZE;
