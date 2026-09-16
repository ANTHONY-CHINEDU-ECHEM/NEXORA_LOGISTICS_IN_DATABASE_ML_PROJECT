# NEXORA Logistics: Intelligent Predictive Operations Initiative

**A production-grade, in-database machine learning platform for fleet health prediction, demand forecasting, and dynamic network risk scoring—built entirely in PostgreSQL with PostgresML.**

---

## 🎯 Overview

NEXORA Logistics is an enterprise analytics initiative that transforms reactive logistics operations into predictive, data-driven decision-making systems. By consolidating operational telemetry, fleet diagnostics, and network performance data into a single PostgreSQL data foundation, the platform enables real-time risk identification and optimized resource allocation across a distributed logistics network.

This repository contains **Use Case A: Fleet, Trailer & Material-Handling Equipment Health Prediction**—a pure in-database ML pipeline that predicts 30-day equipment failure risk using gradient-boosted trees (XGBoost), executed entirely within PostgreSQL.

---

## 🔑 Key Capabilities

### **Fleet Health Prediction (Use Case A)**
- **Predictive Scope:** 30-day failure probability for tractors, trailers, delivery vans, yard trucks, material-handling equipment
- **Risk Stratification:** Four-tier risk model (Critical, High, Medium, Low) based on equipment telemetry, maintenance history, and operational patterns
- **Operational Output:** Asset-level failure scoring, maintenance prioritization, real-time safety alerts
- **Expected Impact:** 15–25% reduction in unscheduled downtime, 10–20% improvement in maintenance cost efficiency

### **Modular Architecture Across 5 Use Cases**
- **Use Case A:** Fleet & Equipment Health Prediction *(implemented)*
- **Use Case B:** Multi-Horizon Demand & Inventory Forecasting (SKU-location & network node level)
- **Use Case C:** Delivery-Time Distribution & Route-Risk Prediction
- **Use Case D:** Package Quality & Damage Risk Scoring
- **Use Case E:** Dynamic Carrier & Network Partner Risk Scoring

---

## 📊 Technical Stack

- **Database:** PostgreSQL 15+ with PostgresML extension
- **ML Framework:** PostgresML (`pgml`) for in-database training and inference
- **Primary Algorithm:** XGBoost (gradient-boosted trees), with linear regression challenger model
- **Feature Engineering:** Pure SQL (window functions, CTEs, aggregations)
- **Data Quality:** Automated validation rules with quarantine table
- **Monitoring:** Feature drift detection, prediction distribution tracking, performance backtesting
- **BI Layer:** Power BI-facing semantic views (read-only consumption)
- **Language:** PL/pgSQL, SQL

---

## 📁 Repository Structure

```
NEXORA_LOGISTICS_IN_DATABASE_ML_PROJECT/
├── nexora_postgresql_ml_pipeline.sql   # Main ML pipeline (1,000+ lines, 14 sections)
├── nexora_fleet_health_dataset.csv      # Training data (7,850 assets × 45 features)
├── nexora_fleet_health_dataset.xlsx     # Same dataset in Excel format
├── README.md                            # This file
├── LICENSE                              # MIT License
└── [Governance & Use Case Documentation]
    ├── 2 BUSINESS CASE 2.docx          # Detailed business case & architecture spec
    ├── NEXORA LOGISTICS USE CASE A.jpeg # Fleet health pipeline diagram
    ├── NEXORA LOGISTICS USE CASE B.jpeg # Demand forecasting overview
    ├── NEXORA LOGISTICS USE CASE C.jpeg # Delivery-time prediction overview
    ├── NEXORA LOGISTICS USE CASE D.jpeg # Package quality risk model overview
    └── NEXORA LOGISTICS USE CASE E.jpeg # Carrier/partner risk scoring overview
```

---

## 🏗️ Database Schema Architecture

The pipeline implements a **layered, modular schema design** consistent with analytics best practices:

