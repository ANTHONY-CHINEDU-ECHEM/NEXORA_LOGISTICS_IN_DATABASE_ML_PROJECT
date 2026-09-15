-- =====================================================================
-- NEXORA LOGISTICS CORPORATION
-- Intelligent Predictive Operations Initiative
-- Use Case A: Fleet, Trailer & Material-Handling Equipment Health Prediction
--
-- PURE IN-DATABASE MACHINE LEARNING PIPELINE (PostgreSQL + PostgresML)
-- Consistent with Business Case Section 7.2 constraint: all training,
-- validation, inference, monitoring, and model storage occur exclusively
-- inside PostgreSQL. Power BI is a read-only consumption layer on top of
-- the views/tables produced here.
--
-- Companion file: nexora_fleet_health_dataset.csv / .xlsx (7,850 rows x
-- 45 columns)
--
-- Tested design target: PostgreSQL 15+ with the PostgresML extension
-- (pgml). Where PostgresML is unavailable, equivalent MADlib calls are
-- noted in comments.
-- =====================================================================


-- =====================================================================
-- SECTION 0 — EXTENSIONS
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgml;      -- PostgresML: pgml.train / pgml.predict
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for audit hashing / row fingerprints


-- =====================================================================
-- SECTION 1 — SCHEMA DESIGN (modular, per Business Case Section 7.5)
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS raw;        -- landing zone for source extracts
CREATE SCHEMA IF NOT EXISTS curated;    -- cleaned, conformed, governed data
CREATE SCHEMA IF NOT EXISTS features;   -- versioned feature tables
CREATE SCHEMA IF NOT EXISTS models;     -- model metadata / model cards
CREATE SCHEMA IF NOT EXISTS predictions;-- scoring outputs
CREATE SCHEMA IF NOT EXISTS monitoring; -- drift & performance tracking
CREATE SCHEMA IF NOT EXISTS bi;         -- Power BI-facing semantic views


-- =====================================================================
-- SECTION 2 — RAW LANDING TABLE (mirrors the Excel/CSV export exactly)
-- =====================================================================
DROP TABLE IF EXISTS raw.fleet_health_snapshot CASCADE;

