**COMPREHENSIVE CURRENT STATE PROBLEM ANALYSIS**


The dominant decision paradigm across Nexora’s network remains reactive or only lightly anticipatory. Equipment health is monitored primarily through fault codes, scheduled inspections, and run-to-failure or interval-based maintenance. Demand and inventory planning rely on statistical forecasts that are refreshed on fixed cadences and that struggle to incorporate real-time signals of promotional activity, weather, or upstream supply disruption. 

Transit-time performance is examined after the fact through lane-level averages rather than through full distributional and risk-aware predictions. Package condition is assessed largely through post-delivery claims. Carrier performance is scored retrospectively on lagged on-time and damage metrics.These practices produce five tightly interdependent categories of quantifiable pain.First, unplanned equipment failures of tractors, trailers, material-handling equipment, and sortation systems generate direct repair costs, secondary network disruption, overtime, and service failures. Because remaining useful life and short-horizon failure probability are not systematically predicted, maintenance resources cannot be positioned proactively and critical assets are often allowed to operate until failure occurs.

Second, multi-horizon demand forecast inaccuracy at SKU-location and network-node level drives both out-of-stock events that damage customer experience and excess inventory that ties up working capital and warehouse capacity. Static or slowly adapting forecasts cannot keep pace with the velocity and volatility of modern fulfilment demand.

Third, delivery-time variability across the corridor network remains only partially characterised. Without forward-looking, distribution-aware, and risk-factor-informed predictions, transportation planners cannot proactively adjust routes, mode choices, or customer promises, resulting in avoidable SLA breaches and customer dissatisfaction.

Fourth, package damage, shortage, and condition issues are detected predominantly after the fact. High-density sortation paths, repeated handling, and vibration exposure create predictable risk concentrations that are not scored in advance, allowing claims cost and customer friction to accumulate.

Fifth, carrier, broker, and partner performance is monitored retrospectively. Early indicators of rising delay risk, capacity constraint, or quality deterioration are not aggregated into dynamic risk scores, so intervention occurs only after service leakage has already materialised.

These five problem clusters reinforce one another. Equipment downtime reduces network capacity and amplifies delivery-time risk. Forecast error creates inventory imbalances that increase handling intensity and damage probability. Carrier under-performance compounds transit-time variability. The absence of a unified, governed predictive layer leaves each function optimising locally while the global cost-to-serve and service reliability of the network continue to erode.


**SOLUTION VISION, DESIGN PRINCIPLES AND ARCHITECTURAL INTENT**

The Intelligent Predictive Operations Initiative establishes a single, high-integrity, fully governed analytical data foundation that consolidates curated operational telemetry, fleet and asset health records, inventory and demand histories, shipment and handling events, quality and claims data, carrier performance metrics, and external context (weather, traffic, port status) exclusively inside PostgreSQL. Upon that foundation the program develops, independently validates where risk classification requires, deploys, and continuously monitors predictive models realised entirely through algorithms and functions natively supported by PostgreSQL machine-learning extensions. All predictions, uncertainty estimates, feature-importance explanations, and monitoring statistics are written back into PostgreSQL tables and surfaced exclusively through role-specific Power BI decision-support environments. 

Hard reliability interlocks, human-in-the-loop overrides, and full auditability are non-negotiable design invariants. Algorithms inform and prioritise; authorised personnel retain final decision authority within immutable operational bounds.The initiative is deliberately conceived as a reusable enterprise platform rather than a collection of isolated point solutions. Every early use case is required to leave behind versioned data products, feature tables, model-lifecycle patterns, safety and reliability templates, and decision interfaces that accelerate every subsequent use case and future extensions into network-wide optimisation or autonomous exception handling.Guiding design principles include platform orientation, primacy of asset reliability, customer experience, and auditability, deliberate human-in-the-loop and supervised autonomy, closed-loop intent with graceful degradation, incremental value-driven delivery, and governance embedded from day one. 

