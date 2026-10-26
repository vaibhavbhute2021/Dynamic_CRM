-- script: 002_timescale.sql
-- Production telemetry physical design. Run after 001_core.sql as a superuser
-- on a server where TimescaleDB is installed. Do not run 003_native_partition.sql
-- if this script has been applied.
--
-- Some Timescale procedures commit on their own. Keep this file out of a
-- surrounding transaction.

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Classic signature, still supported alongside by_range() on TimescaleDB 2.17.
SELECT create_hypertable(
  'telemetry_metrics',
  'recorded_at',
  chunk_time_interval => INTERVAL '1 day',
  if_not_exists => true,
  migrate_data => true
);

ALTER TABLE telemetry_metrics SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'tenant_id, node_id, metric_name',
  timescaledb.compress_orderby = 'recorded_at DESC'
);

SELECT add_compression_policy(
  'telemetry_metrics',
  INTERVAL '7 days',
  if_not_exists => true
);

SELECT add_retention_policy(
  'telemetry_metrics',
  INTERVAL '400 days',
  if_not_exists => true
);

CREATE MATERIALIZED VIEW telemetry_1m
WITH (timescaledb.continuous) AS
SELECT
  time_bucket(INTERVAL '1 minute', recorded_at) AS bucket,
  tenant_id,
  node_id,
  metric_name,
  avg(value) AS avg_value,
  min(value) AS min_value,
  max(value) AS max_value,
  count(*) AS sample_count
FROM telemetry_metrics
GROUP BY
  time_bucket(INTERVAL '1 minute', recorded_at),
  tenant_id,
  node_id,
  metric_name
WITH NO DATA;

SELECT add_continuous_aggregate_policy(
  'telemetry_1m',
  start_offset => INTERVAL '2 hours',
  end_offset => INTERVAL '1 minute',
  schedule_interval => INTERVAL '1 minute',
  if_not_exists => true
);

-- Continuous aggregates cannot carry row-level security. The runtime role
-- reaches buckets only through this function, which requires the transaction
-- tenant setting to match the requested tenant.
CREATE OR REPLACE FUNCTION read_metric_buckets(
  p_tenant_id uuid,
  p_node_id uuid,
  p_metric_name text,
  p_from timestamptz,
  p_to timestamptz
) RETURNS TABLE (
  bucket timestamptz,
  avg_value double precision,
  min_value double precision,
  max_value double precision,
  sample_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF current_setting('app.tenant_id', true) IS NULL
     OR current_setting('app.tenant_id', true)::uuid IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'tenant context mismatch';
  END IF;

  RETURN QUERY
  SELECT
    t.bucket,
    t.avg_value,
    t.min_value,
    t.max_value,
    t.sample_count
  FROM public.telemetry_1m AS t
  WHERE t.tenant_id = p_tenant_id
    AND t.node_id = p_node_id
    AND t.metric_name = p_metric_name
    AND t.bucket >= p_from
    AND t.bucket < p_to
  ORDER BY t.bucket;
END;
$$;

REVOKE ALL ON FUNCTION read_metric_buckets(uuid, uuid, text, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION read_metric_buckets(uuid, uuid, text, timestamptz, timestamptz) TO dynamic_crm_runtime;
REVOKE ALL ON TABLE telemetry_1m FROM dynamic_crm_runtime;

ALTER FUNCTION read_metric_buckets(uuid, uuid, text, timestamptz, timestamptz)
  OWNER TO dynamic_crm_migrator;