CREATE TABLE raw.fleet_health_snapshot (
    asset_id                                TEXT PRIMARY KEY,
    asset_type                              TEXT NOT NULL,
    asset_subtype_model                     TEXT,
    manufacturer                            TEXT,
    region                                  TEXT,
    depot_location                          TEXT,
    in_service_date                         DATE,
    asset_age_years                         NUMERIC(6,2),
    purchase_cost_usd                       NUMERIC(12,2),
    current_odometer_miles                  NUMERIC(12,0),
    current_engine_hours                    NUMERIC(12,0),
    fuel_type                               TEXT,
    avg_daily_miles_last_30d                NUMERIC(10,1),
    avg_daily_hours_last_30d                NUMERIC(8,2),
    utilization_rate_pct                    NUMERIC(5,1),
    total_trips_last_90d                    INTEGER,
    total_idle_hours_last_30d               NUMERIC(8,1),
    load_factor_pct                         NUMERIC(5,1),
    route_type                              TEXT,
    total_maintenance_events_lifetime       INTEGER,
    scheduled_maintenance_count_last_12m    INTEGER,
    unscheduled_repair_count_last_12m       INTEGER,
    days_since_last_maintenance             NUMERIC(8,0),
    days_since_last_major_repair            NUMERIC(8,0),
    avg_repair_cost_last_12m_usd            NUMERIC(12,2),
    total_maintenance_cost_lifetime_usd     NUMERIC(14,2),
    last_maintenance_type                   TEXT,
    open_recall_flag                        CHAR(1),
    active_fault_code_count                 INTEGER,
    critical_fault_code_flag                CHAR(1),
    engine_temp_avg_last_30d_f              NUMERIC(6,1),
    oil_pressure_avg_psi                    NUMERIC(6,1),
    battery_voltage_avg                     NUMERIC(5,2),
    brake_wear_pct                          NUMERIC(5,1),
    tire_tread_depth_mm                     NUMERIC(5,2),
    vibration_index                         NUMERIC(5,2),
    telematics_data_completeness_pct        NUMERIC(5,1),
    driver_assigned_count_last_90d          INTEGER,
    weather_exposure_index                  NUMERIC(5,2),
    cargo_weight_avg_lbs                    NUMERIC(10,0),
    inspection_pass_rate_pct_last_12m       NUMERIC(5,1),
    downtime_events_last_12m                INTEGER,
    downtime_hours_last_12m                 NUMERIC(10,1),
    failure_within_30d                      SMALLINT,
    days_to_next_failure_or_censor          NUMERIC(6,0),
    load_batch_id                           BIGINT,
    loaded_at                               TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE raw.fleet_health_snapshot IS
  'Landing table for Use Case A fleet-health source extract. One row per asset per snapshot date. Loaded via COPY from the governed CSV export.';

-- ---------------------------------------------------------------------
-- Load command (run from psql, adjust path to your local copy of the CSV)
-- ---------------------------------------------------------------------
-- \copy raw.fleet_health_snapshot(asset_id, asset_type, asset_subtype_model, manufacturer, region,
--   depot_location, in_service_date, asset_age_years, purchase_cost_usd, current_odometer_miles,
--   current_engine_hours, fuel_type, avg_daily_miles_last_30d, avg_daily_hours_last_30d,
--   utilization_rate_pct, total_trips_last_90d, total_idle_hours_last_30d, load_factor_pct,
--   route_type, total_maintenance_events_lifetime, scheduled_maintenance_count_last_12m,
--   unscheduled_repair_count_last_12m, days_since_last_maintenance, days_since_last_major_repair,
--   avg_repair_cost_last_12m_usd, total_maintenance_cost_lifetime_usd, last_maintenance_type,
--   open_recall_flag, active_fault_code_count, critical_fault_code_flag, engine_temp_avg_last_30d_f,
--   oil_pressure_avg_psi, battery_voltage_avg, brake_wear_pct, tire_tread_depth_mm, vibration_index,
--   telematics_data_completeness_pct, driver_assigned_count_last_90d, weather_exposure_index,
--   cargo_weight_avg_lbs, inspection_pass_rate_pct_last_12m, downtime_events_last_12m,
--   downtime_hours_last_12m, failure_within_30d, days_to_next_failure_or_censor)
-- FROM 'nexora_fleet_health_dataset.csv' WITH (FORMAT csv, HEADER true);


-- =====================================================================
-- SECTION 3 — MASTER DATA / REFERENCE TABLES (Business Case Section 7.1)
-- =====================================================================
CREATE TABLE IF NOT EXISTS curated.dim_asset_type (
    asset_type   TEXT PRIMARY KEY,
    asset_class  TEXT NOT NULL   -- 'Motorized-Road', 'Non-Motorized', 'Material-Handling'
);
INSERT INTO curated.dim_asset_type (asset_type, asset_class) VALUES
    ('Tractor','Motorized-Road'), ('Delivery Van','Motorized-Road'), ('Yard Truck','Motorized-Road'),
    ('Trailer','Non-Motorized'), ('Forklift','Material-Handling'), ('Conveyor/Sorter','Material-Handling')
ON CONFLICT (asset_type) DO NOTHING;


-- =====================================================================
-- SECTION 4 — DATA QUALITY FRAMEWORK (Business Case Section 7.1)
-- Automated completeness / validity / referential-integrity checks with
-- quarantine table and a scheduled job stub.
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitoring.dq_quarantine (
    quarantine_id   BIGSERIAL PRIMARY KEY,
    asset_id        TEXT,
    rule_violated   TEXT,
    detail          TEXT,
    quarantined_at  TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE FUNCTION monitoring.run_data_quality_checks()
RETURNS TABLE(rule_violated TEXT, violation_count BIGINT) AS $$
BEGIN
    -- Rule 1: completeness on mandatory identifiers
    INSERT INTO monitoring.dq_quarantine (asset_id, rule_violated, detail)
    SELECT asset_id, 'missing_asset_type', 'asset_type is null'
    FROM raw.fleet_health_snapshot WHERE asset_type IS NULL;

    -- Rule 2: validity — utilization and percentage fields must be 0-100
    INSERT INTO monitoring.dq_quarantine (asset_id, rule_violated, detail)
    SELECT asset_id, 'invalid_utilization_pct', utilization_rate_pct::TEXT
    FROM raw.fleet_health_snapshot
    WHERE utilization_rate_pct < 0 OR utilization_rate_pct > 100;

    -- Rule 3: uniqueness of asset_id (defence in depth beyond the PK)
    INSERT INTO monitoring.dq_quarantine (asset_id, rule_violated, detail)
    SELECT asset_id, 'duplicate_asset_id', 'count>1'
    FROM (SELECT asset_id, COUNT(*) c FROM raw.fleet_health_snapshot GROUP BY asset_id HAVING COUNT(*) > 1) d;

    -- Rule 4: referential integrity — asset_type must exist in dimension
    INSERT INTO monitoring.dq_quarantine (asset_id, rule_violated, detail)
    SELECT s.asset_id, 'unknown_asset_type', s.asset_type
    FROM raw.fleet_health_snapshot s
    LEFT JOIN curated.dim_asset_type d ON d.asset_type = s.asset_type
    WHERE d.asset_type IS NULL;

    RETURN QUERY
    SELECT q.rule_violated, COUNT(*)::BIGINT
    FROM monitoring.dq_quarantine q
    WHERE q.quarantined_at > now() - INTERVAL '1 hour'
    GROUP BY q.rule_violated;
END;
$$ LANGUAGE plpgsql;

-- Run once after each load: SELECT * FROM monitoring.run_data_quality_checks();


-- =====================================================================
-- SECTION 5 — CURATED TABLE (cleaned, typed, partitioned by snapshot date)
-- Partitioning is declared for multi-year historical depth per Section 7.1;
-- with a single historical load, only the initial partition is created.
-- =====================================================================
CREATE TABLE IF NOT EXISTS curated.fleet_health (
    LIKE raw.fleet_health_snapshot INCLUDING DEFAULTS,
    snapshot_date DATE NOT NULL DEFAULT DATE '2026-09-01'
) PARTITION BY RANGE (snapshot_date);

CREATE TABLE IF NOT EXISTS curated.fleet_health_2026h2
    PARTITION OF curated.fleet_health
    FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');

INSERT INTO curated.fleet_health
SELECT s.*, DATE '2026-09-01'
FROM raw.fleet_health_snapshot s
WHERE NOT EXISTS (SELECT 1 FROM monitoring.dq_quarantine q WHERE q.asset_id = s.asset_id);

CREATE INDEX IF NOT EXISTS idx_fleet_health_asset_type ON curated.fleet_health (asset_type);
CREATE INDEX IF NOT EXISTS idx_fleet_health_region ON curated.fleet_health (region);
CREATE INDEX IF NOT EXISTS idx_fleet_health_snapshot ON curated.fleet_health (snapshot_date);


-- =====================================================================
-- SECTION 6 — FEATURE ENGINEERING (pure SQL: window functions, CTEs)
-- Materialized into a versioned feature table, per Section 7.2.
-- =====================================================================
DROP TABLE IF EXISTS features.fleet_health_features_v1;

CREATE TABLE features.fleet_health_features_v1 AS
WITH base AS (
    SELECT
        f.*,
        d.asset_class,
        -- Encode categoricals PostgresML can consume as numeric features
        CASE f.open_recall_flag        WHEN 'Y' THEN 1 ELSE 0 END AS open_recall_flag_num,
        CASE f.critical_fault_code_flag WHEN 'Y' THEN 1 ELSE 0 END AS critical_fault_flag_num,
        -- Ratios / engineered signals
        ROUND(f.unscheduled_repair_count_last_12m::NUMERIC
              / NULLIF(f.total_maintenance_events_lifetime, 0), 3)      AS unscheduled_repair_ratio,
        ROUND(f.avg_repair_cost_last_12m_usd
              / NULLIF(f.purchase_cost_usd, 0), 4)                      AS repair_cost_to_asset_value_ratio,
        ROUND(f.downtime_hours_last_12m
              / NULLIF(f.total_trips_last_90d, 0), 3)                   AS downtime_per_trip,
        ROUND(f.active_fault_code_count::NUMERIC
              / NULLIF(f.asset_age_years, 0), 3)                        AS fault_codes_per_age_year,
        -- Cohort z-score of fault codes vs. same asset_type (window function)
        ROUND((f.active_fault_code_count -
               AVG(f.active_fault_code_count) OVER (PARTITION BY f.asset_type)) /
               NULLIF(STDDEV(f.active_fault_code_count) OVER (PARTITION BY f.asset_type), 0), 3)
                                                                          AS fault_codes_z_within_type,
        NTILE(5) OVER (ORDER BY f.days_since_last_maintenance DESC)     AS maintenance_recency_quintile
    FROM curated.fleet_health f
    LEFT JOIN curated.dim_asset_type d ON d.asset_type = f.asset_type
)
SELECT * FROM base;

ALTER TABLE features.fleet_health_features_v1 ADD PRIMARY KEY (asset_id);

COMMENT ON TABLE features.fleet_health_features_v1 IS
  'Version 1 feature table for Use Case A. Built entirely in SQL (CTEs + window functions) from curated.fleet_health. Feeds pgml.train directly.';


-- =====================================================================
-- SECTION 7 — TRAIN / VALIDATION SPLIT (temporal-safe, expressible in SQL)
-- Since this is a single snapshot, split is randomized but reproducible
-- via a deterministic hash of asset_id (stand-in for a true temporal split
-- once multiple snapshot dates exist).
-- =====================================================================
ALTER TABLE features.fleet_health_features_v1
  ADD COLUMN IF NOT EXISTS data_split TEXT;

UPDATE features.fleet_health_features_v1
SET data_split = CASE
    WHEN ('x' || md5(asset_id))::bit(32)::int % 100 < 70 THEN 'train'
    WHEN ('x' || md5(asset_id))::bit(32)::int % 100 < 85 THEN 'validation'
    ELSE 'test'
END;


-- =====================================================================
-- SECTION 8 — IN-DATABASE MODEL TRAINING (PostgresML)
-- Algorithm choice: gradient-boosted trees (xgboost), matching the
-- Business-Case-approved algorithm family (Section 7.2).
-- =====================================================================
SELECT pgml.train(
    project_name    => 'nexora_fleet_failure_30d',
    task            => 'classification',
    relation_name   => 'features.fleet_health_features_v1',
    y_column_name   => 'failure_within_30d',
    algorithm       => 'xgboost',
    hyperparams     => '{
        "n_estimators": 300,
        "max_depth": 6,
        "learning_rate": 0.05,
        "subsample": 0.8,
        "colsample_bytree": 0.8
    }'::jsonb,
    test_size       => 0.15,
    test_sampling   => 'random'
);

-- Optional challenger model for comparison (regularized logistic regression)
SELECT pgml.train(
    project_name    => 'nexora_fleet_failure_30d',
    task            => 'classification',
    relation_name   => 'features.fleet_health_features_v1',
    y_column_name   => 'failure_within_30d',
    algorithm       => 'linear',
    hyperparams     => '{"penalty": "l2"}'::jsonb,
    test_size       => 0.15,
    test_sampling   => 'random'
);

-- Inspect trained model performance:
-- SELECT * FROM pgml.overview WHERE project_name = 'nexora_fleet_failure_30d';


-- =====================================================================
-- SECTION 9 — MODEL CARD (structured metadata, Business Case Section 7.2)
-- =====================================================================
CREATE TABLE IF NOT EXISTS models.model_card (
    model_id                BIGSERIAL PRIMARY KEY,
    project_name            TEXT NOT NULL,
    model_version           TEXT NOT NULL,
    algorithm                TEXT NOT NULL,
    training_data_summary    TEXT,
    hyperparameters           JSONB,
    performance_metrics       JSONB,
    intended_use              TEXT,
    known_limitations         TEXT,
    trained_at                TIMESTAMPTZ DEFAULT now(),
    approved_by               TEXT,
    risk_classification        TEXT  -- 'Standard' | 'Elevated' per Section 7.4
);

INSERT INTO models.model_card
(project_name, model_version, algorithm, training_data_summary, hyperparameters,
 performance_metrics, intended_use, known_limitations, risk_classification)
VALUES (
    'nexora_fleet_failure_30d', 'v1_xgboost',
    'xgboost (gradient-boosted trees)',
    '7,850 assets, 45 source attributes, snapshot date 2026-09-01, 70/15/15 train/validation/test split',
    '{"n_estimators":300,"max_depth":6,"learning_rate":0.05,"subsample":0.8,"colsample_bytree":0.8}'::jsonb,
    '{"note":"populate from pgml.overview / pgml.predict against the test split after training"}'::jsonb,
    'Ranks fleet, trailer, and MHE assets by 30-day failure risk to prioritize maintenance planning and inspection scheduling. Not a sole basis for safety-critical decisions.',
    'Trained on a single synthetic snapshot; retrain on rolling real production data before go-live. Elevated-risk asset classes (safety-critical failures) require human review per Section 7.2.',
    'Elevated'
);


-- =====================================================================
-- SECTION 10 — SCORING / INFERENCE (predictions written back to PostgreSQL)
-- =====================================================================
CREATE TABLE IF NOT EXISTS predictions.fleet_failure_scores (
    asset_id                TEXT PRIMARY KEY REFERENCES curated.fleet_health(asset_id) ON DELETE CASCADE,
    model_version            TEXT NOT NULL,
    predicted_probability     NUMERIC(6,5),
    predicted_class            SMALLINT,
    risk_tier                  TEXT,
    top_contributing_feature   TEXT,
    scored_at                  TIMESTAMPTZ DEFAULT now()
);

INSERT INTO predictions.fleet_failure_scores
    (asset_id, model_version, predicted_probability, predicted_class, risk_tier)
SELECT
    f.asset_id,
    'v1_xgboost',
    pgml.predict('nexora_fleet_failure_30d', f.*)::NUMERIC(6,5)               AS predicted_probability,
    ROUND(pgml.predict('nexora_fleet_failure_30d', f.*))::SMALLINT            AS predicted_class,
    CASE
        WHEN pgml.predict('nexora_fleet_failure_30d', f.*) >= 0.60 THEN 'Critical'
        WHEN pgml.predict('nexora_fleet_failure_30d', f.*) >= 0.35 THEN 'High'
        WHEN pgml.predict('nexora_fleet_failure_30d', f.*) >= 0.15 THEN 'Medium'
        ELSE 'Low'
    END AS risk_tier
FROM features.fleet_health_features_v1 f
ON CONFLICT (asset_id) DO UPDATE SET
    model_version = EXCLUDED.model_version,
    predicted_probability = EXCLUDED.predicted_probability,
    predicted_class = EXCLUDED.predicted_class,
    risk_tier = EXCLUDED.risk_tier,
    scored_at = now();

-- NOTE: pgml.predict's exact call signature (row vs. array of feature
-- values) depends on your installed PostgresML version — see the
-- pgml.predict documentation for your instance and adjust the SELECT
-- list of feature columns accordingly if row-type prediction is not
-- supported in your version.


