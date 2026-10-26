-- script: 001_core.sql
-- Dynamic CRM relational core. PostgreSQL 17.
-- Run as a superuser after 000_roles.sql, against the database named dynamic_crm.
-- The whole file is one transaction. TimescaleDB is applied later by 002_timescale.sql.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE schema_migrations (
  filename text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

CREATE TYPE tenant_status AS ENUM ('provisioning', 'active', 'suspended', 'cancelled');
CREATE TYPE user_role AS ENUM ('tenant_admin', 'technician', 'account_manager', 'client_viewer');
CREATE TYPE user_status AS ENUM ('invited', 'active', 'disabled');
CREATE TYPE custom_field_type AS ENUM ('text', 'number', 'boolean', 'enum', 'date', 'currency');
CREATE TYPE billing_interval AS ENUM ('one_time', 'monthly', 'quarterly', 'annual', 'block_hours');
CREATE TYPE order_line_kind AS ENUM ('service', 'hardware', 'license', 'block_hours');
CREATE TYPE procurement_status AS ENUM ('not_required', 'to_order', 'ordered', 'received', 'deployed');
CREATE TYPE node_kind AS ENUM (
  'server', 'network_switch', 'website', 'api_endpoint',
  'ssl_certificate', 'cloud_instance', 'application'
);
CREATE TYPE check_type AS ENUM ('heartbeat', 'ping', 'http', 'tcp', 'ssl', 'resource');
CREATE TYPE node_status AS ENUM ('unknown', 'up', 'degraded', 'down', 'maintenance');
CREATE TYPE ticket_priority AS ENUM ('low', 'normal', 'high', 'urgent');
CREATE TYPE comment_visibility AS ENUM ('internal', 'client');
CREATE TYPE alert_comparator AS ENUM ('gt', 'gte', 'lt', 'lte', 'eq', 'neq');
CREATE TYPE alert_aggregation AS ENUM ('last', 'avg', 'min', 'max');
CREATE TYPE alert_severity AS ENUM ('info', 'warning', 'critical');
CREATE TYPE incident_source AS ENUM ('rule', 'heartbeat', 'check', 'sla', 'block_hours');
CREATE TYPE incident_status AS ENUM ('open', 'acknowledged', 'resolved');
CREATE TYPE breach_kind AS ENUM ('response', 'resolution');
CREATE TYPE clock_mode AS ENUM ('24x7', 'business_hours');

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION sla_targets_valid(targets jsonb) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT targets IS NOT NULL
    AND targets ?& ARRAY['urgent', 'high', 'normal', 'low']
    AND (
      SELECT bool_and(
        jsonb_typeof(targets -> p -> 'response_minutes') = 'number'
        AND jsonb_typeof(targets -> p -> 'resolution_minutes') = 'number'
        AND (targets -> p ->> 'response_minutes') ~ '^[0-9]+$'
        AND (targets -> p ->> 'resolution_minutes') ~ '^[0-9]+$'
        AND (targets -> p ->> 'response_minutes')::integer > 0
        AND (targets -> p ->> 'resolution_minutes')::integer
            >= (targets -> p ->> 'response_minutes')::integer
      )
      FROM unnest(ARRAY['urgent', 'high', 'normal', 'low']) AS p
    );
$$;

CREATE OR REPLACE FUNCTION business_hours_valid(hours jsonb) RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  day_key text;
  span jsonb;
  start_m integer;
  end_m integer;
  prev_end integer;
BEGIN
  IF hours IS NULL OR jsonb_typeof(hours) <> 'object' THEN
    RETURN false;
  END IF;

  FOR day_key IN SELECT jsonb_object_keys(hours)
  LOOP
    IF day_key <> ALL (ARRAY['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']) THEN
      RETURN false;
    END IF;
    IF jsonb_typeof(hours -> day_key) <> 'array' THEN
      RETURN false;
    END IF;

    prev_end := -1;
    FOR span IN SELECT jsonb_array_elements(hours -> day_key)
    LOOP
      IF jsonb_typeof(span) <> 'array' OR jsonb_array_length(span) <> 2 THEN
        RETURN false;
      END IF;
      IF (span ->> 0) !~ '^[0-2][0-9]:[0-5][0-9]$'
         OR (span ->> 1) !~ '^[0-2][0-9]:[0-5][0-9]$' THEN
        RETURN false;
      END IF;
      start_m := split_part(span ->> 0, ':', 1)::integer * 60
        + split_part(span ->> 0, ':', 2)::integer;
      end_m := split_part(span ->> 1, ':', 1)::integer * 60
        + split_part(span ->> 1, ':', 2)::integer;
      IF start_m < 0 OR end_m > 1440 OR start_m >= end_m OR start_m < prev_end THEN
        RETURN false;
      END IF;
      prev_end := end_m;
    END LOOP;
  END LOOP;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION holiday_list_valid(days jsonb) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT days IS NOT NULL
    AND jsonb_typeof(days) = 'array'
    AND (
      SELECT coalesce(bool_and(value ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'), true)
      FROM jsonb_array_elements_text(days) AS value
    );
$$;

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION reject_tenant_id_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
    RAISE EXCEPTION 'tenant_id is immutable';
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tenants and users
-- ---------------------------------------------------------------------------

CREATE TABLE tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  legal_name text,
  slug citext NOT NULL,
  status tenant_status NOT NULL DEFAULT 'active',
  billing_email citext,
  phone text,
  address jsonb NOT NULL DEFAULT '{}'::jsonb,
  timezone text NOT NULL DEFAULT 'UTC',
  currency_code char(3) NOT NULL DEFAULT 'USD',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenants_slug_uniq UNIQUE (slug),
  CONSTRAINT tenants_slug_chk CHECK (
    (slug::text) ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    AND char_length(slug::text) BETWEEN 3 AND 48
  ),
  CONSTRAINT tenants_name_chk CHECK (char_length(name) BETWEEN 1 AND 200),
  CONSTRAINT tenants_currency_chk CHECK (currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT tenants_address_obj CHECK (jsonb_typeof(address) = 'object'),
  CONSTRAINT tenants_timezone_chk CHECK (char_length(timezone) BETWEEN 1 AND 64)
);

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid,
  email citext NOT NULL,
  full_name text NOT NULL,
  password_hash text NOT NULL,
  role user_role NOT NULL,
  status user_status NOT NULL DEFAULT 'active',
  token_version integer NOT NULL DEFAULT 1 CHECK (token_version > 0),
  timezone text NOT NULL DEFAULT 'UTC',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_email_uniq UNIQUE (email),
  CONSTRAINT users_email_chk CHECK (
    char_length(email::text) BETWEEN 3 AND 320
    AND position('@' IN (email::text)) > 1
  ),
  CONSTRAINT users_name_chk CHECK (char_length(full_name) BETWEEN 1 AND 200),
  CONSTRAINT users_password_hash_chk CHECK (char_length(password_hash) >= 50),
  CONSTRAINT users_timezone_chk CHECK (char_length(timezone) BETWEEN 1 AND 64)
);

CREATE TABLE refresh_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  family_id uuid NOT NULL,
  token_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  replaced_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT refresh_tokens_hash_uniq UNIQUE (token_hash)
);

ALTER TABLE refresh_tokens
  ADD CONSTRAINT refresh_tokens_replaced_by_fk
  FOREIGN KEY (replaced_by) REFERENCES refresh_tokens (id) ON DELETE SET NULL;

CREATE TABLE entity_schema_revisions (
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  entity_key text NOT NULL,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  PRIMARY KEY (tenant_id, entity_key)
);

-- ---------------------------------------------------------------------------
-- Status lifecycles
-- ---------------------------------------------------------------------------

CREATE TABLE status_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  entity_type text NOT NULL,
  key text NOT NULL,
  label text NOT NULL,
  sort_order integer NOT NULL,
  category text NOT NULL,
  is_initial boolean NOT NULL DEFAULT false,
  is_terminal boolean NOT NULL DEFAULT false,
  pauses_sla boolean NOT NULL DEFAULT false,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT status_definitions_entity_chk CHECK (
    entity_type IN ('crm_customer', 'crm_opportunity', 'crm_order', 'crm_ticket')
  ),
  CONSTRAINT status_definitions_key_chk CHECK (key ~ '^[a-z][a-z0-9_]{0,39}$'),
  CONSTRAINT status_definitions_category_chk CHECK (category IN ('open', 'pending', 'closed')),
  CONSTRAINT status_definitions_pause_chk CHECK (pauses_sla = false OR entity_type = 'crm_ticket'),
  CONSTRAINT status_definitions_label_chk CHECK (char_length(label) BETWEEN 1 AND 80),
  CONSTRAINT status_definitions_unique_key UNIQUE (tenant_id, entity_type, key)
);

CREATE UNIQUE INDEX status_definitions_one_initial
  ON status_definitions (tenant_id, entity_type)
  WHERE is_initial AND archived_at IS NULL;

CREATE TABLE status_transitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  entity_type text NOT NULL,
  from_key text NOT NULL,
  to_key text NOT NULL,
  client_allowed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT status_transitions_distinct_chk CHECK (from_key <> to_key),
  CONSTRAINT status_transitions_unique UNIQUE (tenant_id, entity_type, from_key, to_key),
  CONSTRAINT status_transitions_from_fk
    FOREIGN KEY (tenant_id, entity_type, from_key)
    REFERENCES status_definitions (tenant_id, entity_type, key),
  CONSTRAINT status_transitions_to_fk
    FOREIGN KEY (tenant_id, entity_type, to_key)
    REFERENCES status_definitions (tenant_id, entity_type, key)
);

-- ---------------------------------------------------------------------------
-- Dynamic configuration
-- ---------------------------------------------------------------------------

