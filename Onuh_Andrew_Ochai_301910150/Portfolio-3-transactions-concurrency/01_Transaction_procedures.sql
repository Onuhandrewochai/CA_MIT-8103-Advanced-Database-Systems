-- =====================================================================
-- Portfolio 3 — stored procedure used by the transaction demos
-- dispense_prescription(): all-or-nothing pharmacy dispensing
-- =====================================================================


SET search_path TO clinic;

CREATE OR REPLACE PROCEDURE dispense_prescription(p_prescription_id BIGINT)
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    IF EXISTS (SELECT 1 FROM prescription WHERE prescription_id = p_prescription_id AND dispensed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Prescription % already dispensed', p_prescription_id;
    END IF;

    -- Lock medication rows in a FIXED order (medication_id) to avoid deadlocks between pharmacists
    FOR r IN SELECT pi.medication_id, pi.quantity
             FROM prescription_item pi
             WHERE pi.prescription_id = p_prescription_id
             ORDER BY pi.medication_id
    LOOP
        UPDATE medication SET stock_qty = stock_qty - r.quantity      -- CHECK (stock_qty >= 0) aborts if insufficient
         WHERE medication_id = r.medication_id;
        INSERT INTO stock_movement (medication_id, qty_change, reason, prescription_id)
        VALUES (r.medication_id, -r.quantity, 'DISPENSE', p_prescription_id);
    END LOOP;

    UPDATE prescription SET dispensed_at = now() WHERE prescription_id = p_prescription_id;
END $$;