```sql
raw            -- Landing zone: direct extracts from source systems
curated        -- Cleaned, conformed, governed data with reference dimensions
features       -- Versioned feature tables (SQL-engineered, ML-ready)
models         -- Model cards, metadata, governance tracking
predictions    -- Scoring outputs and risk-tier assignments
monitoring     -- Data quality, drift detection, performance logging
bi             -- Power BI semantic layer (views, read-only)
```

### Core Tables & Views

| Component | Purpose |
|-----------|---------|
| `raw.fleet_health_snapshot` | Landing table (45 columns, 7,850 rows) |
| `curated.fleet_health` | Production data, partitioned by snapshot date |
| `curated.dim_asset_type` | Reference dimension (Motorized-Road, Non-Motorized, Material-Handling) |
| `features.fleet_health_features_v1` | 50+ engineered features (ratios, z-scores, cohort indicators) |
| `predictions.fleet_failure_scores` | Model predictions with risk tier assignments |
| `monitoring.dq_quarantine` | Data quality violations and quarantine log |
| `monitoring.feature_drift_log` | Baseline vs. current feature statistics |
| `bi.vw_asset_risk_overview` | Executive view: assets + predictions + actuals |
| `bi.vw_model_quality_backtest` | Accuracy, precision, recall metrics |

---

## 🚀 Quick Start

### Prerequisites

- PostgreSQL 15+ with `pgml` and `pgcrypto` extensions installed
- Admin access to create schemas and tables
- `psql` CLI or IDE (pgAdmin, DBeaver, etc.)

### Installation & Data Load

1. **Clone this repository:**
   ```bash
   git clone https://github.com/ANTHONY-CHINEDU-ECHEM/NEXORA_LOGISTICS_IN_DATABASE_ML_PROJECT.git
   cd NEXORA_LOGISTICS_IN_DATABASE_ML_PROJECT
   ```

2. **Connect to PostgreSQL and verify extensions:**
   ```sql
   -- Log in to your PostgreSQL instance
   psql -U <user> -d <database>

   -- Verify pgml and pgcrypto are available
   CREATE EXTENSION IF NOT EXISTS pgml;
   CREATE EXTENSION IF NOT EXISTS pgcrypto;
   \dx  -- List installed extensions
   ```

3. **Load the SQL pipeline:**
   ```bash
   psql -U <user> -d <database> -f nexora_postgresql_ml_pipeline.sql
   ```

4. **Load training data into the raw landing table:**
   ```sql
   -- From within psql, adjust the path to your local CSV copy:
   \copy raw.fleet_health_snapshot(asset_id, asset_type, asset_subtype_model, manufacturer, region,
     depot_location, in_service_date, asset_age_years, purchase_cost_usd, current_odometer_miles,
     current_engine_hours, fuel_type, avg_daily_miles_last_30d, avg_daily_hours_last_30d,
     utilization_rate_pct, total_trips_last_90d, total_idle_hours_last_30d, load_factor_pct,
     route_type, total_maintenance_events_lifetime, scheduled_maintenance_count_last_12m,
     unscheduled_repair_count_last_12m, days_since_last_maintenance, days_since_last_major_repair,
     avg_repair_cost_last_12m_usd, total_maintenance_cost_lifetime_usd, last_maintenance_type,
     open_recall_flag, active_fault_code_count, critical_fault_code_flag, engine_temp_avg_last_30d_f,
     oil_pressure_avg_psi, battery_voltage_avg, brake_wear_pct, tire_tread_depth_mm, vibration_index,
     telematics_data_completeness_pct, driver_assigned_count_last_90d, weather_exposure_index,
     cargo_weight_avg_lbs, inspection_pass_rate_pct_last_12m, downtime_events_last_12m,
     downtime_hours_last_12m, failure_within_30d, days_to_next_failure_or_censor)
   FROM 'nexora_fleet_health_dataset.csv' WITH (FORMAT csv, HEADER true);
   ```

5. **Run data quality checks:**
   ```sql
   SELECT * FROM monitoring.run_data_quality_checks();
   ```