CREATE TABLE escalation_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  name text NOT NULL,
  steps jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT escalation_policies_name_chk CHECK (char_length(name) BETWEEN 1 AND 120),
  CONSTRAINT escalation_policies_steps_chk CHECK (
    jsonb_typeof(steps) = 'array' AND jsonb_array_length(steps) BETWEEN 1 AND 10
  )
);

CREATE TABLE custom_entity_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  key text NOT NULL,
  label text NOT NULL,
  plural_label text NOT NULL,
  description text,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT custom_entity_key_chk CHECK (key ~ '^[a-z][a-z0-9_]{0,39}$'),
  CONSTRAINT custom_entity_label_chk CHECK (
    char_length(label) BETWEEN 1 AND 80
    AND char_length(plural_label) BETWEEN 1 AND 80
  )
);

CREATE UNIQUE INDEX custom_entity_key_uniq
  ON custom_entity_definitions (tenant_id, key)
  WHERE archived_at IS NULL;

CREATE TABLE custom_field_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  target_entity text NOT NULL,
  custom_entity_id uuid REFERENCES custom_entity_definitions (id) ON DELETE RESTRICT,
  key text NOT NULL,
  label text NOT NULL,
  data_type custom_field_type NOT NULL,
  required boolean NOT NULL DEFAULT false,
  exposed_to_client boolean NOT NULL DEFAULT false,
  help_text text,
  enum_options jsonb NOT NULL DEFAULT '[]'::jsonb,
  validation jsonb NOT NULL DEFAULT '{}'::jsonb,
  layout jsonb NOT NULL DEFAULT '{"section":"Details","width":"half"}'::jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT custom_fields_target_chk CHECK (
    target_entity IN (
      'crm_customer', 'crm_contact', 'crm_opportunity', 'crm_order',
      'crm_order_line', 'crm_ticket', 'monitored_node', 'custom_record'
    )
  ),
  CONSTRAINT custom_fields_entity_link_chk CHECK (
    (target_entity = 'custom_record' AND custom_entity_id IS NOT NULL)
    OR (target_entity <> 'custom_record' AND custom_entity_id IS NULL)
  ),
  CONSTRAINT custom_fields_key_chk CHECK (key ~ '^[a-z][a-z0-9_]{0,39}$'),
  CONSTRAINT custom_fields_label_chk CHECK (char_length(label) BETWEEN 1 AND 120),
  CONSTRAINT custom_fields_enum_chk CHECK (
    (
      data_type = 'enum'
      AND jsonb_typeof(enum_options) = 'array'
      AND jsonb_array_length(enum_options) BETWEEN 1 AND 100
    )
    OR (
      data_type <> 'enum'
      AND jsonb_typeof(enum_options) = 'array'
      AND jsonb_array_length(enum_options) = 0
    )
  ),
  CONSTRAINT custom_fields_validation_chk CHECK (jsonb_typeof(validation) = 'object'),
  CONSTRAINT custom_fields_layout_chk CHECK (
    jsonb_typeof(layout) = 'object'
    AND layout ->> 'width' IN ('half', 'full')
    AND coalesce(layout ->> 'section', '') <> ''
  )
);

CREATE UNIQUE INDEX custom_fields_core_key_uniq
  ON custom_field_definitions (tenant_id, target_entity, key)
  WHERE custom_entity_id IS NULL AND archived_at IS NULL;

CREATE UNIQUE INDEX custom_fields_custom_entity_key_uniq
  ON custom_field_definitions (tenant_id, custom_entity_id, key)
  WHERE custom_entity_id IS NOT NULL AND archived_at IS NULL;

-- ---------------------------------------------------------------------------
-- CRM
-- ---------------------------------------------------------------------------

CREATE TABLE crm_customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  name text NOT NULL,
  legal_name text,
  slug text,
  entity_type text NOT NULL DEFAULT 'crm_customer',
  status_key text NOT NULL,
  account_owner_user_id uuid REFERENCES users (id) ON DELETE SET NULL,
  billing_email citext,
  currency_code char(3) NOT NULL DEFAULT 'USD',
  timezone text NOT NULL DEFAULT 'UTC',
  notes text,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT crm_customers_entity_type_chk CHECK (entity_type = 'crm_customer'),
  CONSTRAINT crm_customers_name_chk CHECK (char_length(name) BETWEEN 1 AND 200),
  CONSTRAINT crm_customers_currency_chk CHECK (currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT crm_customers_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT crm_customers_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384),
  CONSTRAINT crm_customers_status_fk
    FOREIGN KEY (tenant_id, entity_type, status_key)
    REFERENCES status_definitions (tenant_id, entity_type, key)
);

CREATE UNIQUE INDEX crm_customers_slug_uniq
  ON crm_customers (tenant_id, slug)
  WHERE slug IS NOT NULL AND deleted_at IS NULL;

ALTER TABLE users
  ADD CONSTRAINT users_customer_id_fk
  FOREIGN KEY (customer_id) REFERENCES crm_customers (id) ON DELETE RESTRICT;

CREATE TABLE crm_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES crm_customers (id) ON DELETE RESTRICT,
  full_name text NOT NULL,
  email citext,
  phone text,
  job_title text,
  is_primary boolean NOT NULL DEFAULT false,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT crm_contacts_name_chk CHECK (char_length(full_name) BETWEEN 1 AND 200),
  CONSTRAINT crm_contacts_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT crm_contacts_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384)
);

CREATE UNIQUE INDEX crm_contacts_one_primary
  ON crm_contacts (tenant_id, customer_id)
  WHERE is_primary AND deleted_at IS NULL;

CREATE UNIQUE INDEX crm_contacts_email_uniq
  ON crm_contacts (tenant_id, email)
  WHERE deleted_at IS NULL AND email IS NOT NULL;

CREATE TABLE sla_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid REFERENCES crm_customers (id) ON DELETE RESTRICT,
  escalation_policy_id uuid NOT NULL REFERENCES escalation_policies (id) ON DELETE RESTRICT,
  name text NOT NULL,
  clock_mode clock_mode NOT NULL,
  timezone text NOT NULL,
  business_hours jsonb NOT NULL,
  holidays jsonb NOT NULL DEFAULT '[]'::jsonb,
  targets jsonb NOT NULL,
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT sla_contracts_name_chk CHECK (char_length(name) BETWEEN 1 AND 160),
  CONSTRAINT sla_contracts_timezone_chk CHECK (char_length(timezone) BETWEEN 1 AND 64),
  CONSTRAINT sla_contracts_hours_chk CHECK (business_hours_valid(business_hours)),
  CONSTRAINT sla_contracts_holidays_chk CHECK (holiday_list_valid(holidays)),
  CONSTRAINT sla_contracts_targets_chk CHECK (sla_targets_valid(targets))
);

CREATE UNIQUE INDEX sla_contracts_customer_default_uniq
  ON sla_contracts (tenant_id, customer_id)
  WHERE is_default AND deleted_at IS NULL AND customer_id IS NOT NULL;

CREATE UNIQUE INDEX sla_contracts_tenant_default_uniq
  ON sla_contracts (tenant_id)
  WHERE is_default AND deleted_at IS NULL AND customer_id IS NULL;

CREATE TABLE crm_opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES crm_customers (id) ON DELETE RESTRICT,
  owner_user_id uuid REFERENCES users (id) ON DELETE SET NULL,
  name text NOT NULL,
  entity_type text NOT NULL DEFAULT 'crm_opportunity',
  status_key text NOT NULL,
  amount_minor bigint,
  currency_code char(3) NOT NULL,
  expected_close_on date,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT crm_opportunities_entity_type_chk CHECK (entity_type = 'crm_opportunity'),
  CONSTRAINT crm_opportunities_name_chk CHECK (char_length(name) BETWEEN 1 AND 200),
  CONSTRAINT crm_opportunities_amount_chk CHECK (amount_minor IS NULL OR amount_minor >= 0),
  CONSTRAINT crm_opportunities_currency_chk CHECK (currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT crm_opportunities_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT crm_opportunities_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384),
  CONSTRAINT crm_opportunities_status_fk
    FOREIGN KEY (tenant_id, entity_type, status_key)
    REFERENCES status_definitions (tenant_id, entity_type, key)
);

CREATE TABLE crm_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES crm_customers (id) ON DELETE RESTRICT,
  opportunity_id uuid REFERENCES crm_opportunities (id) ON DELETE RESTRICT,
  entity_type text NOT NULL DEFAULT 'crm_order',
  status_key text NOT NULL,
  billing_interval billing_interval NOT NULL,
  currency_code char(3) NOT NULL,
  term_starts_on date,
  term_ends_on date,
  block_hours_purchased numeric(10, 2),
  block_hours_consumed numeric(10, 2) NOT NULL DEFAULT 0,
  recurring_amount_minor bigint,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT crm_orders_entity_type_chk CHECK (entity_type = 'crm_order'),
  CONSTRAINT crm_orders_currency_chk CHECK (currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT crm_orders_term_chk CHECK (
    term_starts_on IS NULL OR term_ends_on IS NULL OR term_ends_on >= term_starts_on
  ),
  CONSTRAINT crm_orders_block_purchased_chk CHECK (
    billing_interval <> 'block_hours'
    OR (block_hours_purchased IS NOT NULL AND block_hours_purchased > 0)
  ),
  CONSTRAINT crm_orders_block_consumed_chk CHECK (block_hours_consumed >= 0),
  CONSTRAINT crm_orders_recurring_chk CHECK (
    recurring_amount_minor IS NULL
    OR (
      billing_interval IN ('monthly', 'quarterly', 'annual')
      AND recurring_amount_minor >= 0
    )
  ),
  CONSTRAINT crm_orders_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT crm_orders_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384),
  CONSTRAINT crm_orders_status_fk
    FOREIGN KEY (tenant_id, entity_type, status_key)
    REFERENCES status_definitions (tenant_id, entity_type, key)
);

