-- script: 000_roles.sql
-- Dynamic CRM database roles.
-- Run with psql against the PostgreSQL cluster, outside an explicit transaction.
-- PostgreSQL rejects CREATE ROLE inside a transaction block.
-- Forward-only: run once per cluster. Passwords are applied in the deployment
-- runbook (see docs/03_DATABASE_SCHEMA.md), never in this file.

CREATE ROLE dynamic_crm_migrator NOLOGIN BYPASSRLS;
CREATE ROLE dynamic_crm_runtime NOLOGIN NOBYPASSRLS;
