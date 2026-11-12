=====================================================================
-- Portfolio 2 — workload queries (one per key clinic operation)
-- Literal values are realistic constants so plans are reproducible.=====================================================================




SET search_path TO clinic;


-- name: Q1 Patient history (front desk / doctor opens a folder by hospital number)
SELECT a.appointment_id, a.scheduled_at, a.status,
       d.first_name || ' ' || d.last_name AS doctor,
       dg.icd10_code, ic.description
FROM patient p
JOIN appointment a      ON a.patient_id = p.patient_id
JOIN doctor d           ON d.doctor_id  = a.doctor_id
LEFT JOIN diagnosis dg  ON dg.appointment_id = a.appointment_id
LEFT JOIN icd10_code ic ON ic.code = dg.icd10_code
WHERE p.hospital_no = 'CBC-0004321'
ORDER BY a.scheduled_at DESC
LIMIT 20;





-- name: Q2 Doctor day sheet (all of a doctor's appointments on one day)
SELECT a.appointment_id, a.scheduled_at, a.status, p.hospital_no, p.first_name, p.last_name
FROM appointment a
JOIN patient p ON p.patient_id = a.patient_id
WHERE a.doctor_id = 57
  AND a.scheduled_at >= TIMESTAMPTZ '2025-06-10 00:00'
  AND a.scheduled_at <  TIMESTAMPTZ '2025-06-11 00:00'
ORDER BY a.scheduled_at;




-- name: Q3 Non-sargable variant of Q2 (function wrapped around the indexed column)
SELECT a.appointment_id, a.scheduled_at, a.status
FROM appointment a
WHERE a.doctor_id = 57
  AND date(a.scheduled_at AT TIME ZONE 'Africa/Lagos') = DATE '2025-06-10'
ORDER BY a.scheduled_at;




-- name: Q4 Malaria cases per month in 2025 (public-health trend report)
SELECT date_trunc('month', a.scheduled_at) AS month, count(*) AS malaria_cases
FROM diagnosis dg
JOIN appointment a ON a.appointment_id = dg.appointment_id
WHERE dg.icd10_code = 'B54'
  AND a.scheduled_at >= TIMESTAMPTZ '2025-01-01'
  AND a.scheduled_at <  TIMESTAMPTZ '2026-01-01'
GROUP BY 1 ORDER BY 1;




-- name: Q5 Pharmacy: top medications dispensed in the last 30 days of data
SELECT m.name, m.strength, sum(pi.quantity) AS units, count(DISTINCT pr.prescription_id) AS scripts
FROM prescription pr
JOIN prescription_item pi ON pi.prescription_id = pr.prescription_id
JOIN medication m         ON m.medication_id    = pi.medication_id
WHERE pr.prescribed_at >= TIMESTAMPTZ '2026-10-01'
  AND pr.prescribed_at <  TIMESTAMPTZ '2026-11-01'
GROUP BY m.name, m.strength
ORDER BY units DESC LIMIT 10;





-- name: Q6 Patient search by surname prefix, case-insensitive (front desk search box)
SELECT patient_id, hospital_no, first_name, last_name, phone
FROM patient
WHERE lower(last_name) LIKE 'okonk%' AND lower(first_name) = 'lola'
ORDER BY last_name, first_name
LIMIT 25;




-- name: Q7 Outstanding balance for one invoice (cashier screen, uses the invoice_balance view)
SELECT * FROM invoice_balance WHERE invoice_id = 654321;

-- name: Q8 Branch revenue by month for 2025 (management report)
SELECT b.name AS branch, date_trunc('month', pay.paid_at) AS month, sum(pay.amount) AS revenue
FROM payment pay
JOIN invoice i     ON i.invoice_id = pay.invoice_id
JOIN appointment a ON a.appointment_id = i.appointment_id
JOIN branch b      ON b.branch_id = a.branch_id
WHERE pay.paid_at >= TIMESTAMPTZ '2025-01-01' AND pay.paid_at < TIMESTAMPTZ '2026-01-01'
GROUP BY b.name, 2
ORDER BY 1, 2;