CREATE TABLE crm_order_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES crm_orders (id) ON DELETE CASCADE,
  kind order_line_kind NOT NULL,
  sku text,
  description text NOT NULL,
  quantity numeric(12, 2) NOT NULL,
  unit_amount_minor bigint NOT NULL,
  currency_code char(3) NOT NULL,
  procurement_status procurement_status NOT NULL DEFAULT 'not_required',
  vendor text,
  serial_or_license_ref text,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_order_lines_desc_chk CHECK (char_length(description) BETWEEN 1 AND 300),
  CONSTRAINT crm_order_lines_qty_chk CHECK (quantity > 0),
  CONSTRAINT crm_order_lines_amount_chk CHECK (unit_amount_minor >= 0),
  CONSTRAINT crm_order_lines_currency_chk CHECK (currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT crm_order_lines_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT crm_order_lines_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384)
);

-- ---------------------------------------------------------------------------
-- Monitoring
-- ---------------------------------------------------------------------------

CREATE TABLE monitored_nodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid REFERENCES crm_customers (id) ON DELETE RESTRICT,
  name text NOT NULL,
  kind node_kind NOT NULL,
  check_type check_type NOT NULL,
  target text NOT NULL,
  check_interval_seconds integer NOT NULL,
  missed_heartbeat_threshold integer NOT NULL DEFAULT 3,
  status node_status NOT NULL DEFAULT 'unknown',
  next_check_at timestamptz,
  last_checked_at timestamptz,
  last_seen_at timestamptz,
  stale_claimed_until timestamptz,
  ssl_expires_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT monitored_nodes_name_chk CHECK (char_length(name) BETWEEN 1 AND 200),
  CONSTRAINT monitored_nodes_target_chk CHECK (char_length(target) BETWEEN 1 AND 500),
  CONSTRAINT monitored_nodes_interval_chk CHECK (check_interval_seconds BETWEEN 15 AND 86400),
  CONSTRAINT monitored_nodes_threshold_chk CHECK (missed_heartbeat_threshold BETWEEN 1 AND 20),
  CONSTRAINT monitored_nodes_metadata_obj CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT monitored_nodes_metadata_size CHECK (octet_length(metadata::text) <= 8192),
  CONSTRAINT monitored_nodes_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT monitored_nodes_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384)
);

CREATE TABLE ingest_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  node_id uuid REFERENCES monitored_nodes (id) ON DELETE RESTRICT,
  name text NOT NULL,
  token_hash text NOT NULL,
  last_used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ingest_credentials_name_chk CHECK (char_length(name) BETWEEN 1 AND 120),
  CONSTRAINT ingest_credentials_hash_uniq UNIQUE (token_hash)
);

CREATE TABLE crm_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES crm_customers (id) ON DELETE RESTRICT,
  contact_id uuid REFERENCES crm_contacts (id) ON DELETE SET NULL,
  node_id uuid REFERENCES monitored_nodes (id) ON DELETE SET NULL,
  order_line_id uuid REFERENCES crm_order_lines (id) ON DELETE SET NULL,
  sla_contract_id uuid REFERENCES sla_contracts (id) ON DELETE SET NULL,
  assignee_user_id uuid REFERENCES users (id) ON DELETE SET NULL,
  entity_type text NOT NULL DEFAULT 'crm_ticket',
  status_key text NOT NULL,
  priority ticket_priority NOT NULL DEFAULT 'normal',
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  time_spent_hours numeric(8, 2) NOT NULL DEFAULT 0,
  response_due_at timestamptz,
  resolution_due_at timestamptz,
  first_responded_at timestamptz,
  resolved_at timestamptz,
  sla_paused_at timestamptz,
  response_remaining_seconds integer,
  resolution_remaining_seconds integer,
  response_breached boolean NOT NULL DEFAULT false,
  resolution_breached boolean NOT NULL DEFAULT false,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT crm_tickets_entity_type_chk CHECK (entity_type = 'crm_ticket'),
  CONSTRAINT crm_tickets_title_chk CHECK (char_length(title) BETWEEN 1 AND 200),
  CONSTRAINT crm_tickets_time_chk CHECK (time_spent_hours >= 0),
  CONSTRAINT crm_tickets_remaining_chk CHECK (
    (response_remaining_seconds IS NULL OR response_remaining_seconds >= 0)
    AND (resolution_remaining_seconds IS NULL OR resolution_remaining_seconds >= 0)
  ),
  CONSTRAINT crm_tickets_sla_pause_chk CHECK (
    (
      sla_paused_at IS NULL
      AND response_remaining_seconds IS NULL
      AND resolution_remaining_seconds IS NULL
    )
    OR (
      sla_paused_at IS NOT NULL
      AND response_due_at IS NULL
      AND resolution_due_at IS NULL
    )
  ),
  CONSTRAINT crm_tickets_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT crm_tickets_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384),
  CONSTRAINT crm_tickets_status_fk
    FOREIGN KEY (tenant_id, entity_type, status_key)
    REFERENCES status_definitions (tenant_id, entity_type, key)
);

CREATE TABLE ticket_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  ticket_id uuid NOT NULL REFERENCES crm_tickets (id) ON DELETE CASCADE,
  author_user_id uuid REFERENCES users (id) ON DELETE SET NULL,
  visibility comment_visibility NOT NULL,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ticket_comments_body_chk CHECK (char_length(body) BETWEEN 1 AND 20000)
);

CREATE TABLE custom_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  entity_id uuid NOT NULL REFERENCES custom_entity_definitions (id) ON DELETE RESTRICT,
  customer_id uuid REFERENCES crm_customers (id) ON DELETE RESTRICT,
  title text NOT NULL,
  custom_attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT custom_records_title_chk CHECK (char_length(title) BETWEEN 1 AND 200),
  CONSTRAINT custom_records_custom_attributes_object_chk CHECK (jsonb_typeof(custom_attributes) = 'object'),
  CONSTRAINT custom_records_custom_attributes_size_chk CHECK (octet_length(custom_attributes::text) <= 16384)
);

CREATE TABLE dashboard_layouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  role user_role,
  user_id uuid REFERENCES users (id) ON DELETE CASCADE,
  name text NOT NULL,
  widgets jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dashboard_layouts_name_chk CHECK (char_length(name) BETWEEN 1 AND 120),
  CONSTRAINT dashboard_layouts_widgets_array CHECK (jsonb_typeof(widgets) = 'array'),
  CONSTRAINT dashboard_layouts_widget_count CHECK (jsonb_array_length(widgets) <= 8),
  CONSTRAINT dashboard_layouts_owner_chk CHECK (
    (user_id IS NULL AND role IS NOT NULL)
    OR (user_id IS NOT NULL AND role IS NULL)
  )
);

CREATE UNIQUE INDEX dashboard_layouts_role_uniq
  ON dashboard_layouts (tenant_id, role)
  WHERE user_id IS NULL;

CREATE UNIQUE INDEX dashboard_layouts_user_uniq
  ON dashboard_layouts (tenant_id, user_id)
  WHERE user_id IS NOT NULL;

CREATE TABLE alert_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  node_id uuid REFERENCES monitored_nodes (id) ON DELETE RESTRICT,
  customer_id uuid REFERENCES crm_customers (id) ON DELETE RESTRICT,
  node_kind node_kind,
  escalation_policy_id uuid REFERENCES escalation_policies (id) ON DELETE RESTRICT,
  name text NOT NULL,
  metric_name text NOT NULL,
  comparator alert_comparator NOT NULL,
  threshold double precision NOT NULL,
  window_seconds integer NOT NULL DEFAULT 0,
  aggregation alert_aggregation NOT NULL DEFAULT 'last',
  severity alert_severity NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  cooldown_seconds integer NOT NULL DEFAULT 300,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT alert_rules_name_chk CHECK (char_length(name) BETWEEN 1 AND 160),
  CONSTRAINT alert_rules_metric_chk CHECK (metric_name ~ '^[a-z][a-z0-9_.]{0,63}$'),
  CONSTRAINT alert_rules_window_chk CHECK (window_seconds BETWEEN 0 AND 86400),
  CONSTRAINT alert_rules_cooldown_chk CHECK (cooldown_seconds BETWEEN 0 AND 86400),
  CONSTRAINT alert_rules_threshold_chk CHECK (
    threshold = threshold
    AND threshold <> 'NaN'::double precision
    AND threshold <> 'Infinity'::double precision
    AND threshold <> '-Infinity'::double precision
  )
);

CREATE TABLE alert_incidents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  source incident_source NOT NULL,
  rule_id uuid REFERENCES alert_rules (id) ON DELETE RESTRICT,
  node_id uuid REFERENCES monitored_nodes (id) ON DELETE RESTRICT,
  ticket_id uuid REFERENCES crm_tickets (id) ON DELETE RESTRICT,
  order_id uuid REFERENCES crm_orders (id) ON DELETE RESTRICT,
  customer_id uuid REFERENCES crm_customers (id) ON DELETE RESTRICT,
  breach_kind breach_kind,
  threshold_name text,
  status incident_status NOT NULL DEFAULT 'open',
  severity alert_severity NOT NULL,
  summary text NOT NULL,
  last_value double precision,
  opened_at timestamptz NOT NULL DEFAULT now(),
  acknowledged_at timestamptz,
  resolved_at timestamptz,
  last_escalation_step integer NOT NULL DEFAULT -1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT alert_incidents_summary_chk CHECK (char_length(summary) BETWEEN 1 AND 500),
  CONSTRAINT alert_incidents_step_chk CHECK (last_escalation_step >= -1)
);

