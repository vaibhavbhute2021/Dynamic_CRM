-- script: 003_native_partition.sql
-- ALTERNATIVE physical design for telemetry_metrics when TimescaleDB cannot
-- be installed. Do not run this on a database where 001_core.sql already
-- created telemetry_metrics, and do not combine it with 002_timescale.sql.
--
-- Replace the telemetry_metrics section of 001_core.sql with this definition
-- BEFORE any metric rows are loaded. The application read path uses
-- date_trunc on telemetry_metrics when telemetry_1m does not exist.

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
) PARTITION BY RANGE (recorded_at);

CREATE TABLE telemetry_metrics_default PARTITION OF telemetry_metrics DEFAULT;

CREATE OR REPLACE FUNCTION ensure_telemetry_month(p_month date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_start timestamptz;
  v_end timestamptz;
  v_name text;
BEGIN
  v_start := date_trunc('month', p_month::timestamptz);
  v_end := v_start + INTERVAL '1 month';
  v_name := 'telemetry_metrics_' || to_char(v_start, 'YYYY_MM');
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS %I PARTITION OF telemetry_metrics FOR VALUES FROM (%L) TO (%L)',
    v_name, v_start, v_end
  );
END;
$$;

SELECT ensure_telemetry_month((date_trunc('month', now()))::date);
SELECT ensure_telemetry_month((date_trunc('month', now()) + INTERVAL '1 month')::date);
SELECT ensure_telemetry_month((date_trunc('month', now()) + INTERVAL '2 months')::date);

CREATE INDEX telemetry_metrics_node_metric_time_idx
  ON telemetry_metrics (tenant_id, node_id, metric_name, recorded_at DESC);
