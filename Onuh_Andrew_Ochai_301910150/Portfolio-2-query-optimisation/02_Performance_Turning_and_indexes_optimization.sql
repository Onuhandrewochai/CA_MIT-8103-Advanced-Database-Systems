-- =====================================================================
-- Portfolio 2 — optimisation step: indexes chosen from the baseline plans
-- Each index is justified by the query that needs it (see README §3).
-- =====================================================================


SET search_path TO clinic;

-- Q1: patient → appointments, newest first. Composite so ORDER BY ... DESC LIMIT is served by the index.
CREATE INDEX idx_appt_patient_time   ON appointment (patient_id, scheduled_at DESC);

-- Q2/Q3: doctor + time range. The partial unique index from Portfolio 1 only covers non-cancelled rows,
-- so a query that also needs CANCELLED rows cannot use it — a full composite index is needed.
CREATE INDEX idx_appt_doctor_time    ON appointment (doctor_id, scheduled_at);


-- Q4: diagnosis PK is (appointment_id, icd10_code) — useless for "WHERE icd10_code = ?".
-- Leading with icd10_code and INCLUDE-ing appointment_id makes an index-only scan possible.
CREATE INDEX idx_diag_code           ON diagnosis (icd10_code) INCLUDE (appointment_id);
CREATE INDEX idx_appt_time           ON appointment (scheduled_at);


-- Q5: range filter on prescribed_at.
CREATE INDEX idx_rx_prescribed_at    ON prescription (prescribed_at);

-- Q6: expression index matching lower(...) exactly; text_pattern_ops enables LIKE 'prefix%'
-- regardless of the database collation.
CREATE INDEX idx_patient_name_search ON patient (lower(last_name) text_pattern_ops, lower(first_name));

-- Q7 (and the over-payment trigger): FK columns are not auto-indexed in PostgreSQL.
CREATE INDEX idx_payment_invoice     ON payment (invoice_id);

-- Other FK columns used in joins / cascades
CREATE INDEX idx_rx_appointment      ON prescription (appointment_id);
CREATE INDEX idx_lab_order_appt      ON lab_order (appointment_id);
CREATE INDEX idx_rx_item_medication  ON prescription_item (medication_id);

ANALYZE;