CREATE UNIQUE INDEX alert_incidents_open_rule
  ON alert_incidents (tenant_id, rule_id, node_id)
  WHERE status <> 'resolved' AND source = 'rule' AND rule_id IS NOT NULL AND node_id IS NOT NULL;

CREATE UNIQUE INDEX alert_incidents_open_heartbeat
  ON alert_incidents (tenant_id, node_id)
  WHERE status <> 'resolved' AND source = 'heartbeat' AND node_id IS NOT NULL;

CREATE UNIQUE INDEX alert_incidents_open_check
  ON alert_incidents (tenant_id, node_id)
  WHERE status <> 'resolved' AND source = 'check' AND node_id IS NOT NULL;

CREATE UNIQUE INDEX alert_incidents_open_sla
  ON alert_incidents (tenant_id, ticket_id, breach_kind)
  WHERE status <> 'resolved' AND source = 'sla' AND ticket_id IS NOT NULL AND breach_kind IS NOT NULL;

CREATE UNIQUE INDEX alert_incidents_open_block
  ON alert_incidents (tenant_id, order_id, threshold_name)
  WHERE status <> 'resolved' AND source = 'block_hours' AND order_id IS NOT NULL AND threshold_name IS NOT NULL;

CREATE TABLE notification_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  incident_id uuid NOT NULL REFERENCES alert_incidents (id) ON DELETE CASCADE,
  step_index integer NOT NULL CHECK (step_index >= 0),
  target jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_intents_target_obj CHECK (jsonb_typeof(target) = 'object'),
  CONSTRAINT notification_intents_step_uniq UNIQUE (incident_id, step_index)
);

CREATE TABLE audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  actor_user_id uuid REFERENCES users (id) ON DELETE SET NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  before_state jsonb,
  after_state jsonb,
  ip inet,
  request_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_logs_action_chk CHECK (action ~ '^[a-z0-9_.]+$'),
  CONSTRAINT audit_logs_entity_chk CHECK (char_length(entity_type) BETWEEN 1 AND 80)
);

CREATE TABLE ingest_receipts (
  tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, idempotency_key),
  CONSTRAINT ingest_receipts_key_chk CHECK (char_length(idempotency_key) BETWEEN 8 AND 200)
);

-- High-velocity samples. No foreign keys: a hypertable insert must not take
-- a lock on the parent node row, and Timescale unique constraints must include
-- recorded_at. The ingest service checks that node_id belongs to the credential's
-- tenant before inserting. A nightly reconciliation reports orphan node ids.
CREATE TABLE telemetry_metrics (
  tenant_id uuid NOT NULL,
  node_id uuid NOT NULL,
  metric_name text NOT NULL,
  recorded_at timestamptz NOT NULL,
  value double precision NOT NULL,
  unit text,
  attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT telemetry_metrics_pk PRIMARY KEY (tenant_id, node_id, metric_name, recorded_at),
  CONSTRAINT telemetry_metrics_metric_chk CHECK (metric_name ~ '^[a-z][a-z0-9_.]{0,63}$'),
  CONSTRAINT telemetry_metrics_value_chk CHECK (
    value <> 'NaN'::double precision
    AND value <> 'Infinity'::double precision
    AND value <> '-Infinity'::double precision
  ),
  CONSTRAINT telemetry_metrics_pct_chk CHECK (
    metric_name NOT LIKE '%.util_pct' OR (value >= 0 AND value <= 100)
  ),
  CONSTRAINT telemetry_metrics_attributes_obj CHECK (jsonb_typeof(attributes) = 'object')
);

ALTER TABLE monitored_nodes SET (fillfactor = 80);
ALTER TABLE alert_incidents SET (fillfactor = 80);
ALTER TABLE crm_tickets SET (fillfactor = 80);
ALTER TABLE telemetry_metrics SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  fillfactor = 100
);

-- ---------------------------------------------------------------------------
-- Secondary indexes
-- Foreign keys are not auto-indexed. Leading tenant_id supports the RLS
-- predicate together with the application predicate.
-- ---------------------------------------------------------------------------

