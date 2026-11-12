-- =====================================================================
-- MIT 8103 Advanced Database Systems — Portfolio 1
-- Case study : CareBridge Clinics (simulated multi-branch outpatient clinic, Lagos)
-- DBMS       : PostgreSQL 16
-- File       : 01_schema.sql
-- Run        : psql -U postgres -d carebridge -f 01_schema.sql
-- =====================================================================


CREATE SCHEMA AND PRIVILEGES




--CREATE USER clinic IDENTIFIED BY "Clinic$$123"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users;

--GRANT CONNECT, RESOURCE TO clinic;
GRANT CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE TO clinic;