The absolute technology constraint is that all storage, feature engineering, model training and updating, inference, monitoring, lineage, and audit logging occur exclusively inside PostgreSQL; Power BI is the sole visualisation, exploration, and interaction layer; no external machine-learning platforms, notebooks for production scoring, or non-PostgreSQL model engines are permitted.

The architectural intent is a cleanly layered structure: a curated analytical data foundation inside PostgreSQL; a feature and label engineering layer; a model training, versioning, and inference layer using supported extensions; a prediction, explanation, and monitoring service layer implemented as PostgreSQL functions and tables; and a consumption layer of role-tailored Power BI environments reading exclusively from governed PostgreSQL artefacts, all under unified security, lineage, and operational monitoring.


-- =====================================================================
-- NEXORA LOGISTICS CORPORATION
-- Intelligent Predictive Operations Initiative
-- Use Case A: Fleet, Trailer & Material-Handling Equipment Health Prediction
-- PURE IN-DATABASE MACHINE LEARNING PIPELINE (PostgreSQL + PostgresML)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgml;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Modular Schema Architecture per Business Case Section 7.5
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS curated;
CREATE SCHEMA IF NOT EXISTS features;
CREATE SCHEMA IF NOT EXISTS models;
CREATE SCHEMA IF NOT EXISTS predictions;
CREATE SCHEMA IF NOT EXISTS monitoring;
CREATE SCHEMA IF NOT EXISTS bi;

-- Reference Dimension Table
CREATE TABLE IF NOT EXISTS curated.dim_asset_type (
    asset_type   TEXT PRIMARY KEY,
    asset_class  TEXT NOT NULL
);
INSERT INTO curated.dim_asset_type (asset_type, asset_class) VALUES
    ('Tractor','Motorized-Road'), ('Delivery Van','Motorized-Road'), ('Yard Truck','Motorized-Road'),
    ('Trailer','Non-Motorized'), ('Forklift','Material-Handling'), ('Conveyor/Sorter','Material-Handling')
ON CONFLICT (asset_type) DO NOTHING;

-- Data Quality Automated Validation & Quarantine
CREATE TABLE IF NOT EXISTS monitoring.dq_quarantine (
    quarantine_id   BIGSERIAL PRIMARY KEY,
    asset_id        TEXT,
    rule_violated   TEXT,
    detail          TEXT,
    quarantined_at  TIMESTAMPTZ DEFAULT now()
);

-- Feature Engineering (Pure SQL window functions & aggregations)
DROP TABLE IF EXISTS features.fleet_health_features_v1 CASCADE;
CREATE TABLE features.fleet_health_features_v1 AS
SELECT
    f.*,
    d.asset_class,
    CASE f.open_recall_flag WHEN 'Y' THEN 1 ELSE 0 END AS open_recall_flag_num,
    CASE f.critical_fault_code_flag WHEN 'Y' THEN 1 ELSE 0 END AS critical_fault_flag_num,
    ROUND(f.unscheduled_repair_count_last_12m::NUMERIC / NULLIF(f.total_maintenance_events_lifetime, 0), 3) AS unscheduled_repair_ratio,
    ROUND(f.avg_repair_cost_last_12m_usd / NULLIF(f.purchase_cost_usd, 0), 4) AS repair_cost_to_asset_value_ratio,
    ROUND((f.active_fault_code_count - AVG(f.active_fault_code_count) OVER (PARTITION BY f.asset_type)) /
           NULLIF(STDDEV(f.active_fault_code_count) OVER (PARTITION BY f.asset_type), 0), 3) AS fault_codes_z_within_type
FROM curated.fleet_health f
LEFT JOIN curated.dim_asset_type d ON d.asset_type = f.asset_type;

ALTER TABLE features.fleet_health_features_v1 ADD PRIMARY KEY (asset_id);