CREATE INDEX users_tenant_id_idx ON users (tenant_id);
CREATE INDEX users_customer_id_idx ON users (customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX users_tenant_role_idx ON users (tenant_id, role);

CREATE INDEX refresh_tokens_tenant_id_idx ON refresh_tokens (tenant_id);
CREATE INDEX refresh_tokens_user_id_idx ON refresh_tokens (user_id);
CREATE INDEX refresh_tokens_family_id_idx ON refresh_tokens (family_id);

CREATE INDEX status_definitions_tenant_idx ON status_definitions (tenant_id, entity_type);
CREATE INDEX status_transitions_tenant_idx ON status_transitions (tenant_id, entity_type);

CREATE INDEX escalation_policies_tenant_idx ON escalation_policies (tenant_id);
CREATE INDEX custom_entity_definitions_tenant_idx ON custom_entity_definitions (tenant_id);
CREATE INDEX custom_field_definitions_target_idx
  ON custom_field_definitions (tenant_id, target_entity)
  WHERE archived_at IS NULL;

CREATE INDEX crm_customers_tenant_status_idx
  ON crm_customers (tenant_id, status_key)
  WHERE deleted_at IS NULL;
CREATE INDEX crm_customers_owner_idx
  ON crm_customers (tenant_id, account_owner_user_id)
  WHERE deleted_at IS NULL AND account_owner_user_id IS NOT NULL;

CREATE INDEX crm_contacts_customer_idx
  ON crm_contacts (tenant_id, customer_id)
  WHERE deleted_at IS NULL;

CREATE INDEX sla_contracts_customer_idx ON sla_contracts (tenant_id, customer_id) WHERE deleted_at IS NULL;
CREATE INDEX sla_contracts_policy_idx ON sla_contracts (escalation_policy_id);

CREATE INDEX crm_opportunities_customer_idx
  ON crm_opportunities (tenant_id, customer_id)
  WHERE deleted_at IS NULL;
CREATE INDEX crm_opportunities_status_idx
  ON crm_opportunities (tenant_id, status_key)
  WHERE deleted_at IS NULL;

CREATE INDEX crm_orders_customer_idx
  ON crm_orders (tenant_id, customer_id)
  WHERE deleted_at IS NULL;
CREATE INDEX crm_orders_opportunity_idx ON crm_orders (opportunity_id) WHERE opportunity_id IS NOT NULL;
CREATE INDEX crm_order_lines_order_idx ON crm_order_lines (tenant_id, order_id);
CREATE INDEX crm_order_lines_procurement_idx
  ON crm_order_lines (tenant_id, procurement_status)
  WHERE procurement_status IN ('to_order', 'ordered');

CREATE INDEX monitored_nodes_customer_idx
  ON monitored_nodes (tenant_id, customer_id)
  WHERE deleted_at IS NULL;
CREATE INDEX monitored_nodes_status_idx
  ON monitored_nodes (tenant_id, status)
  WHERE deleted_at IS NULL;
CREATE INDEX monitored_nodes_ssl_expiry_idx
  ON monitored_nodes (tenant_id, ssl_expires_at)
  WHERE deleted_at IS NULL AND ssl_expires_at IS NOT NULL;
CREATE INDEX monitored_nodes_due_idx
  ON monitored_nodes (next_check_at)
  WHERE deleted_at IS NULL AND check_type IN ('http', 'tcp', 'ssl', 'ping');
CREATE INDEX monitored_nodes_heartbeat_seen_idx
  ON monitored_nodes (last_seen_at)
  WHERE deleted_at IS NULL AND check_type IN ('heartbeat', 'resource');

CREATE INDEX ingest_credentials_tenant_idx ON ingest_credentials (tenant_id) WHERE revoked_at IS NULL;
CREATE INDEX ingest_credentials_node_idx ON ingest_credentials (node_id) WHERE node_id IS NOT NULL;

CREATE INDEX crm_tickets_customer_idx
  ON crm_tickets (tenant_id, customer_id)
  WHERE deleted_at IS NULL;
CREATE INDEX crm_tickets_open_idx
  ON crm_tickets (tenant_id, updated_at DESC)
  WHERE deleted_at IS NULL AND resolved_at IS NULL;
CREATE INDEX crm_tickets_response_due_idx
  ON crm_tickets (tenant_id, response_due_at)
  WHERE response_breached = false
    AND first_responded_at IS NULL
    AND response_due_at IS NOT NULL
    AND deleted_at IS NULL;
CREATE INDEX crm_tickets_resolution_due_idx
  ON crm_tickets (tenant_id, resolution_due_at)
  WHERE resolution_breached = false
    AND resolved_at IS NULL
    AND resolution_due_at IS NOT NULL
    AND deleted_at IS NULL;
CREATE INDEX crm_tickets_node_idx ON crm_tickets (node_id) WHERE node_id IS NOT NULL;
CREATE INDEX crm_tickets_order_line_idx ON crm_tickets (order_line_id) WHERE order_line_id IS NOT NULL;
CREATE INDEX ticket_comments_ticket_idx ON ticket_comments (tenant_id, ticket_id, created_at);

CREATE INDEX custom_records_entity_idx
  ON custom_records (tenant_id, entity_id)
  WHERE deleted_at IS NULL;
CREATE INDEX custom_records_customer_idx
  ON custom_records (tenant_id, customer_id)
  WHERE deleted_at IS NULL AND customer_id IS NOT NULL;

CREATE INDEX alert_rules_tenant_idx ON alert_rules (tenant_id, metric_name) WHERE enabled;
CREATE INDEX alert_rules_node_idx ON alert_rules (node_id) WHERE node_id IS NOT NULL;
CREATE INDEX alert_incidents_queue_idx
  ON alert_incidents (tenant_id, status, opened_at DESC);
CREATE INDEX alert_incidents_node_idx ON alert_incidents (tenant_id, node_id) WHERE node_id IS NOT NULL;
CREATE INDEX alert_incidents_ticket_idx ON alert_incidents (tenant_id, ticket_id) WHERE ticket_id IS NOT NULL;
CREATE INDEX notification_intents_incident_idx ON notification_intents (incident_id);

CREATE INDEX audit_logs_tenant_time_idx ON audit_logs (tenant_id, created_at DESC);
CREATE INDEX audit_logs_entity_idx ON audit_logs (tenant_id, entity_type, entity_id, created_at DESC);
CREATE INDEX ingest_receipts_received_idx ON ingest_receipts (received_at);

-- Default opclass jsonb_ops supports containment (@>) and key existence (?, ?|, ?&).
-- jsonb_path_ops is smaller and serves only @>. The dynamic filter API uses both
-- families, and these tables are low-write, so the fuller opclass is the one we build.
CREATE INDEX crm_customers_custom_attributes_gin
  ON crm_customers USING GIN (custom_attributes jsonb_ops);
CREATE INDEX crm_contacts_custom_attributes_gin
  ON crm_contacts USING GIN (custom_attributes jsonb_ops);
CREATE INDEX crm_opportunities_custom_attributes_gin
  ON crm_opportunities USING GIN (custom_attributes jsonb_ops);
CREATE INDEX crm_orders_custom_attributes_gin
  ON crm_orders USING GIN (custom_attributes jsonb_ops);
CREATE INDEX crm_order_lines_custom_attributes_gin
  ON crm_order_lines USING GIN (custom_attributes jsonb_ops);
CREATE INDEX crm_tickets_custom_attributes_gin
  ON crm_tickets USING GIN (custom_attributes jsonb_ops);
CREATE INDEX monitored_nodes_custom_attributes_gin
  ON monitored_nodes USING GIN (custom_attributes jsonb_ops);
CREATE INDEX custom_records_custom_attributes_gin
  ON custom_records USING GIN (custom_attributes jsonb_ops);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION status_transition_terminal_check() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  from_terminal boolean;
BEGIN
  SELECT is_terminal INTO from_terminal
  FROM status_definitions
  WHERE tenant_id = NEW.tenant_id
    AND entity_type = NEW.entity_type
    AND key = NEW.from_key;

  IF from_terminal AND NOT (NEW.entity_type = 'crm_ticket' AND NEW.to_key = 'in_progress') THEN
    RAISE EXCEPTION 'terminal status has no outbound transition';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER status_transitions_terminal
  BEFORE INSERT OR UPDATE ON status_transitions
  FOR EACH ROW EXECUTE FUNCTION status_transition_terminal_check();

CREATE OR REPLACE FUNCTION users_customer_scope_check() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
BEGIN
  IF NEW.role = 'client_viewer' AND NEW.customer_id IS NULL THEN
    RAISE EXCEPTION 'client_viewer requires customer_id';
  END IF;
  IF NEW.role <> 'client_viewer' AND NEW.customer_id IS NOT NULL THEN
    RAISE EXCEPTION 'customer_id is only valid for client_viewer';
  END IF;
  IF NEW.customer_id IS NOT NULL THEN
    SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
    IF customer_tenant IS NULL OR customer_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION 'customer must belong to the user tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER users_customer_scope
  BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION users_customer_scope_check();

CREATE OR REPLACE FUNCTION custom_fields_immutable() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.key <> OLD.key
     OR NEW.data_type <> OLD.data_type
     OR NEW.target_entity <> OLD.target_entity
     OR NEW.custom_entity_id IS DISTINCT FROM OLD.custom_entity_id
     OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
    RAISE EXCEPTION 'custom field key, data_type, and target are immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER custom_field_definitions_immutable
  BEFORE UPDATE ON custom_field_definitions
  FOR EACH ROW EXECUTE FUNCTION custom_fields_immutable();

CREATE OR REPLACE FUNCTION enforce_custom_field_cap() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  field_count integer;
BEGIN
  IF NEW.archived_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT count(*) INTO field_count
  FROM custom_field_definitions
  WHERE tenant_id = NEW.tenant_id
    AND target_entity = NEW.target_entity
    AND custom_entity_id IS NOT DISTINCT FROM NEW.custom_entity_id
    AND archived_at IS NULL
    AND id <> NEW.id;
  IF field_count >= 50 THEN
    RAISE EXCEPTION 'custom field cap exceeded';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER custom_field_definitions_cap
  BEFORE INSERT OR UPDATE ON custom_field_definitions
  FOR EACH ROW EXECUTE FUNCTION enforce_custom_field_cap();

CREATE OR REPLACE FUNCTION enforce_custom_entity_cap() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  entity_count integer;
BEGIN
  IF NEW.archived_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  SELECT count(*) INTO entity_count
  FROM custom_entity_definitions
  WHERE tenant_id = NEW.tenant_id
    AND archived_at IS NULL
    AND id <> NEW.id;
  IF entity_count >= 20 THEN
    RAISE EXCEPTION 'custom entity cap exceeded';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER custom_entity_definitions_cap
  BEFORE INSERT OR UPDATE ON custom_entity_definitions
  FOR EACH ROW EXECUTE FUNCTION enforce_custom_entity_cap();

CREATE OR REPLACE FUNCTION custom_fields_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  entity_tenant uuid;
BEGIN
  IF NEW.custom_entity_id IS NOT NULL THEN
    SELECT tenant_id INTO entity_tenant
    FROM custom_entity_definitions
    WHERE id = NEW.custom_entity_id;
    IF entity_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'custom entity must belong to the tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER custom_field_definitions_same_tenant
  BEFORE INSERT OR UPDATE ON custom_field_definitions
  FOR EACH ROW EXECUTE FUNCTION custom_fields_same_tenant();

CREATE OR REPLACE FUNCTION bump_named_revision() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant uuid;
  v_key text;
BEGIN
  v_tenant := COALESCE(NEW.tenant_id, OLD.tenant_id);
  v_key := TG_ARGV[0];
  INSERT INTO entity_schema_revisions (tenant_id, entity_key, revision)
  VALUES (v_tenant, v_key, 1)
  ON CONFLICT (tenant_id, entity_key)
  DO UPDATE SET revision = entity_schema_revisions.revision + 1;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION bump_custom_field_revision() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant uuid;
  v_key text;
BEGIN
  v_tenant := COALESCE(NEW.tenant_id, OLD.tenant_id);
  IF COALESCE(NEW.target_entity, OLD.target_entity) = 'custom_record' THEN
    v_key := 'custom_record:' || COALESCE(NEW.custom_entity_id, OLD.custom_entity_id)::text;
  ELSE
    v_key := COALESCE(NEW.target_entity, OLD.target_entity);
  END IF;
  INSERT INTO entity_schema_revisions (tenant_id, entity_key, revision)
  VALUES (v_tenant, v_key, 1)
  ON CONFLICT (tenant_id, entity_key)
  DO UPDATE SET revision = entity_schema_revisions.revision + 1;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION bump_status_revision() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant uuid;
  v_entity text;
BEGIN
  v_tenant := COALESCE(NEW.tenant_id, OLD.tenant_id);
  v_entity := COALESCE(NEW.entity_type, OLD.entity_type);
  INSERT INTO entity_schema_revisions (tenant_id, entity_key, revision)
  VALUES (v_tenant, 'status:' || v_entity, 1)
  ON CONFLICT (tenant_id, entity_key)
  DO UPDATE SET revision = entity_schema_revisions.revision + 1;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER custom_field_definitions_revision
  AFTER INSERT OR UPDATE OR DELETE ON custom_field_definitions
  FOR EACH ROW EXECUTE FUNCTION bump_custom_field_revision();

CREATE TRIGGER custom_entity_definitions_revision
  AFTER INSERT OR UPDATE OR DELETE ON custom_entity_definitions
  FOR EACH ROW EXECUTE FUNCTION bump_named_revision('custom_entities');

CREATE TRIGGER status_definitions_revision
  AFTER INSERT OR UPDATE OR DELETE ON status_definitions
  FOR EACH ROW EXECUTE FUNCTION bump_status_revision();

CREATE TRIGGER status_transitions_revision
  AFTER INSERT OR UPDATE OR DELETE ON status_transitions
  FOR EACH ROW EXECUTE FUNCTION bump_status_revision();

CREATE TRIGGER alert_rules_revision
  AFTER INSERT OR UPDATE OR DELETE ON alert_rules
  FOR EACH ROW EXECUTE FUNCTION bump_named_revision('alert_rules');

CREATE OR REPLACE FUNCTION sla_contracts_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
  policy_tenant uuid;
BEGIN
  IF NEW.customer_id IS NOT NULL THEN
    SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
    IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'sla customer must belong to the tenant';
    END IF;
  END IF;
  SELECT tenant_id INTO policy_tenant FROM escalation_policies WHERE id = NEW.escalation_policy_id;
  IF policy_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'escalation policy must belong to the tenant';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER sla_contracts_same_tenant
  BEFORE INSERT OR UPDATE ON sla_contracts
  FOR EACH ROW EXECUTE FUNCTION sla_contracts_same_tenant();

CREATE OR REPLACE FUNCTION crm_orders_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
  opportunity_customer uuid;
  opportunity_tenant uuid;
BEGIN
  SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
  IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'order customer must belong to the tenant';
  END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.currency_code IS DISTINCT FROM OLD.currency_code
     AND EXISTS (SELECT 1 FROM crm_order_lines WHERE order_id = NEW.id) THEN
    RAISE EXCEPTION 'cannot change order currency while lines exist';
  END IF;
  IF NEW.opportunity_id IS NOT NULL THEN
    SELECT tenant_id, customer_id INTO opportunity_tenant, opportunity_customer
    FROM crm_opportunities WHERE id = NEW.opportunity_id;
    IF opportunity_tenant IS DISTINCT FROM NEW.tenant_id
       OR opportunity_customer IS DISTINCT FROM NEW.customer_id THEN
      RAISE EXCEPTION 'order opportunity must belong to the order customer';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER crm_orders_same_tenant
  BEFORE INSERT OR UPDATE ON crm_orders
  FOR EACH ROW EXECUTE FUNCTION crm_orders_same_tenant();

CREATE OR REPLACE FUNCTION crm_order_lines_match_order() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  order_currency char(3);
  order_interval billing_interval;
  order_tenant uuid;
BEGIN
  SELECT tenant_id, currency_code, billing_interval
    INTO order_tenant, order_currency, order_interval
  FROM crm_orders
  WHERE id = NEW.order_id;

  IF order_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'order line must belong to the order tenant';
  END IF;
  IF NEW.currency_code <> order_currency THEN
    RAISE EXCEPTION 'line currency must match order currency';
  END IF;
  IF NEW.kind = 'block_hours' AND order_interval <> 'block_hours' THEN
    RAISE EXCEPTION 'block_hours lines require a block_hours order';
  END IF;
  IF NEW.kind <> 'block_hours' AND order_interval = 'block_hours' THEN
    RAISE EXCEPTION 'block_hours orders only accept block_hours lines';
  END IF;
  IF NEW.kind IN ('hardware', 'license') AND NEW.procurement_status = 'not_required' THEN
    RAISE EXCEPTION 'hardware and license lines require procurement status';
  END IF;
  IF NEW.kind NOT IN ('hardware', 'license') AND NEW.procurement_status <> 'not_required' THEN
    RAISE EXCEPTION 'procurement status is only for hardware and license lines';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER crm_order_lines_match_order
  BEFORE INSERT OR UPDATE ON crm_order_lines
  FOR EACH ROW EXECUTE FUNCTION crm_order_lines_match_order();

CREATE OR REPLACE FUNCTION assert_block_order_lines(p_tenant uuid, p_order uuid) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  interval_kind billing_interval;
  alive boolean;
  line_count integer;
BEGIN
  SELECT billing_interval, deleted_at IS NULL
    INTO interval_kind, alive
  FROM crm_orders
  WHERE id = p_order AND tenant_id = p_tenant;

  IF interval_kind IS DISTINCT FROM 'block_hours' OR NOT coalesce(alive, false) THEN
    RETURN;
  END IF;

  SELECT count(*) INTO line_count
  FROM crm_order_lines
  WHERE order_id = p_order AND tenant_id = p_tenant;

  IF line_count <> 1 THEN
    RAISE EXCEPTION 'block_hours orders require exactly one line';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION assert_order_block_line() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM assert_block_order_lines(NEW.tenant_id, NEW.id);
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER crm_orders_block_hours_line
  AFTER INSERT OR UPDATE OF billing_interval, deleted_at, block_hours_purchased ON crm_orders
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_order_block_line();

CREATE OR REPLACE FUNCTION assert_line_block_counts() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
    PERFORM assert_block_order_lines(OLD.tenant_id, OLD.order_id);
  END IF;
  IF TG_OP = 'DELETE' THEN
    PERFORM assert_block_order_lines(OLD.tenant_id, OLD.order_id);
  ELSE
    PERFORM assert_block_order_lines(NEW.tenant_id, NEW.order_id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER crm_order_lines_block_hours_count
  AFTER INSERT OR UPDATE OR DELETE ON crm_order_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_line_block_counts();

CREATE OR REPLACE FUNCTION crm_contacts_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
BEGIN
  SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
  IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'contact customer must belong to the tenant';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER crm_contacts_same_tenant
  BEFORE INSERT OR UPDATE ON crm_contacts
  FOR EACH ROW EXECUTE FUNCTION crm_contacts_same_tenant();

CREATE OR REPLACE FUNCTION crm_opportunities_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
BEGIN
  SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
  IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'opportunity customer must belong to the tenant';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER crm_opportunities_same_tenant
  BEFORE INSERT OR UPDATE ON crm_opportunities
  FOR EACH ROW EXECUTE FUNCTION crm_opportunities_same_tenant();

CREATE OR REPLACE FUNCTION crm_tickets_refs_check() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
  node_tenant uuid;
  node_customer uuid;
  contact_tenant uuid;
  contact_customer uuid;
  line_tenant uuid;
  line_customer uuid;
  contract_tenant uuid;
  contract_customer uuid;
BEGIN
  SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
  IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'ticket customer must belong to the tenant';
  END IF;

  IF NEW.contact_id IS NOT NULL THEN
    SELECT tenant_id, customer_id INTO contact_tenant, contact_customer
    FROM crm_contacts WHERE id = NEW.contact_id;
    IF contact_tenant IS DISTINCT FROM NEW.tenant_id
       OR contact_customer IS DISTINCT FROM NEW.customer_id THEN
      RAISE EXCEPTION 'ticket contact must belong to the ticket customer';
    END IF;
  END IF;

  IF NEW.node_id IS NOT NULL THEN
    SELECT tenant_id, customer_id INTO node_tenant, node_customer
    FROM monitored_nodes WHERE id = NEW.node_id;
    IF node_tenant IS DISTINCT FROM NEW.tenant_id OR node_customer IS DISTINCT FROM NEW.customer_id THEN
      RAISE EXCEPTION 'ticket node must belong to the ticket customer';
    END IF;
  END IF;

  IF NEW.order_line_id IS NOT NULL THEN
    SELECT l.tenant_id, o.customer_id INTO line_tenant, line_customer
    FROM crm_order_lines AS l
    JOIN crm_orders AS o ON o.id = l.order_id
    WHERE l.id = NEW.order_line_id;
    IF line_tenant IS DISTINCT FROM NEW.tenant_id OR line_customer IS DISTINCT FROM NEW.customer_id THEN
      RAISE EXCEPTION 'ticket order line must belong to the ticket customer';
    END IF;
  END IF;

  IF NEW.sla_contract_id IS NOT NULL THEN
    SELECT tenant_id, customer_id INTO contract_tenant, contract_customer
    FROM sla_contracts WHERE id = NEW.sla_contract_id;
    IF contract_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'ticket sla contract must belong to the tenant';
    END IF;
    IF contract_customer IS NOT NULL AND contract_customer IS DISTINCT FROM NEW.customer_id THEN
      RAISE EXCEPTION 'ticket sla contract must belong to the ticket customer';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER crm_tickets_refs_check
  BEFORE INSERT OR UPDATE ON crm_tickets
  FOR EACH ROW EXECUTE FUNCTION crm_tickets_refs_check();

CREATE OR REPLACE FUNCTION monitored_nodes_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  customer_tenant uuid;
BEGIN
  IF NEW.customer_id IS NOT NULL THEN
    SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
    IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'node customer must belong to the tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER monitored_nodes_same_tenant
  BEFORE INSERT OR UPDATE ON monitored_nodes
  FOR EACH ROW EXECUTE FUNCTION monitored_nodes_same_tenant();

CREATE OR REPLACE FUNCTION ingest_credentials_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  node_tenant uuid;
BEGIN
  IF NEW.node_id IS NOT NULL THEN
    SELECT tenant_id INTO node_tenant FROM monitored_nodes WHERE id = NEW.node_id;
    IF node_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'ingest credential node must belong to the tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ingest_credentials_same_tenant
  BEFORE INSERT OR UPDATE ON ingest_credentials
  FOR EACH ROW EXECUTE FUNCTION ingest_credentials_same_tenant();

CREATE OR REPLACE FUNCTION alert_rules_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  node_tenant uuid;
  customer_tenant uuid;
  policy_tenant uuid;
BEGIN
  IF NEW.node_id IS NOT NULL THEN
    SELECT tenant_id INTO node_tenant FROM monitored_nodes WHERE id = NEW.node_id;
    IF node_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'alert rule node must belong to the tenant';
    END IF;
  END IF;
  IF NEW.customer_id IS NOT NULL THEN
    SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
    IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'alert rule customer must belong to the tenant';
    END IF;
  END IF;
  IF NEW.escalation_policy_id IS NOT NULL THEN
    SELECT tenant_id INTO policy_tenant FROM escalation_policies WHERE id = NEW.escalation_policy_id;
    IF policy_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'escalation policy must belong to the tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER alert_rules_same_tenant
  BEFORE INSERT OR UPDATE ON alert_rules
  FOR EACH ROW EXECUTE FUNCTION alert_rules_same_tenant();

CREATE OR REPLACE FUNCTION custom_records_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  entity_tenant uuid;
  customer_tenant uuid;
BEGIN
  SELECT tenant_id INTO entity_tenant FROM custom_entity_definitions WHERE id = NEW.entity_id;
  IF entity_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'custom record entity must belong to the tenant';
  END IF;
  IF NEW.customer_id IS NOT NULL THEN
    SELECT tenant_id INTO customer_tenant FROM crm_customers WHERE id = NEW.customer_id;
    IF customer_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'custom record customer must belong to the tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER custom_records_same_tenant
  BEFORE INSERT OR UPDATE ON custom_records
  FOR EACH ROW EXECUTE FUNCTION custom_records_same_tenant();

CREATE OR REPLACE FUNCTION ticket_comments_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  ticket_tenant uuid;
BEGIN
  SELECT tenant_id INTO ticket_tenant FROM crm_tickets WHERE id = NEW.ticket_id;
  IF ticket_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'comment ticket must belong to the tenant';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ticket_comments_same_tenant
  BEFORE INSERT OR UPDATE ON ticket_comments
  FOR EACH ROW EXECUTE FUNCTION ticket_comments_same_tenant();

CREATE OR REPLACE FUNCTION dashboard_layouts_same_tenant() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  user_tenant uuid;
BEGIN
  IF NEW.user_id IS NOT NULL THEN
    SELECT tenant_id INTO user_tenant FROM users WHERE id = NEW.user_id;
    IF user_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'dashboard user must belong to the tenant';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER dashboard_layouts_same_tenant
  BEFORE INSERT OR UPDATE ON dashboard_layouts
  FOR EACH ROW EXECUTE FUNCTION dashboard_layouts_same_tenant();

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'tenants', 'users', 'status_definitions', 'escalation_policies',
    'custom_entity_definitions', 'custom_field_definitions', 'crm_customers',
    'crm_contacts', 'sla_contracts', 'crm_opportunities', 'crm_orders',
    'crm_order_lines', 'monitored_nodes', 'crm_tickets', 'custom_records',
    'dashboard_layouts', 'alert_rules', 'alert_incidents'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
      table_name || '_set_updated_at',
      table_name
    );
    IF table_name <> 'tenants' THEN
      EXECUTE format(
        'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION reject_tenant_id_change()',
        table_name || '_reject_tenant_change',
        table_name
      );
    END IF;
  END LOOP;
END;
$$;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'refresh_tokens', 'status_transitions', 'ingest_credentials',
    'ticket_comments', 'notification_intents', 'audit_logs', 'ingest_receipts'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION reject_tenant_id_change()',
      table_name || '_reject_tenant_change',
      table_name
    );
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- Missing app.tenant_id fails closed: the comparison is unknown and no row matches.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.relname AS table_name
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_attribute AS a ON a.attrelid = c.oid
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND a.attname = 'tenant_id'
      AND a.attnum > 0
      AND NOT a.attisdropped
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', r.table_name);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', r.table_name);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I
         USING (
           current_setting(''app.tenant_id'', true) IS NOT NULL
           AND tenant_id = current_setting(''app.tenant_id'', true)::uuid
         )
         WITH CHECK (
           current_setting(''app.tenant_id'', true) IS NOT NULL
           AND tenant_id = current_setting(''app.tenant_id'', true)::uuid
         )',
      r.table_name
    );
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Privileged functions. Allowlist is documented in docs/03_DATABASE_SCHEMA.md.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION lookup_user_by_email(p_email citext)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  customer_id uuid,
  password_hash text,
  role user_role,
  status user_status,
  full_name text,
  token_version integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN QUERY
  SELECT u.id, u.tenant_id, u.customer_id, u.password_hash, u.role, u.status, u.full_name, u.token_version
  FROM public.users AS u
  WHERE u.email = p_email
  LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION load_session(p_user_id uuid)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  customer_id uuid,
  role user_role,
  status user_status,
  token_version integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN QUERY
  SELECT u.id, u.tenant_id, u.customer_id, u.role, u.status, u.token_version
  FROM public.users AS u
  WHERE u.id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION lookup_ingest_credential(p_token_hash text)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  node_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN QUERY
  SELECT c.id, c.tenant_id, c.node_id
  FROM public.ingest_credentials AS c
  WHERE c.token_hash = p_token_hash
    AND c.revoked_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION claim_due_probes(p_limit integer)