6. **Verify model training and predictions:**
   ```sql
   -- Check trained models
   SELECT * FROM pgml.overview WHERE project_name = 'nexora_fleet_failure_30d';

   -- View sample predictions
   SELECT asset_id, risk_tier, predicted_probability, scored_at 
   FROM predictions.fleet_failure_scores 
   LIMIT 20;

   -- Executive summary: assets by risk tier
   SELECT region, asset_type, risk_tier, COUNT(*) AS asset_count,
          ROUND(AVG(predicted_probability), 4) AS avg_risk
   FROM bi.vw_asset_risk_overview
   GROUP BY region, asset_type, risk_tier
   ORDER BY asset_count DESC;
   ```

---

## 📈 How It Works

### **Step 1: Data Ingestion & Quality**
- Raw extracts from fleet telematics, maintenance systems, and inventory platforms land in `raw.fleet_health_snapshot`
- Automated validation rules detect missing identifiers, out-of-range percentages, and referential integrity issues
- Violations are logged in `monitoring.dq_quarantine`; only validated rows proceed to `curated.fleet_health`

### **Step 2: Feature Engineering**
- 50+ ML-ready features are derived entirely in SQL using window functions and aggregations
- Examples:
  - `repair_cost_to_asset_value_ratio`: lifetime repair spend ÷ purchase cost
  - `fault_codes_z_within_type`: standardized deviation of fault codes within asset class
  - `maintenance_recency_quintile`: asset age ranking within cohort
  - Categorical encodings (`open_recall_flag_num`, `critical_fault_flag_num`)

### **Step 3: Model Training**
- Feature table `features.fleet_health_features_v1` is split 70% train / 15% validation / 15% test
- XGBoost classifier (`n_estimators=300, max_depth=6`) trained to predict `failure_within_30d`
- Hyperparameters tuned per business case constraints; regularization prevents overfitting
- Secondary linear regression model trained for interpretability comparison

### **Step 4: Inference & Risk Scoring**
- Trained model scores all assets, producing a normalized probability (0.0–1.0)
- Probabilities mapped to four-tier risk model:
  - **Critical:** ≥ 0.60 probability → immediate inspection / preventive maintenance
  - **High:** 0.35–0.59 → scheduled within 7 days
  - **Medium:** 0.15–0.34 → monitor closely, schedule within 30 days
  - **Low:** < 0.15 → standard maintenance cycle

### **Step 5: Monitoring & Feedback**
- **Feature Drift Detection:** baseline means vs. current statistics flag distributions shifts > 15%
- **Prediction Distribution Tracking:** asset count and average probability logged by risk tier
- **Model Quality Backtesting:** accuracy, precision, recall computed on holdout test set
- **Human-in-the-Loop:** reviewer overrides captured in `predictions.human_review_feedback` for retraining

### **Step 6: BI Consumption**
- Power BI connects to semantic views in `bi` schema
- Read-only access ensures data integrity; filtering and drill-down happen in BI layer
- Dashboards track:
  - Risk tier distribution (by region, asset type, fleet)
  - Model performance (accuracy, precision, recall)
  - Data quality scorecard
  - Feature drift trends

---

## 🎓 Core Design Principles

1. **All-in-Database Execution**
   - No Python / R scripts, no data movement to external ML platforms
   - Training, feature engineering, inference, monitoring all in PostgreSQL
   - Single source of truth; full audit trail in SQL

2. **Layered Modularity**
   - Cleanly separated concerns (raw → curated → features → models → predictions → monitoring → BI)
   - Each schema is independently testable; changes don't cascade

3. **Governance & Auditability**
   - Model cards document algorithm choice, hyperparameters, intended use, limitations
   - Human-in-the-loop overrides captured for feedback loops
   - Data quality rules and violations logged permanently

4. **Fairness & Risk Management**
   - Four-tier risk stratification prevents over-fitting predictions to action
   - Elevated-risk models (safety-critical) flagged for human review
   - Challenger models (linear regression) trained for interpretability

5. **Scalability & Maintainability**
   - Table partitioning by snapshot date enables efficient historical depth
   - Feature versioning allows safe side-by-side model comparison
   - Stored procedures enable scheduled retraining via `pg_cron`

---

## 🔄 Production Deployment Checklist

