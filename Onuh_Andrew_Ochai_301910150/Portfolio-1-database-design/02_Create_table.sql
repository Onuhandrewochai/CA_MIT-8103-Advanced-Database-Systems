-- =====================================================================
-- MIT 8103 Advanced Database Systems — Portfolio 1
-- Case study : CareBridge Clinics (simulated multi-branch outpatient clinic, Lagos)
-- DBMS       : PostgreSQL 16
-- File       : 01_schema.sql  — relational schema, keys and constraints (3NF / BCNF)
-- Run        : psql -U postgres -d carebridge -f 01_schema.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- Reference / master data
-- ---------------------------------------------------------------------
CREATE TABLE branch (
    branch_id     SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(80)  NOT NULL UNIQUE,
    address       VARCHAR(200) NOT NULL,
    city          VARCHAR(60)  NOT NULL,
    phone         VARCHAR(20)  NOT NULL
);

CREATE TABLE department (
    department_id SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(60) NOT NULL UNIQUE          -- e.g. General Practice, Paediatrics
);

CREATE TABLE doctor (
    doctor_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    license_no    VARCHAR(20)  NOT NULL UNIQUE,        -- MDCN licence number (candidate key)
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    email         VARCHAR(120) NOT NULL UNIQUE,
    phone         VARCHAR(20),
    department_id SMALLINT NOT NULL REFERENCES department(department_id),
    branch_id     SMALLINT NOT NULL REFERENCES branch(branch_id),
    on_call       BOOLEAN  NOT NULL DEFAULT FALSE,     -- used in Portfolio 3 (write-skew demo)
    hired_on      DATE     NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE patient (
    patient_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hospital_no   VARCHAR(12)  NOT NULL UNIQUE,        -- e.g. CBC-0000001 (candidate key)
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    date_of_birth DATE         NOT NULL CHECK (date_of_birth <= CURRENT_DATE),
    sex           CHAR(1)      NOT NULL CHECK (sex IN ('M','F')),
    phone         VARCHAR(20)  NOT NULL,
    email         VARCHAR(120),
    address       VARCHAR(200),
    blood_group   VARCHAR(3)   CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    registered_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE icd10_code (
    code          VARCHAR(8)   PRIMARY KEY,            -- natural key, e.g. B54 (malaria)
    description   VARCHAR(200) NOT NULL
);

CREATE TABLE medication (
    medication_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    form          VARCHAR(20)  NOT NULL CHECK (form IN ('tablet','capsule','syrup','injection','cream')),
    strength      VARCHAR(30)  NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    stock_qty     INT          NOT NULL CHECK (stock_qty >= 0),   -- negative stock is impossible
    UNIQUE (name, form, strength)
);

CREATE TABLE lab_test (
    test_code     VARCHAR(10)  PRIMARY KEY,            -- e.g. FBC, MPS, FBS
    name          VARCHAR(100) NOT NULL,
    price         NUMERIC(10,2) NOT NULL CHECK (price >= 0)
);

-- ---------------------------------------------------------------------
-- Transactional data
-- ---------------------------------------------------------------------
CREATE TABLE appointment (
    appointment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id     INT      NOT NULL REFERENCES patient(patient_id),
    doctor_id      INT      NOT NULL REFERENCES doctor(doctor_id),
    branch_id      SMALLINT NOT NULL REFERENCES branch(branch_id),
    scheduled_at   TIMESTAMPTZ NOT NULL,
    status         VARCHAR(12) NOT NULL DEFAULT 'BOOKED'
                   CHECK (status IN ('BOOKED','CHECKED_IN','COMPLETED','CANCELLED','NO_SHOW')),
    reason         VARCHAR(200),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Business rule: a doctor cannot hold two active appointments in the same slot.
-- A *partial* unique index enforces it while still allowing cancelled bookings to remain as history.
CREATE UNIQUE INDEX uq_doctor_active_slot
    ON appointment (doctor_id, scheduled_at)
    WHERE status <> 'CANCELLED';

CREATE TABLE diagnosis (
    appointment_id BIGINT     NOT NULL REFERENCES appointment(appointment_id) ON DELETE CASCADE,
    icd10_code     VARCHAR(8) NOT NULL REFERENCES icd10_code(code),
    is_primary     BOOLEAN    NOT NULL DEFAULT FALSE,
    notes          TEXT,
    PRIMARY KEY (appointment_id, icd10_code)            -- M:N between appointment and ICD-10
);

CREATE TABLE prescription (
    prescription_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  BIGINT NOT NULL REFERENCES appointment(appointment_id) ON DELETE CASCADE,
    prescribed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    dispensed_at    TIMESTAMPTZ                          -- NULL until pharmacy dispenses
);

CREATE TABLE prescription_item (
    prescription_id BIGINT NOT NULL REFERENCES prescription(prescription_id) ON DELETE CASCADE,
    medication_id   INT    NOT NULL REFERENCES medication(medication_id),
    dosage          VARCHAR(40) NOT NULL,               -- e.g. "1 tablet"
    frequency       VARCHAR(40) NOT NULL,               -- e.g. "twice daily"
    duration_days   SMALLINT    NOT NULL CHECK (duration_days BETWEEN 1 AND 365),
    quantity        INT         NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (prescription_id, medication_id)
);

CREATE TABLE lab_order (
    lab_order_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id BIGINT      NOT NULL REFERENCES appointment(appointment_id) ON DELETE CASCADE,
    test_code      VARCHAR(10) NOT NULL REFERENCES lab_test(test_code),
    status         VARCHAR(10) NOT NULL DEFAULT 'ORDERED'
                   CHECK (status IN ('ORDERED','COLLECTED','RESULTED','CANCELLED')),
    ordered_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (appointment_id, test_code)
);

CREATE TABLE lab_result (                                -- 1:1 with lab_order (shared PK)
    lab_order_id    BIGINT PRIMARY KEY REFERENCES lab_order(lab_order_id) ON DELETE CASCADE,
    result_value    VARCHAR(40) NOT NULL,
    unit            VARCHAR(20),
    reference_range VARCHAR(40),
    flag            VARCHAR(8) CHECK (flag IN ('LOW','NORMAL','HIGH','POSITIVE','NEGATIVE')),
    resulted_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE invoice (
    invoice_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id BIGINT NOT NULL UNIQUE REFERENCES appointment(appointment_id),  -- 1 invoice per visit
    issued_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    status         VARCHAR(10) NOT NULL DEFAULT 'UNPAID'
                   CHECK (status IN ('UNPAID','PART_PAID','PAID','VOID'))
);

CREATE TABLE invoice_line (
    invoice_id  BIGINT       NOT NULL REFERENCES invoice(invoice_id) ON DELETE CASCADE,
    line_no     SMALLINT     NOT NULL,
    description VARCHAR(120) NOT NULL,
    amount      NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    PRIMARY KEY (invoice_id, line_no)                   -- weak entity: identified through invoice
);

CREATE TABLE payment (
    payment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id  BIGINT        NOT NULL REFERENCES invoice(invoice_id),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    method      VARCHAR(10)   NOT NULL CHECK (method IN ('CASH','CARD','TRANSFER','HMO')),
    reference   VARCHAR(40)   UNIQUE,                   -- bank/POS reference, prevents double posting
    paid_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- Audit trail used in Portfolio 3 (every stock movement is logged)
CREATE TABLE stock_movement (
    movement_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medication_id  INT    NOT NULL REFERENCES medication(medication_id),
    qty_change     INT    NOT NULL CHECK (qty_change <> 0),
    reason         VARCHAR(30) NOT NULL,
    prescription_id BIGINT REFERENCES prescription(prescription_id),
    moved_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Derived data lives in a VIEW, not a stored column (avoids update anomalies)
-- ---------------------------------------------------------------------
CREATE VIEW invoice_balance AS
SELECT i.invoice_id,
       i.appointment_id,
       COALESCE(l.total, 0)                     AS total_due,
       COALESCE(p.paid, 0)                      AS total_paid,
       COALESCE(l.total, 0) - COALESCE(p.paid, 0) AS balance
FROM invoice i
LEFT JOIN (SELECT invoice_id, SUM(amount) total FROM invoice_line GROUP BY invoice_id) l USING (invoice_id)
LEFT JOIN (SELECT invoice_id, SUM(amount) paid  FROM payment      GROUP BY invoice_id) p USING (invoice_id);

-- ---------------------------------------------------------------------
-- Trigger: block over-payment and keep invoice.status consistent
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_payment_check() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_due NUMERIC; v_paid NUMERIC;
BEGIN
    -- lock the invoice row so two concurrent payments are serialised
    PERFORM 1 FROM invoice WHERE invoice_id = NEW.invoice_id FOR UPDATE;
    SELECT COALESCE(SUM(amount),0) INTO v_due  FROM invoice_line WHERE invoice_id = NEW.invoice_id;
    SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payment      WHERE invoice_id = NEW.invoice_id;
    IF v_paid + NEW.amount > v_due THEN
        RAISE EXCEPTION 'Over-payment on invoice %: due %, already paid %, attempted %',
                        NEW.invoice_id, v_due, v_paid, NEW.amount;
    END IF;
    UPDATE invoice
       SET status = CASE WHEN v_paid + NEW.amount = v_due THEN 'PAID' ELSE 'PART_PAID' END
     WHERE invoice_id = NEW.invoice_id;
    RETURN NEW;
END $$;

CREATE TRIGGER payment_before_insert
BEFORE INSERT ON payment
FOR EACH ROW EXECUTE FUNCTION trg_payment_check();

-- Foreign-key columns are NOT indexed automatically in PostgreSQL.
-- They are deliberately left un-indexed here so Portfolio 2 can measure the effect of adding them.