RETURNS SETOF monitored_nodes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'claim limit out of range';
  END IF;

  RETURN QUERY
  UPDATE public.monitored_nodes AS n
  SET next_check_at = now() + make_interval(secs => n.check_interval_seconds),
      last_checked_at = now()
  FROM (
    SELECT m.id
    FROM public.monitored_nodes AS m
    JOIN public.tenants AS t ON t.id = m.tenant_id
    WHERE m.next_check_at <= now()
      AND m.deleted_at IS NULL
      AND m.check_type IN ('http', 'tcp', 'ssl', 'ping')
      AND t.status = 'active'
    ORDER BY m.next_check_at
    FOR UPDATE OF m SKIP LOCKED
    LIMIT p_limit
  ) AS claimed
  WHERE n.id = claimed.id
  RETURNING n.*;
END;
$$;

CREATE OR REPLACE FUNCTION claim_stale_heartbeats(p_limit integer)
RETURNS SETOF monitored_nodes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'claim limit out of range';
  END IF;

  RETURN QUERY
  UPDATE public.monitored_nodes AS n
  SET stale_claimed_until = now() + INTERVAL '1 minute'
  FROM (
    SELECT m.id
    FROM public.monitored_nodes AS m
    JOIN public.tenants AS t ON t.id = m.tenant_id
    WHERE m.deleted_at IS NULL
      AND m.check_type IN ('heartbeat', 'resource')
      AND m.status <> 'maintenance'
      AND t.status = 'active'
      AND (m.stale_claimed_until IS NULL OR m.stale_claimed_until < now())
      AND (
        (
          m.last_seen_at IS NULL
          AND m.created_at <= now() - make_interval(secs => m.check_interval_seconds * m.missed_heartbeat_threshold)
        )
        OR m.last_seen_at <= now() - make_interval(secs => m.check_interval_seconds * m.missed_heartbeat_threshold)
      )
    ORDER BY m.created_at
    FOR UPDATE OF m SKIP LOCKED
    LIMIT p_limit
  ) AS claimed
  WHERE n.id = claimed.id
  RETURNING n.*;