-- In-Database Model Training via PostgresML (XGBoost)
SELECT pgml.train(
    project_name    => 'nexora_fleet_failure_30d',
    task            => 'classification',
    relation_name   => 'features.fleet_health_features_v1',
    y_column_name   => 'failure_within_30d',
    algorithm       => 'xgboost',
    hyperparams     => '{"n_estimators": 300, "max_depth": 6, "learning_rate": 0.05, "subsample": 0.8}'::jsonb,
    test_size       => 0.15
);

-- In-Database Inference & Scoring Write-Back
CREATE TABLE IF NOT EXISTS predictions.fleet_failure_scores (
    asset_id                TEXT PRIMARY KEY REFERENCES curated.fleet_health(asset_id) ON DELETE CASCADE,
    model_version           TEXT NOT NULL,
    predicted_probability   NUMERIC(6,5),
    predicted_class         SMALLINT,
    risk_tier               TEXT,
    scored_at               TIMESTAMPTZ DEFAULT now()
);

INSERT INTO predictions.fleet_failure_scores
    (asset_id, model_version, predicted_probability, predicted_class, risk_tier)
SELECT
    f.asset_id,
    'v1_xgboost',
    pgml.predict('nexora_fleet_failure_30d', f.*)::NUMERIC(6,5),
    ROUND(pgml.predict('nexora_fleet_failure_30d', f.*))::SMALLINT,
    CASE
        WHEN pgml.predict('nexora_fleet_failure_30d', f.*) >= 0.60 THEN 'Critical'
        WHEN pgml.predict('nexora_fleet_failure_30d', f.*) >= 0.35 THEN 'High'
        WHEN pgml.predict('nexora_fleet_failure_30d', f.*) >= 0.15 THEN 'Medium'
        ELSE 'Low'
    END
FROM features.fleet_health_features_v1 f
ON CONFLICT (asset_id) DO UPDATE SET
    predicted_probability = EXCLUDED.predicted_probability,
    risk_tier = EXCLUDED.risk_tier,
    scored_at = now();

-- Power BI Semantic Views
CREATE OR REPLACE VIEW bi.vw_asset_risk_overview AS
SELECT
    f.asset_id, f.asset_type, f.manufacturer, f.region, f.depot_location,
    f.asset_age_years, f.utilization_rate_pct, f.active_fault_code_count,
    p.predicted_probability, p.risk_tier, p.model_version, p.scored_at,
    f.failure_within_30d AS actual_failure_within_30d
FROM curated.fleet_health f
LEFT JOIN predictions.fleet_failure_scores p ON p.asset_id = f.asset_id;



The program is organised around five interconnected priority use cases, each selected both for direct, measurable economic and service return and for its ability to generate reusable platform assets.

Use Case A addresses fleet, trailer, and material-handling equipment health prediction. It focuses on estimating 30-day failure probabilities and remaining useful life for tractors, trailers, delivery vans, yard trucks, forklifts, conveyors, and sorters. Context features include utilisation intensity, fault-code histories, unscheduled repair ratios, age, manufacturer, region, and open recall status. The associated decision-support environment provides prioritised maintenance queues, risk-tier distributions, and forward visibility of maintenance workload. Value is realised through reduction of unplanned downtime, more efficient deployment of maintenance resources, extended asset life, and avoidance of secondary network disruption.

<img width="1408" height="768" alt="NEXORA LOGISTICS USE CASE A" src="https://github.com/user-attachments/assets/308edb46-6555-4c13-9f85-b286349dbb77" />



Use Case B addresses multi-horizon demand and inventory forecasting at SKU-location and network-node level across the nineteen major hubs and distribution centres. It produces forecasts at multiple horizons, out-of-stock risk flags, excess inventory valuations, and reorder recommendations. Node-level risk scoring highlights concentration of excess or shortage exposure. Value accrues from improved forecast accuracy, lower working-capital intensity, reduced lost sales, and more stable warehouse labour planning.

<img width="1354" height="768" alt="NEXORA LOGISTICS USE CASE B" src="https://github.com/user-attachments/assets/98613ed4-a688-4f52-9f57-63f5f9f6a4c1" />


