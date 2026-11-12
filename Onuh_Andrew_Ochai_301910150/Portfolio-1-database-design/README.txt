PORTFOLIO 1 - DATABASE DESIGN AND MODELLING
===========================================


1. SELECTED CASE STUDY
----------------------

Organisation:
    CareBridge Clinics - a simulated chain of four outpatient clinics
    (Ikeja, Lekki, Yaba, Abeokuta)

Nature of the business:
    Walk-in and booked outpatient consultations, an in-house pharmacy,
    a diagnostic laboratory, and billing (cash, card, transfer, HMO)

Database users:
    - Front-desk officers (register patients, book appointments)
    - Doctors (record diagnoses, prescribe, order tests)
    - Pharmacists (dispense, manage stock)
    - Lab scientists (enter results)
    - Cashiers (invoice and receive payment)
    - Management (reports)

Major data stored:
    Branches, departments, doctors, patients, appointments, ICD-10
    diagnoses, medications and stock, prescriptions, lab orders and
    results, invoices, payments, stock movements

Key operations:
    - Register patient
    - Book / cancel appointment without double-booking a doctor
    - Record diagnosis
    - Prescribe and dispense drugs (decrementing stock)
    - Order and result lab tests
    - Invoice and take payment without over-payment
    - Retrieve full patient history
    - Branch revenue and disease-trend reports

The same case study is used in all five portfolios.


2. ENTITY-RELATIONSHIP DIAGRAM
------------------------------

See the image file: erd.png

erd.dot is the source; regenerate with:
    dot -Tpng erd.dot -o erd.png

Relationships and cardinalities:

  Relationship                     Cardinality          How it is implemented
  -------------------------------  -------------------  ------------------------------------------------
  Branch employs Doctor            1 : N                doctor.branch_id FK
  Department groups Doctor         1 : N                doctor.department_id FK
  Patient books Appointment        1 : N                appointment.patient_id FK
  Doctor attends Appointment       1 : N                appointment.doctor_id FK
  Appointment <-> ICD-10 code      M : N                associative entity "diagnosis" with composite PK
  Prescription <-> Medication      M : N                associative entity "prescription_item" with
                                                        composite PK
  Lab order produces Lab result    1 : 0..1             lab_result.lab_order_id is both PK and FK
                                                        (shared primary key)
  Appointment billed by Invoice    1 : 0..1             invoice.appointment_id is FK AND UNIQUE
  Invoice itemised by Invoice line 1 : N (weak entity)  PK (invoice_id, line_no)


3. RELATIONAL SCHEMA (SUMMARY)
------------------------------

Notation: [PK] = primary key, [FK] = foreign key, [PK, FK] = both.
Full DDL is in 01_schema.sql.

  branch            (branch_id [PK], name, address, city, phone)

  department        (department_id [PK], name)

  doctor            (doctor_id [PK], license_no, first_name, last_name,
                     email, phone, department_id [FK], branch_id [FK],
                     on_call, hired_on)

  patient           (patient_id [PK], hospital_no, first_name, last_name,
                     date_of_birth, sex, phone, email, address,
                     blood_group, registered_at)

  appointment       (appointment_id [PK], patient_id [FK], doctor_id [FK],
                     branch_id [FK], scheduled_at, status, reason,
                     created_at)

  icd10_code        (code [PK], description)

  diagnosis         (appointment_id [PK, FK], icd10_code [PK, FK],
                     is_primary, notes)

  medication        (medication_id [PK], name, form, strength,
                     unit_price, stock_qty)

  prescription      (prescription_id [PK], appointment_id [FK],
                     prescribed_at, dispensed_at)

  prescription_item (prescription_id [PK, FK], medication_id [PK, FK],
                     dosage, frequency, duration_days, quantity)

  lab_test          (test_code [PK], name, price)

  lab_order         (lab_order_id [PK], appointment_id [FK],
                     test_code [FK], status, ordered_at)

  lab_result        (lab_order_id [PK, FK], result_value, unit,
                     reference_range, flag, resulted_at)

  invoice           (invoice_id [PK], appointment_id [FK], issued_at,
                     status)

  invoice_line      (invoice_id [PK, FK], line_no [PK], description,
                     amount)

  payment           (payment_id [PK], invoice_id [FK], amount, method,
                     reference, paid_at)

  stock_movement    (movement_id [PK], medication_id [FK], qty_change,
                     reason, prescription_id [FK], moved_at)


4. KEYS AND CONSTRAINTS - AND WHY EACH EXISTS
---------------------------------------------