END;
$$;

CREATE OR REPLACE FUNCTION list_active_tenant_ids()
RETURNS TABLE (id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN QUERY
  SELECT t.id
  FROM public.tenants AS t
  WHERE t.status = 'active'
  ORDER BY t.id;
END;
$$;

CREATE OR REPLACE FUNCTION purge_ingest_receipts(p_older_than interval)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  deleted_count bigint;
BEGIN
  IF p_older_than < INTERVAL '1 hour' THEN
    RAISE EXCEPTION 'retention interval is too short';
  END IF;
  DELETE FROM public.ingest_receipts WHERE received_at < now() - p_older_than;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

CREATE OR REPLACE FUNCTION provision_tenant(
  p_name text,
  p_slug text,
  p_admin_email citext,
  p_admin_name text,
  p_password_hash text,
  p_timezone text DEFAULT 'UTC',
  p_currency char(3) DEFAULT 'USD'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_tenant uuid;
  v_policy uuid;
  v_hours jsonb := '{
    "mon": [["09:00", "17:00"]],
    "tue": [["09:00", "17:00"]],
    "wed": [["09:00", "17:00"]],
    "thu": [["09:00", "17:00"]],
    "fri": [["09:00", "17:00"]]
  }'::jsonb;
  v_targets jsonb := '{
    "urgent": {"response_minutes": 15, "resolution_minutes": 240},
    "high": {"response_minutes": 60, "resolution_minutes": 480},
    "normal": {"response_minutes": 240, "resolution_minutes": 1440},
    "low": {"response_minutes": 480, "resolution_minutes": 4320}
  }'::jsonb;
  v_steps jsonb := '[
    {"after_seconds": 0, "notify": [{"type": "role", "role": "technician"}]},
    {"after_seconds": 900, "notify": [{"type": "role", "role": "tenant_admin"}]}
  ]'::jsonb;