- [ ] Verify data quality checks pass (`monitoring.run_data_quality_checks()`)
- [ ] Validate model performance on test set meets business SLA (e.g., recall ≥ 0.85 for critical failures)
- [ ] Set up Power BI service account with read-only access to `bi` schema
- [ ] Configure automated data ingestion from source systems → `raw.fleet_health_snapshot`
- [ ] Schedule weekly drift detection: `SELECT monitoring.check_feature_drift();`
- [ ] Schedule monthly retraining via `pg_cron` (see script comments, Section 14)
- [ ] Document model approval sign-off in `models.model_card` (approved_by, risk_classification)
- [ ] Configure alerts for high-priority risk tiers (Critical assets) via BI dashboards
- [ ] Establish feedback loop: operations team enters overrides in `predictions.human_review_feedback`
- [ ] Plan retraining cycles based on drift thresholds and new ground-truth data

---

## 📚 Use Case Details

### **Use Case A: Fleet & Equipment Health Prediction** (Implemented)
**Problem:** Equipment failures are detected after the fact, causing reactive downtime and customer service disruption.

**Solution:** Predict 30-day failure risk using telematics, maintenance history, and fault codes. Prioritize inspection and preventive maintenance on high-risk assets.

**Business Impact:**
- 15–25% reduction in unscheduled downtime
- 10–20% savings on maintenance cost (prevent cascading failures)
- Improved asset utilization (fewer missed pickup/delivery windows)

**Data:** 7,850 assets × 45 operational features (utilization, fault codes, repair costs, engine metrics, weather exposure)

---

### **Use Case B: Multi-Horizon Demand & Inventory Forecasting**
**Problem:** Forecast inaccuracy at SKU-location level drives out-of-stock events and excess inventory.

**Data Layer:** SKU-level demand by distribution center; temporal, seasonal, and promotional covariates.

**Models:** ARIMA, Prophet, or XGBoost regressor trained on rolling 24-month demand history; forecast horizons at 7, 14, and 30 days.

**Output:** Inventory recommendations by SKU-location; safety stock triggers.

---

### **Use Case C: Delivery-Time Distribution & Route-Risk Prediction**
**Problem:** Transit-time variability and late-delivery risk poorly characterized; routing decisions made on average performance.

**Data Layer:** Historical transit times, route segments, carrier performance, congestion patterns.

**Models:** Quantile regression or gradient boosting to forecast full transit-time distribution (10th, 50th, 90th percentiles).

**Output:** Route risk scores; dynamic carrier selection; SLA compliance forecasts.

---

### **Use Case D: Package Quality & Damage Risk Scoring**
**Problem:** Package damage and shortage issues detected post-delivery; high-density sorting and handling create predictable risk.

**Data Layer:** Handling intensity, equipment age, package dimensions, weather, carrier performance.

**Models:** XGBoost classifier for damage / shortage risk; damage type stratified by handling path.

**Output:** Risk-based sorting priority; handler coaching; carrier performance scorecards.

---

### **Use Case E: Dynamic Carrier & Network Partner Risk Scoring**
**Problem:** Partner performance monitored retrospectively; early warning signals not aggregated into dynamic scoring.

**Data Layer:** On-time delivery, quality events, cost performance, capacity trends for all active carriers.

**Models:** Weighted composite risk score incorporating delay risk, quality risk, and cost variance.

**Output:** Dynamic carrier selection; partner performance scorecards; escalation triggers.

---

## 🛠️ Development & Customization

### **Extending the Feature Set**
1. Add new columns to `raw.fleet_health_snapshot` schema definition (Section 2)
2. Re-run data load with `\copy`
3. Add feature expressions to the CTE in `features.fleet_health_features_v1` (Section 6)
4. Retrain models (Section 8)

### **Switching Algorithms**
- Modify the `algorithm` parameter in `pgml.train()` (Section 8)
- Supported algorithms: `xgboost`, `linear`, `svm`, `neural_net`
- Update hyperparameters in the `hyperparams` JSON

