-- Portfolio 1 — reference data + a few hand-written records that prove the constraints work.
SET search_path TO clinic;


INSERT INTO branch (name, address, city, phone) VALUES
 ('CareBridge Ikeja',      '12 Allen Avenue, Ikeja',          'Lagos', '+2348010000001'),
 ('CareBridge Lekki',      '5 Admiralty Way, Lekki Phase 1',  'Lagos', '+2348010000002'),
 ('CareBridge Yaba',       '44 Herbert Macaulay Way, Yaba',   'Lagos', '+2348010000003'),
 ('CareBridge Abeokuta',   '9 Kuto Road, Abeokuta',           'Ogun',  '+2348010000004');


INSERT INTO department (name) VALUES
 ('General Practice'), ('Paediatrics'), ('Obstetrics & Gynaecology'),
 ('Internal Medicine'), ('Dermatology'), ('Ophthalmology');


INSERT INTO icd10_code (code, description) VALUES
 ('B54',   'Unspecified malaria'),
 ('A01.0', 'Typhoid fever'),
 ('I10',   'Essential (primary) hypertension'),
 ('E11.9', 'Type 2 diabetes mellitus without complications'),
 ('J06.9', 'Acute upper respiratory infection, unspecified'),
 ('K29.7', 'Gastritis, unspecified'),
 ('N39.0', 'Urinary tract infection, site not specified'),
 ('L30.9', 'Dermatitis, unspecified'),
 ('H10.9', 'Conjunctivitis, unspecified'),
 ('Z34.9', 'Supervision of normal pregnancy, unspecified'),
 ('D50.9', 'Iron deficiency anaemia, unspecified'),
 ('M54.5', 'Low back pain');


INSERT INTO medication (name, form, strength, unit_price, stock_qty) VALUES
 ('Artemether/Lumefantrine', 'tablet',  '20/120mg', 150.00, 5000),
 ('Paracetamol',             'tablet',  '500mg',     10.00, 20000),
 ('Amoxicillin',             'capsule', '500mg',     40.00, 8000),
 ('Ciprofloxacin',           'tablet',  '500mg',     60.00, 6000),
 ('Amlodipine',              'tablet',  '5mg',       35.00, 7000),
 ('Metformin',               'tablet',  '500mg',     25.00, 9000),
 ('Omeprazole',              'capsule', '20mg',      45.00, 6000),
 ('Ferrous Sulphate',        'tablet',  '200mg',      8.00, 10000),
 ('Hydrocortisone',          'cream',   '1%',       900.00, 400),
 ('Chloramphenicol',         'syrup',   '0.5%',     700.00, 300),
 ('Ceftriaxone',             'injection','1g',     1500.00, 1200),
 ('Folic Acid',              'tablet',  '5mg',        5.00, 15000);


INSERT INTO lab_test (test_code, name, price) VALUES
 ('MPS',  'Malaria parasite smear',       2500),
 ('FBC',  'Full blood count',             6000),
 ('WIDAL','Widal test',                   3000),
 ('FBS',  'Fasting blood sugar',          2000),
 ('HBA1C','Glycated haemoglobin',        12000),
 ('UA',   'Urinalysis',                   2500),
 ('LFT',  'Liver function test',         15000),
 ('PCV',  'Packed cell volume',           1500);


-- ---------------------------------------------------------------------
-- Constraint tests (each statement is EXPECTED to fail; see constraint_tests_output.txt)
-- ---------------------------------------------------------------------
\echo '--- Expected failures: constraint enforcement ---'
\set ON_ERROR_STOP off
INSERT INTO medication (name, form, strength, unit_price, stock_qty) VALUES ('Test','tablet','1mg',1,-5);      -- CHECK stock_qty >= 0
INSERT INTO patient (hospital_no, first_name, last_name, date_of_birth, sex, phone) VALUES ('X1','A','B','1990-01-01','Z','080'); -- CHECK sex
INSERT INTO patient (hospital_no, first_name, last_name, date_of_birth, sex, phone, blood_group) VALUES ('X2','A','B','1990-01-01','M','080','C+'); -- CHECK blood_group
INSERT INTO lab_order (appointment_id, test_code) VALUES (999999, 'MPS');                                           -- FK appointment
INSERT INTO branch (name, address, city, phone) VALUES ('CareBridge Ikeja','dup','Lagos','0');                   -- UNIQUE name
\set ON_ERROR_STOP on