BEGIN
  INSERT INTO tenants (name, slug, timezone, currency_code, status)
  VALUES (p_name, p_slug, p_timezone, p_currency, 'active')
  RETURNING id INTO v_tenant;

  INSERT INTO status_definitions (
    tenant_id, entity_type, key, label, sort_order, category, is_initial, is_terminal, pauses_sla
  ) VALUES
    (v_tenant, 'crm_customer', 'prospect', 'Prospect', 10, 'open', true, false, false),
    (v_tenant, 'crm_customer', 'active', 'Active', 20, 'open', false, false, false),
    (v_tenant, 'crm_customer', 'paused', 'Paused', 30, 'pending', false, false, false),
    (v_tenant, 'crm_customer', 'former', 'Former', 40, 'closed', false, false, false),
    (v_tenant, 'crm_opportunity', 'lead', 'Lead', 10, 'open', true, false, false),
    (v_tenant, 'crm_opportunity', 'qualified', 'Qualified', 20, 'open', false, false, false),
    (v_tenant, 'crm_opportunity', 'proposal', 'Proposal', 30, 'open', false, false, false),
    (v_tenant, 'crm_opportunity', 'negotiation', 'Negotiation', 40, 'open', false, false, false),
    (v_tenant, 'crm_opportunity', 'won', 'Won', 50, 'closed', false, true, false),
    (v_tenant, 'crm_opportunity', 'lost', 'Lost', 60, 'closed', false, true, false),
    (v_tenant, 'crm_order', 'draft', 'Draft', 10, 'open', true, false, false),
    (v_tenant, 'crm_order', 'quoted', 'Quoted', 20, 'open', false, false, false),
    (v_tenant, 'crm_order', 'approved', 'Approved', 30, 'open', false, false, false),
    (v_tenant, 'crm_order', 'active', 'Active', 40, 'open', false, false, false),
    (v_tenant, 'crm_order', 'expired', 'Expired', 50, 'closed', false, true, false),
    (v_tenant, 'crm_order', 'cancelled', 'Cancelled', 60, 'closed', false, true, false),
    (v_tenant, 'crm_ticket', 'new', 'New', 10, 'open', true, false, false),
    (v_tenant, 'crm_ticket', 'triaged', 'Triaged', 20, 'open', false, false, false),
    (v_tenant, 'crm_ticket', 'in_progress', 'In progress', 30, 'open', false, false, false),
    (v_tenant, 'crm_ticket', 'waiting_on_customer', 'Waiting on customer', 40, 'pending', false, false, true),
    (v_tenant, 'crm_ticket', 'waiting_on_vendor', 'Waiting on vendor', 50, 'pending', false, false, true),
    (v_tenant, 'crm_ticket', 'resolved', 'Resolved', 60, 'closed', false, false, false),
    (v_tenant, 'crm_ticket', 'closed', 'Closed', 70, 'closed', false, true, false);

  INSERT INTO status_transitions (tenant_id, entity_type, from_key, to_key, client_allowed) VALUES
    (v_tenant, 'crm_customer', 'prospect', 'active', false),
    (v_tenant, 'crm_customer', 'prospect', 'former', false),
    (v_tenant, 'crm_customer', 'active', 'paused', false),
    (v_tenant, 'crm_customer', 'active', 'former', false),
    (v_tenant, 'crm_customer', 'paused', 'active', false),
    (v_tenant, 'crm_customer', 'paused', 'former', false),
    (v_tenant, 'crm_customer', 'former', 'active', false),
    (v_tenant, 'crm_opportunity', 'lead', 'qualified', false),
    (v_tenant, 'crm_opportunity', 'lead', 'lost', false),
    (v_tenant, 'crm_opportunity', 'qualified', 'proposal', false),
    (v_tenant, 'crm_opportunity', 'qualified', 'lost', false),
    (v_tenant, 'crm_opportunity', 'proposal', 'negotiation', false),
    (v_tenant, 'crm_opportunity', 'proposal', 'won', false),
    (v_tenant, 'crm_opportunity', 'proposal', 'lost', false),
    (v_tenant, 'crm_opportunity', 'negotiation', 'won', false),
    (v_tenant, 'crm_opportunity', 'negotiation', 'lost', false),
    (v_tenant, 'crm_order', 'draft', 'quoted', false),
    (v_tenant, 'crm_order', 'draft', 'cancelled', false),
    (v_tenant, 'crm_order', 'quoted', 'approved', false),
    (v_tenant, 'crm_order', 'quoted', 'draft', false),
    (v_tenant, 'crm_order', 'quoted', 'cancelled', false),
    (v_tenant, 'crm_order', 'approved', 'active', false),
    (v_tenant, 'crm_order', 'approved', 'cancelled', false),
    (v_tenant, 'crm_order', 'active', 'expired', false),
    (v_tenant, 'crm_order', 'active', 'cancelled', false),
    (v_tenant, 'crm_ticket', 'new', 'triaged', false),
    (v_tenant, 'crm_ticket', 'new', 'in_progress', false),
    (v_tenant, 'crm_ticket', 'new', 'waiting_on_customer', false),
    (v_tenant, 'crm_ticket', 'new', 'resolved', false),
    (v_tenant, 'crm_ticket', 'triaged', 'in_progress', false),
    (v_tenant, 'crm_ticket', 'triaged', 'waiting_on_customer', false),
    (v_tenant, 'crm_ticket', 'triaged', 'waiting_on_vendor', false),
    (v_tenant, 'crm_ticket', 'triaged', 'resolved', false),
    (v_tenant, 'crm_ticket', 'in_progress', 'waiting_on_customer', false),
    (v_tenant, 'crm_ticket', 'in_progress', 'waiting_on_vendor', false),
    (v_tenant, 'crm_ticket', 'in_progress', 'resolved', false),
    (v_tenant, 'crm_ticket', 'waiting_on_customer', 'in_progress', false),
    (v_tenant, 'crm_ticket', 'waiting_on_customer', 'resolved', false),
    (v_tenant, 'crm_ticket', 'waiting_on_vendor', 'in_progress', false),
    (v_tenant, 'crm_ticket', 'waiting_on_vendor', 'resolved', false),
    (v_tenant, 'crm_ticket', 'resolved', 'closed', false),
    (v_tenant, 'crm_ticket', 'resolved', 'in_progress', true),
    (v_tenant, 'crm_ticket', 'closed', 'in_progress', true);

  INSERT INTO users (tenant_id, email, full_name, password_hash, role, status, timezone)
  VALUES (v_tenant, p_admin_email, p_admin_name, p_password_hash, 'tenant_admin', 'active', p_timezone);

  INSERT INTO escalation_policies (tenant_id, name, steps)
  VALUES (v_tenant, 'Default escalation', v_steps)
  RETURNING id INTO v_policy;

  INSERT INTO sla_contracts (
    tenant_id, customer_id, escalation_policy_id, name, clock_mode, timezone,
    business_hours, holidays, targets, is_default
  ) VALUES (
    v_tenant, NULL, v_policy, 'Standard business hours', 'business_hours', p_timezone,
    v_hours, '[]'::jsonb, v_targets, true
  );

  INSERT INTO alert_rules (
    tenant_id, node_kind, escalation_policy_id, name, metric_name,
    comparator, threshold, window_seconds, aggregation, severity, cooldown_seconds
  ) VALUES
    (v_tenant, 'ssl_certificate', v_policy, 'SSL certificate under 30 days', 'ssl.days_remaining',
      'lt', 30, 0, 'last', 'warning', 86400),
    (v_tenant, 'ssl_certificate', v_policy, 'SSL certificate under 7 days', 'ssl.days_remaining',
      'lt', 7, 0, 'last', 'critical', 86400);

  INSERT INTO dashboard_layouts (tenant_id, role, name, widgets) VALUES
    (v_tenant, 'tenant_admin', 'Owner', $json$[
      {"id":"node-health","type":"node_health","title":"Node health","grid":{"x":0,"y":0,"w":4,"h":3},"config":{}},
      {"id":"incidents","type":"open_incidents","title":"Open incidents","grid":{"x":4,"y":0,"w":8,"h":3},"config":{}},
      {"id":"sla","type":"sla_risk","title":"SLA risk","grid":{"x":0,"y":3,"w":6,"h":4},"config":{}},
      {"id":"queue","type":"ticket_queue","title":"Ticket queue","grid":{"x":6,"y":3,"w":6,"h":4},"config":{}},
      {"id":"pipeline","type":"pipeline_value","title":"Pipeline","grid":{"x":0,"y":7,"w":4,"h":3},"config":{}},
      {"id":"hours","type":"block_hours","title":"Block hours","grid":{"x":4,"y":7,"w":4,"h":3},"config":{}},
      {"id":"ssl","type":"expiring_ssl","title":"Expiring certificates","grid":{"x":8,"y":7,"w":4,"h":3},"config":{}},
      {"id":"procurement","type":"procurement","title":"Procurement","grid":{"x":0,"y":10,"w":12,"h":3},"config":{}}
    ]$json$::jsonb),
    (v_tenant, 'technician', 'Technician', $json$[
      {"id":"node-health","type":"node_health","title":"Node health","grid":{"x":0,"y":0,"w":4,"h":3},"config":{}},
      {"id":"incidents","type":"open_incidents","title":"Open incidents","grid":{"x":4,"y":0,"w":8,"h":3},"config":{}},
      {"id":"sla","type":"sla_risk","title":"SLA risk","grid":{"x":0,"y":3,"w":6,"h":4},"config":{}},
      {"id":"queue","type":"ticket_queue","title":"Ticket queue","grid":{"x":6,"y":3,"w":6,"h":4},"config":{}},
      {"id":"ssl","type":"expiring_ssl","title":"Expiring certificates","grid":{"x":0,"y":7,"w":12,"h":3},"config":{}}
    ]$json$::jsonb),
    (v_tenant, 'account_manager', 'Account manager', $json$[
      {"id":"pipeline","type":"pipeline_value","title":"Pipeline","grid":{"x":0,"y":0,"w":6,"h":4},"config":{}},
      {"id":"procurement","type":"procurement","title":"Procurement","grid":{"x":6,"y":0,"w":6,"h":4},"config":{}},
      {"id":"hours","type":"block_hours","title":"Block hours","grid":{"x":0,"y":4,"w":6,"h":4},"config":{}},
      {"id":"sla","type":"sla_risk","title":"SLA risk","grid":{"x":6,"y":4,"w":6,"h":4},"config":{}}
    ]$json$::jsonb),
    (v_tenant, 'client_viewer', 'Client', $json$[
      {"id":"queue","type":"ticket_queue","title":"Your tickets","grid":{"x":0,"y":0,"w":7,"h":5},"config":{}},
      {"id":"node-health","type":"node_health","title":"Your sites","grid":{"x":7,"y":0,"w":5,"h":5},"config":{}},
      {"id":"ssl","type":"expiring_ssl","title":"Certificates","grid":{"x":0,"y":5,"w":12,"h":3},"config":{}}
    ]$json$::jsonb);

  RETURN v_tenant;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Grants and ownership
-- ---------------------------------------------------------------------------

GRANT CONNECT ON DATABASE dynamic_crm TO dynamic_crm_runtime;
GRANT CONNECT ON DATABASE dynamic_crm TO dynamic_crm_migrator;
GRANT USAGE ON SCHEMA public TO dynamic_crm_runtime;
GRANT USAGE ON SCHEMA public TO dynamic_crm_migrator;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dynamic_crm_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dynamic_crm_runtime;

REVOKE UPDATE, DELETE ON audit_logs FROM dynamic_crm_runtime;
REVOKE UPDATE, DELETE ON ingest_receipts FROM dynamic_crm_runtime;
REVOKE ALL ON schema_migrations FROM dynamic_crm_runtime;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.sig);
  END LOOP;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO dynamic_crm_runtime;
REVOKE EXECUTE ON FUNCTION provision_tenant(text, text, citext, text, text, text, char) FROM dynamic_crm_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE dynamic_crm_migrator IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO dynamic_crm_migrator', r.tablename);
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO dynamic_crm_migrator', r.sig);
  END LOOP;

  FOR r IN
    SELECT t.typname
    FROM pg_type AS t
    JOIN pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
  LOOP
    EXECUTE format('ALTER TYPE public.%I OWNER TO dynamic_crm_migrator', r.typname);
  END LOOP;
END;
$$;

INSERT INTO schema_migrations (filename) VALUES ('000_roles.sql'), ('001_core.sql');

COMMIT;