### **Adjusting Risk Tiers**
- Modify the `CASE` statement in Section 10 (Inference)
- Update thresholds to reflect operational risk tolerance

### **Connecting to Power BI**
1. Create a Power BI data source with PostgreSQL driver
2. Point to the `bi` schema
3. Import semantic views (`vw_asset_risk_overview`, `vw_risk_tier_summary`, etc.)
4. Build dashboards with filtering, drill-down, and KPI cards

---

## 📋 Data Dictionary (Selected Features)

| Feature | Type | Description |
|---------|------|-------------|
| `asset_id` | TEXT | Unique asset identifier |
| `asset_type` | TEXT | Tractor, Trailer, Delivery Van, Yard Truck, Forklift, Conveyor/Sorter |
| `asset_age_years` | NUMERIC | Years in service |
| `utilization_rate_pct` | NUMERIC | Percentage of available capacity used (last 30 days) |
| `active_fault_code_count` | INTEGER | Current active fault codes from telematics |
| `unscheduled_repair_count_last_12m` | INTEGER | Count of unplanned maintenance events (12-month window) |
| `days_since_last_maintenance` | NUMERIC | Days since most recent service |
| `avg_repair_cost_last_12m_usd` | NUMERIC | Average repair cost (12-month window) |
| `failure_within_30d` | SMALLINT | Target variable (0 = no failure, 1 = failed within 30 days) |
| `predicted_probability` | NUMERIC(6,5) | Model output: P(failure within 30 days) |
| `risk_tier` | TEXT | Derived from predicted_probability (Critical, High, Medium, Low) |

---

## 🔐 Security & Access Control

### **Database-Level Security**
- All schema and table-level access controlled via PostgreSQL roles
- Power BI service account granted read-only access to `bi` schema only
- Data quality and monitoring tables restricted to analytics team
- Feature and prediction tables accessed only through semantic layer

### **Data Governance**
- Model card audit trail (trained_at, approved_by, risk_classification)
- All model training logged to `models.model_card`
- Human-in-the-loop overrides logged permanently in `predictions.human_review_feedback`
- DQ quarantine captures all violations for compliance audits

---

## 🔍 Monitoring & Observability

### **Data Quality Dashboard**
```sql
SELECT * FROM bi.vw_data_quality_summary;
```

### **Feature Drift Monitor**
```sql
SELECT * FROM bi.vw_drift_monitor ORDER BY checked_at DESC LIMIT 10;
```

### **Model Quality Backtest**
```sql
SELECT * FROM bi.vw_model_quality_backtest;
```

### **Prediction Distribution**
```sql
SELECT * FROM monitoring.prediction_distribution_log 
ORDER BY logged_at DESC LIMIT 10;
```

---

## 📞 Support & Contribution

This project is maintained by the Nexora Data & Analytics team. For questions, bug reports, or feature requests:

1. **Check existing issues** in the repository
2. **Review the Business Case document** (2 BUSINESS CASE 2.docx) for architectural constraints
3. **Test locally** before proposing changes to the production pipeline
4. **Document hyperparameter changes** and model updates in the model card

### **Contributing**
- Follow PL/pgSQL style guide: clear naming, comprehensive comments, modular functions
- Add data quality rules to `monitoring.run_data_quality_checks()` for new data sources
- Test feature engineering changes on a sample before applying to full dataset
- Update this README with any schema or pipeline changes

---

## 📄 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

---

## 🎯 Next Steps

1. **Load the pipeline** and verify data quality checks pass
2. **Review model performance** on the test set (accuracy, precision, recall)
3. **Connect Power BI** and build executive dashboards
4. **Set up automated data ingestion** from your fleet management and telematics systems
5. **Configure scheduled retraining** via `pg_cron` (see Section 14)
6. **Establish operational runbooks** for responding to Critical and High risk alerts
7. **Plan rollout** of other use cases (demand forecasting, route optimization, quality risk, carrier scoring)

---

**Version:** 1.0  
**Last Updated:** September 2026  
**Status:** Production Ready (Use Case A)  
**Contact:** ANTHONY-CHINEDU-ECHEM