Surrogate PKs (GENERATED ALWAYS AS IDENTITY)
    Example:       patient_id
    Business rule: Stable, compact join keys; natural values (phone,
                   name) can change.

Candidate keys kept as UNIQUE
    Example:       patient.hospital_no, doctor.license_no, doctor.email
    Business rule: No duplicate patient folders; one licence = one
                   doctor.

Natural PKs where the code is stable
    Example:       icd10_code.code, lab_test.test_code
    Business rule: International / internal codes never change meaning.

Composite PKs
    Example:       diagnosis, prescription_item, invoice_line
    Business rule: Same drug cannot appear twice on one prescription.

CHECK
    Example:       stock_qty >= 0, sex IN ('M','F'), valid blood groups,
                   amount > 0
    Business rule: Domain integrity enforced by the DBMS, not only the
                   app.

Partial unique index
    Example:       UNIQUE (doctor_id, scheduled_at)
                   WHERE status <> 'CANCELLED'
    Business rule: A doctor can't be double-booked, but cancelled slots
                   stay as history and can be re-booked.

ON DELETE CASCADE only on dependent children
    Example:       prescription_item, lab_result, invoice_line
    Business rule: Deleting a parent removes meaningless orphans; master
                   data (patient, doctor) is NOT cascaded.

Trigger
    Example:       payment_before_insert
    Business rule: Blocks over-payment and keeps invoice.status in sync
                   (row-locks the invoice -> safe under concurrency,
                   see Portfolio 3).

View for derived data
    Example:       invoice_balance
    Business rule: Totals are computed, never stored -> no update
                   anomaly.

Evidence: constraint_tests_output.txt shows five deliberately invalid
inserts each rejected by the correct constraint (negative stock,
invalid sex, invalid blood group, missing FK, duplicate branch name).


5. NORMALISATION
----------------

5.1 Starting point - the clinic's paper/Excel "visit register" (UNF)

  visit_no:       1001
  date:           03/11
  patient_name:   Ada Okafor
  patient_phone:  0803...
  doctor:         Dr Bello
  doctor_dept:    Paediatrics
  branch:         Ikeja
  branch_address: 12 Allen Ave
  diagnoses:      B54, D50.9
  drugs (name, qty, price): Coartem x6 @150, Ferrous x30 @8

Problems: repeating groups (diagnoses, drugs), and the same
patient/doctor/branch facts repeated on every visit.


5.2 First Normal Form (1NF) - atomic values, no repeating groups

Split each repeating group into its own row: one row per (visit,
diagnosis, drug). Key becomes (visit_no, icd10_code, drug_name).

Remaining problem: patient_name depends only on visit_no -> PARTIAL
DEPENDENCY on part of the composite key.


5.3 Second Normal Form (2NF) - remove partial dependencies

  - visit_no -> date, patient, doctor, branch      => appointment
  - (visit_no, icd10_code) -> notes                => diagnosis
  - (visit_no, drug) -> qty                        => prescription_item
  - drug -> price                                  => medication

Remaining problem: in appointment, doctor -> doctor_dept and
branch -> branch_address - TRANSITIVE DEPENDENCIES
(visit_no -> doctor -> doctor_dept).


5.4 Third Normal Form (3NF) / BCNF - remove transitive dependencies

  - doctor_id -> name, license_no, department_id, branch_id  => doctor
  - department_id -> name                                    => department
  - branch_id -> name, address                               => branch
  - patient_id -> name, phone, dob...                        => patient

BCNF check: in every table, every determinant is a candidate key.
E.g. in doctor the determinants are doctor_id, license_no and email -
all candidate keys. In prescription_item the only determinant of the
non-key attributes is the full key (prescription_id, medication_id).


5.5 Deliberate design decisions

  - appointment.branch_id is kept even though a doctor has a home
    branch: doctors rotate, so the visit's branch is a fact about the
    VISIT, not derivable from the doctor. It is not a transitive
    dependency.

  - Invoice totals are not stored - computed by the invoice_balance
    view (avoids update anomalies). Portfolio 2 shows this stays fast
    with the right index.

  - unit_price is not copied into prescription_item. A production
    system would snapshot the price at dispensing time (price
    history); left out here to keep the model in strict 3NF, noted as
    a future improvement.


6. HOW TO RUN
-------------

  createdb -U postgres carebridge
  psql -U postgres -d carebridge -f 01_schema.sql
  psql -U postgres -d carebridge -f 02_reference_data.sql   # also runs the constraint tests

Tested on PostgreSQL 16.15.
Output: schema_output.txt, constraint_tests_output.txt