Use Case C addresses delivery-time distribution and route-risk prediction across the corridor network. It characterises full transit-time distributions rather than simple averages, estimates delay-risk probabilities, and attributes risk to primary drivers such as weather, congestion, and port status. Transportation planners receive early warning of corridors likely to breach customer promises. Value is realised through proactive route and mode adjustment, more accurate customer communication, and reduction of SLA penalties and service recovery costs.


<img width="1380" height="768" alt="NEXORA LOGISTICS USE CASE C" src="https://github.com/user-attachments/assets/bed966ea-cd0e-43f2-ab45-4342dc433f8a" />


Use Case D addresses package quality and damage risk scoring. It evaluates pre-delivery damage, shortage, and condition risk across high-density sorting and handling paths. Features capture sortation intensity, vibration exposure, handling counts, and package characteristics. High-risk consignments can be flagged for special handling or inspection before final delivery. Value appears as reduced claims cost, lower customer friction, and earlier identification of systemic handling issues.

<img width="1444" height="736" alt="NEXORA LOGISTICS USE CASE D" src="https://github.com/user-attachments/assets/7b5a11e6-bc15-4bbc-80eb-d44cf82ac9a8" />


Use Case E addresses dynamic carrier, partner, and network risk scoring for the active base of carriers, brokers, regional line-haul providers, and last-mile partners. Multi-factor scores incorporate on-time performance trajectories, damage rates, capacity signals, and responsiveness. The decision environment surfaces partners requiring immediate intervention and predicts near-term on-time performance. Value is realised through earlier intervention, more informed allocation of volume, and progressive improvement of the overall partner portfolio.

<img width="1376" height="768" alt="NEXORA LOGISTICS USE CASE E" src="https://github.com/user-attachments/assets/6b87d98c-c43d-473f-a636-004c88c3be7e" />


Each use case begins with deliberately constrained scope—selected asset classes, SKU cohorts, corridors, or partner segments of manageable complexity—and expands only after statistical performance, operational stability, measured cost-to-serve and service impact, reliability integrity, and user acceptance have been demonstrated on production data inside the PostgreSQL environment.

Controlled, auditable ingestion processes land immutable extracts from telematics platforms, fleet management systems, warehouse management systems, transportation management systems, inventory systems, claims systems, and carrier portals into a raw schema. A curated layer conforms dimensions, reconstructs asset and shipment histories, and links events to network nodes, corridors, and partners. 

A features layer materialises versioned feature tables that capture utilisation metrics, fault-code patterns, repair ratios, demand covariates, transit-time predictors, handling intensity indicators, and partner performance trajectories—all engineered with native SQL window functions, aggregations, and statistical transformations. A models layer maintains a complete registry of trained artefacts, hyperparameters, performance metrics, intended use, known limitations, version history, and risk classification. Predictions are written to a dedicated schema together with probability scores, risk tiers, explanations, confidence measures, and model-version identifiers. A monitoring layer continuously evaluates data quality, feature drift, prediction performance, and reliability-related signals, generating alerts when predefined thresholds are breached. A bi schema exposes only governed, business-friendly semantic views that Power BI consumes for executive, planning, maintenance, and carrier-management workbenches.

A balanced scorecard continuously monitors four perspectives with pre-defined metrics and named owners: technical health (data-quality scores, pipeline reliability, model statistical performance offline and online, calibration, stability, and reliability-bound integrity, all measured inside PostgreSQL); adoption and embedding (active user count of Power BI environments, prediction acceptance versus override rates, feature usage, and qualitative user feedback); business outcomes (equipment downtime and maintenance cost, forecast accuracy and inventory metrics, delivery-time performance and SLA adherence, claims cost, carrier on-time performance, and selected customer-experience indicators, all tracked against pre-initiative baselines with statistical attribution where feasible); and program delivery (milestone adherence, budget variance, residual risk posture, and unbroken compliance with technology and reliability constraints).