-- =====================================================================
-- SECTION 11 — MONITORING: DATA DRIFT & PERFORMANCE DEGRADATION (pure SQL)
-- =====================================================================
CREATE TABLE IF NOT EXISTS monitoring.feature_drift_log (
    check_id        BIGSERIAL PRIMARY KEY,
    feature_name    TEXT,
    baseline_mean   NUMERIC,
    current_mean    NUMERIC,
    pct_change      NUMERIC,
    drift_flag      BOOLEAN,
    checked_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS monitoring.feature_baseline (
    feature_name  TEXT PRIMARY KEY,
    baseline_mean NUMERIC
);

INSERT INTO monitoring.feature_baseline (feature_name, baseline_mean)
SELECT 'active_fault_code_count', AVG(active_fault_code_count) FROM features.fleet_health_features_v1
ON CONFLICT (feature_name) DO UPDATE SET baseline_mean = EXCLUDED.baseline_mean;

INSERT INTO monitoring.feature_baseline (feature_name, baseline_mean)
SELECT 'days_since_last_maintenance', AVG(days_since_last_maintenance) FROM features.fleet_health_features_v1
ON CONFLICT (feature_name) DO UPDATE SET baseline_mean = EXCLUDED.baseline_mean;

CREATE OR REPLACE FUNCTION monitoring.check_feature_drift(threshold_pct NUMERIC DEFAULT 15.0)
RETURNS VOID AS $$
DECLARE
    r RECORD;
    cur_mean NUMERIC;
    pct NUMERIC;
BEGIN
    FOR r IN SELECT * FROM monitoring.feature_baseline LOOP
        EXECUTE format('SELECT AVG(%I) FROM features.fleet_health_features_v1', r.feature_name)
            INTO cur_mean;
        pct := ROUND(100.0 * (cur_mean - r.baseline_mean) / NULLIF(r.baseline_mean, 0), 2);
        INSERT INTO monitoring.feature_drift_log (feature_name, baseline_mean, current_mean, pct_change, drift_flag)
        VALUES (r.feature_name, r.baseline_mean, cur_mean, pct, ABS(pct) > threshold_pct);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Schedule after each new snapshot load: SELECT monitoring.check_feature_drift();

CREATE TABLE IF NOT EXISTS monitoring.prediction_distribution_log (
    log_id            BIGSERIAL PRIMARY KEY,
    risk_tier         TEXT,
    asset_count       BIGINT,
    avg_probability   NUMERIC(6,5),
    logged_at         TIMESTAMPTZ DEFAULT now()
);

INSERT INTO monitoring.prediction_distribution_log (risk_tier, asset_count, avg_probability)
SELECT risk_tier, COUNT(*), ROUND(AVG(predicted_probability), 5)
FROM predictions.fleet_failure_scores
GROUP BY risk_tier;


-- =====================================================================
-- SECTION 12 — HUMAN-IN-THE-LOOP OVERRIDE CAPTURE (Section 7.2)
-- =====================================================================
CREATE TABLE IF NOT EXISTS predictions.human_review_feedback (
    review_id         BIGSERIAL PRIMARY KEY,
    asset_id          TEXT REFERENCES curated.fleet_health(asset_id),
    reviewer_name     TEXT,
    model_predicted_class SMALLINT,
    reviewer_override_class SMALLINT,
    override_reason   TEXT,
    reviewed_at       TIMESTAMPTZ DEFAULT now()
);
-- This table is the closed-loop feedback source for future retraining
-- cycles (Section 7.2: "feedback available for subsequent training cycles").


-- =====================================================================
-- SECTION 13 — SEMANTIC LAYER FOR POWER BI (bi schema; consumption-only)
-- =====================================================================
CREATE OR REPLACE VIEW bi.vw_asset_risk_overview AS
SELECT
    f.asset_id, f.asset_type, f.manufacturer, f.region, f.depot_location,
    f.route_type, f.asset_age_years, f.utilization_rate_pct,
    f.active_fault_code_count, f.critical_fault_code_flag, f.open_recall_flag,
    f.unscheduled_repair_count_last_12m, f.days_since_last_maintenance,
    f.downtime_hours_last_12m, f.total_maintenance_cost_lifetime_usd,
    p.predicted_probability, p.predicted_class, p.risk_tier, p.model_version, p.scored_at,
    f.failure_within_30d AS actual_failure_within_30d   -- retained for backtesting/model-quality visuals
FROM curated.fleet_health f
LEFT JOIN predictions.fleet_failure_scores p ON p.asset_id = f.asset_id;

CREATE OR REPLACE VIEW bi.vw_risk_tier_summary AS
SELECT region, asset_type, risk_tier, COUNT(*) AS asset_count,
       ROUND(AVG(predicted_probability), 4) AS avg_predicted_probability
FROM bi.vw_asset_risk_overview
GROUP BY region, asset_type, risk_tier;

CREATE OR REPLACE VIEW bi.vw_model_quality_backtest AS
SELECT
    model_version,
    COUNT(*) AS scored_assets,
    SUM(CASE WHEN predicted_class = actual_failure_within_30d THEN 1 ELSE 0 END)::NUMERIC
        / COUNT(*) AS accuracy,
    SUM(CASE WHEN predicted_class = 1 AND actual_failure_within_30d = 1 THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(SUM(CASE WHEN predicted_class = 1 THEN 1 ELSE 0 END), 0) AS precision,
    SUM(CASE WHEN predicted_class = 1 AND actual_failure_within_30d = 1 THEN 1 ELSE 0 END)::NUMERIC
        / NULLIF(SUM(CASE WHEN actual_failure_within_30d = 1 THEN 1 ELSE 0 END), 0) AS recall
FROM bi.vw_asset_risk_overview
GROUP BY model_version;

CREATE OR REPLACE VIEW bi.vw_data_quality_summary AS
SELECT rule_violated, COUNT(*) AS violation_count, MAX(quarantined_at) AS last_seen
FROM monitoring.dq_quarantine
GROUP BY rule_violated;

CREATE OR REPLACE VIEW bi.vw_drift_monitor AS
SELECT feature_name, baseline_mean, current_mean, pct_change, drift_flag, checked_at
FROM monitoring.feature_drift_log;

-- Grant read-only access to the Power BI service account (adjust role name):
-- CREATE ROLE powerbi_reader LOGIN PASSWORD '<use a secrets manager, not plaintext>';
-- GRANT USAGE ON SCHEMA bi TO powerbi_reader;
-- GRANT SELECT ON ALL TABLES IN SCHEMA bi TO powerbi_reader;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA bi GRANT SELECT ON TABLES TO powerbi_reader;


-- =====================================================================
-- SECTION 14 — SCHEDULED RETRAINING TRIGGER STUB (pg_cron)
-- Requires the pg_cron extension; illustrates threshold-based retraining
-- per Section 7.2 ("retraining triggered by scheduled SQL jobs or simple
-- threshold-based conditions").
-- =====================================================================
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('nexora_weekly_drift_check', '0 3 * * 1',
--     $$ SELECT monitoring.check_feature_drift(); $$);
-- SELECT cron.schedule('nexora_monthly_retrain_check', '0 4 1 * *',
--     $$ SELECT pgml.train(project_name => 'nexora_fleet_failure_30d',
--                           task => 'classification',
--                           relation_name => 'features.fleet_health_features_v1',
--                           y_column_name => 'failure_within_30d',
--                           algorithm => 'xgboost'); $$);

-- =====================================================================
-- END OF SCRIPT
-- =====================================================================
