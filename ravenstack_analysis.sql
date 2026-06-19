-- =============================================================
-- RavenStack SaaS Revenue Intelligence — SQL Analysis
-- Author : Sumit Kuskar
-- Dataset: RavenStack synthetic SaaS data by River @ Rivalytics
-- Period : Jan 2023 – Dec 2024
-- DB     : PostgreSQL 16
-- =============================================================
-- Run this against the ravenstack_analytics database.
-- Create and load all tables before running the analysis sections.
-- =============================================================

-- accounts (load first — all other tables reference this)
CREATE TABLE IF NOT EXISTS accounts (
    account_id VARCHAR(50) PRIMARY KEY,
    account_name VARCHAR(255) NOT NULL,
    industry VARCHAR(100) NOT NULL,
    country VARCHAR(100) NOT NULL,
    signup_date DATE NOT NULL,
    referral_source VARCHAR(100) NOT NULL,
    plan_tier VARCHAR(50) NOT NULL,
    seats INTEGER NOT NULL,
    is_trial BOOLEAN NOT NULL,
    churn_flag BOOLEAN NOT NULL
);

-- subscriptions
CREATE TABLE IF NOT EXISTS subscriptions (
    subscription_id VARCHAR(50) PRIMARY KEY,
    account_id VARCHAR(50) NOT NULL REFERENCES accounts(account_id),
    start_date DATE NOT NULL,
    end_date DATE NULL,
    plan_tier VARCHAR(50) NOT NULL,
    seats INTEGER NOT NULL,
    mrr_amount NUMERIC(10,2) NOT NULL,
    arr_amount NUMERIC(10,2) NOT NULL,
    is_trial BOOLEAN NOT NULL,
    upgrade_flag BOOLEAN NOT NULL,
    downgrade_flag BOOLEAN NOT NULL,
    churn_flag BOOLEAN NOT NULL,
    billing_frequency VARCHAR(50) NOT NULL,
    auto_renew_flag BOOLEAN NOT NULL
);

-- feature_usage
CREATE TABLE IF NOT EXISTS feature_usage (
    usage_id VARCHAR(50) PRIMARY KEY,
    subscription_id VARCHAR(50) NOT NULL REFERENCES subscriptions(subscription_id),
    usage_date DATE NOT NULL,
    feature_name VARCHAR(100) NOT NULL,
    usage_count INTEGER NOT NULL,
    usage_duration_secs INTEGER NOT NULL,
    error_count INTEGER NOT NULL,
    is_beta_feature BOOLEAN NOT NULL
);

-- support_tickets
CREATE TABLE IF NOT EXISTS support_tickets (
    ticket_id VARCHAR(50) PRIMARY KEY,
    account_id VARCHAR(50) NOT NULL REFERENCES accounts(account_id),
    submitted_at TIMESTAMP NOT NULL,
    closed_at TIMESTAMP NULL,
    resolution_time_hours NUMERIC(10,2) NULL,
    priority VARCHAR(50) NOT NULL,
    first_response_time_minutes INTEGER NULL,
    satisfaction_score INTEGER NULL,
    escalation_flag BOOLEAN NOT NULL
);

-- churn_events (load last — FK references accounts)
CREATE TABLE IF NOT EXISTS churn_events (
    churn_event_id VARCHAR(50) PRIMARY KEY,
    account_id VARCHAR(50) NOT NULL REFERENCES accounts(account_id),
    churn_date DATE NOT NULL,
    reason_code VARCHAR(100) NOT NULL,
    refund_amount_usd NUMERIC(10,2) NOT NULL DEFAULT 0,
    preceding_upgrade_flag BOOLEAN NOT NULL,
    preceding_downgrade_flag BOOLEAN NOT NULL,
    is_reactivation BOOLEAN NOT NULL,
    feedback_text TEXT NULL
);

-- -------------------------------------------------------------
-- Load CSV files — update the path below to match your local
-- folder before running. Load order matters due to FK constraints.
-- -------------------------------------------------------------
COPY accounts
FROM '/path/to/data/ravenstack_accounts.csv'
DELIMITER ',' CSV HEADER;

COPY subscriptions
FROM '/path/to/data/ravenstack_subscriptions.csv'
DELIMITER ',' CSV HEADER;

COPY feature_usage
FROM '/path/to/data/ravenstack_feature_usage.csv'
DELIMITER ',' CSV HEADER;

COPY support_tickets
FROM '/path/to/data/ravenstack_support_tickets.csv'
DELIMITER ',' CSV HEADER;

COPY churn_events
FROM '/path/to/data/ravenstack_churn_events.csv'
DELIMITER ',' CSV HEADER;

-- Quick sanity check — expected: 500, 5000, 25000, 2000, 600
SELECT 'accounts' AS tbl, COUNT(*) FROM accounts
UNION ALL SELECT 'subscriptions', COUNT(*) FROM subscriptions
UNION ALL SELECT 'feature_usage', COUNT(*) FROM feature_usage
UNION ALL SELECT 'support_tickets', COUNT(*) FROM support_tickets
UNION ALL SELECT 'churn_events', COUNT(*) FROM churn_events;

-- =============================================================
-- SECTION 1 — Core KPI snapshot (MRR, ARR, ARPU, churn, NRR)
-- Reporting date: 2024-12-31. Change report_date / prior_date
-- in the CTE below if you want a different period.
-- Note: Dec 2024 monthly churn (~20%) is a synthetic data artifact
-- — the generator front-loaded year-end churn events. Frame any
-- churn analysis around reason codes rather than the absolute rate.
-- =============================================================
WITH reporting_period AS (
    SELECT
        '2024-12-31'::DATE AS report_date,
        '2024-11-30'::DATE AS prior_date
),
active_curr AS (
    SELECT s.account_id, SUM(s.mrr_amount) AS mrr_amount
    FROM subscriptions s
    CROSS JOIN reporting_period rp
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
      AND s.start_date <= rp.report_date
      AND (s.end_date IS NULL OR s.end_date > rp.report_date)
    GROUP BY s.account_id
),
active_prior AS (
    SELECT s.account_id, SUM(s.mrr_amount) AS mrr_amount
    FROM subscriptions s
    CROSS JOIN reporting_period rp
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
      AND s.start_date <= rp.prior_date
      AND (s.end_date IS NULL OR s.end_date > rp.prior_date)
    GROUP BY s.account_id
),
latest_churn AS (
    SELECT
        account_id,
        churn_date,
        ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY churn_date DESC) AS rn
    FROM churn_events
),
retained AS (
    SELECT c.account_id, c.mrr_amount AS curr_mrr
    FROM active_curr c
    JOIN active_prior p ON c.account_id = p.account_id
)
SELECT
    ROUND(SUM(ac.mrr_amount), 2) AS total_mrr,
    ROUND(SUM(ac.mrr_amount) * 12, 2) AS total_arr,
    COUNT(DISTINCT ac.account_id) AS active_accounts,
    ROUND(SUM(ac.mrr_amount) / NULLIF(COUNT(DISTINCT ac.account_id), 0), 2) AS arpu,
    ROUND(
        (
            SELECT COUNT(DISTINCT lc.account_id)
            FROM latest_churn lc
            CROSS JOIN reporting_period rp
            WHERE lc.rn = 1
              AND lc.churn_date > rp.prior_date
              AND lc.churn_date <= rp.report_date
        )::NUMERIC
        / NULLIF((SELECT COUNT(DISTINCT account_id) FROM active_prior), 0)
        * 100,
        2
    ) AS monthly_churn_rate_pct,
    ROUND(
        (SELECT SUM(curr_mrr) FROM retained)
        / NULLIF((SELECT SUM(mrr_amount) FROM active_prior), 0)
        * 100,
        2
    ) AS net_revenue_retention_pct
FROM active_curr ac;

-- =============================================================
-- SECTION 2 — Monthly cohort retention (m0 through m6)
-- Groups accounts by signup month, tracks % still active at
-- months 0, 1, 2, 3, and 6. GENERATE_SERIES expands each sub
-- across all months it was active so we can count per cohort.
-- =============================================================
WITH cohort_base AS (
    SELECT
        account_id,
        DATE_TRUNC('month', signup_date)::DATE AS cohort_month
    FROM accounts
),
sub_months AS (
    SELECT
        s.account_id,
        gs.activity_month::DATE AS activity_month
    FROM subscriptions s
    CROSS JOIN LATERAL GENERATE_SERIES(
        DATE_TRUNC('month', s.start_date),
        DATE_TRUNC('month', COALESCE(s.end_date, '2024-12-31'::DATE)),
        '1 month'::INTERVAL
    ) AS gs(activity_month)
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT account_id) AS cohort_size
    FROM cohort_base
    GROUP BY cohort_month
),
retention_raw AS (
    SELECT
        cb.cohort_month,
        (
            EXTRACT(YEAR FROM AGE(sm.activity_month, cb.cohort_month)) * 12
            + EXTRACT(MONTH FROM AGE(sm.activity_month, cb.cohort_month))
        )::INT AS month_num,
        COUNT(DISTINCT cb.account_id) AS retained_users
    FROM cohort_base cb
    JOIN sub_months sm ON cb.account_id = sm.account_id
    WHERE sm.activity_month >= cb.cohort_month
    GROUP BY cb.cohort_month, month_num
)
SELECT
    rr.cohort_month,
    cs.cohort_size,
    MAX(CASE WHEN rr.month_num = 0 THEN ROUND(rr.retained_users * 100.0 / cs.cohort_size, 1) END) AS m0_pct,
    MAX(CASE WHEN rr.month_num = 1 THEN ROUND(rr.retained_users * 100.0 / cs.cohort_size, 1) END) AS m1_pct,
    MAX(CASE WHEN rr.month_num = 2 THEN ROUND(rr.retained_users * 100.0 / cs.cohort_size, 1) END) AS m2_pct,
    MAX(CASE WHEN rr.month_num = 3 THEN ROUND(rr.retained_users * 100.0 / cs.cohort_size, 1) END) AS m3_pct,
    MAX(CASE WHEN rr.month_num = 6 THEN ROUND(rr.retained_users * 100.0 / cs.cohort_size, 1) END) AS m6_pct
FROM retention_raw rr
JOIN cohort_sizes cs ON rr.cohort_month = cs.cohort_month
GROUP BY rr.cohort_month, cs.cohort_size
ORDER BY rr.cohort_month;

-- =============================================================
-- SECTION 3 — MRR waterfall (new, expansion, contraction, churn)
-- CROSS JOIN all revenue accounts to the calendar so churned
-- accounts appear as zero-MRR rows each month. Without this,
-- churned accounts disappear and churned_mrr always comes out 0.
-- =============================================================
WITH calendar AS (
    SELECT GENERATE_SERIES(
        DATE_TRUNC('month', '2023-01-01'::DATE),
        DATE_TRUNC('month', '2024-12-01'::DATE),
        '1 month'::INTERVAL
    )::DATE AS reporting_month
),
all_rev_accounts AS (
    SELECT DISTINCT account_id
    FROM subscriptions
    WHERE is_trial = FALSE
      AND mrr_amount > 0
),
monthly_mrr AS (
    SELECT
        c.reporting_month,
        ara.account_id,
        COALESCE(SUM(s.mrr_amount), 0) AS current_mrr
    FROM calendar c
    CROSS JOIN all_rev_accounts ara
    LEFT JOIN subscriptions s
        ON s.account_id = ara.account_id
       AND s.is_trial = FALSE
       AND s.mrr_amount > 0
       AND DATE_TRUNC('month', s.start_date) <= c.reporting_month
       AND (
            s.end_date IS NULL
            OR DATE_TRUNC('month', s.end_date) > c.reporting_month
       )
    GROUP BY c.reporting_month, ara.account_id
),
mrr_with_lag AS (
    SELECT
        reporting_month,
        account_id,
        current_mrr,
        LAG(current_mrr, 1, 0) OVER (
            PARTITION BY account_id
            ORDER BY reporting_month
        ) AS previous_mrr
    FROM monthly_mrr
),
waterfall AS (
    SELECT
        reporting_month,
        CASE
            WHEN previous_mrr = 0 AND current_mrr > 0 THEN current_mrr
            ELSE 0
        END AS new_mrr,
        CASE
            WHEN previous_mrr > 0 AND current_mrr > previous_mrr THEN current_mrr - previous_mrr
            ELSE 0
        END AS expansion_mrr,
        CASE
            WHEN previous_mrr > 0 AND current_mrr > 0 AND current_mrr < previous_mrr THEN previous_mrr - current_mrr
            ELSE 0
        END AS contraction_mrr,
        CASE
            WHEN previous_mrr > 0 AND current_mrr = 0 THEN previous_mrr
            ELSE 0
        END AS churned_mrr
    FROM mrr_with_lag
)
SELECT
    reporting_month,
    ROUND(SUM(new_mrr)::NUMERIC, 2) AS total_new_mrr,
    ROUND(SUM(expansion_mrr)::NUMERIC, 2) AS total_expansion_mrr,
    ROUND(SUM(contraction_mrr)::NUMERIC, 2) AS total_contraction_mrr,
    ROUND(SUM(churned_mrr)::NUMERIC, 2) AS total_churned_mrr,
    ROUND(
        (SUM(new_mrr) + SUM(expansion_mrr) - SUM(contraction_mrr) - SUM(churned_mrr))::NUMERIC,
        2
    ) AS net_new_mrr
FROM waterfall
GROUP BY reporting_month
ORDER BY reporting_month;

-- =============================================================
-- SECTION 4 — Revenue by industry and plan tier
-- Simple cut of active MRR/ARR grouped by industry and plan tier.
-- Useful for spotting which segments carry the most revenue weight.
-- =============================================================
WITH active AS (
    SELECT s.account_id, s.plan_tier, s.mrr_amount
    FROM subscriptions s
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
      AND s.start_date <= '2024-12-31'::DATE
      AND (s.end_date IS NULL OR s.end_date > '2024-12-31'::DATE)
)
SELECT
    a.industry,
    ac.plan_tier,
    COUNT(DISTINCT a.account_id) AS customers,
    SUM(ac.mrr_amount) AS segment_mrr,
    ROUND(SUM(ac.mrr_amount) / NULLIF(COUNT(DISTINCT a.account_id), 0), 2) AS arpu,
    ROUND(SUM(ac.mrr_amount) * 12, 2) AS segment_arr
FROM accounts a
JOIN active ac ON a.account_id = ac.account_id
GROUP BY a.industry, ac.plan_tier
ORDER BY segment_mrr DESC;

-- =============================================================
-- SECTION 5 — Account health scores (90-day lookback)
-- Composite score weighted: usage 40%, CSAT 30%, errors 15%,
-- escalations 15%. Weights chosen to prioritise product engagement
-- over support signals, which tend to lag actual health changes.
-- Missing CSAT scores imputed as 3.0 (neutral) — ~22% of tickets
-- have no satisfaction response so blanking them would skew low.
-- =============================================================
WITH lookback AS (
    SELECT
        '2024-12-31'::DATE AS report_date,
        '2024-10-02'::DATE AS start_date
),
active_accounts AS (
    SELECT DISTINCT s.account_id, s.plan_tier, s.mrr_amount
    FROM subscriptions s
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
      AND s.start_date <= '2024-12-31'::DATE
      AND (s.end_date IS NULL OR s.end_date > '2024-12-31'::DATE)
),
usage_stats AS (
    SELECT
        s.account_id,
        SUM(fu.usage_count) AS total_usage,
        AVG(fu.error_count) AS avg_errors
    FROM feature_usage fu
    JOIN subscriptions s ON fu.subscription_id = s.subscription_id
    CROSS JOIN lookback lb
    WHERE fu.usage_date >= lb.start_date
    GROUP BY s.account_id
),
support_stats AS (
    SELECT
        st.account_id,
        AVG(COALESCE(st.satisfaction_score, 3.0)) AS avg_csat,
        SUM(CASE WHEN st.escalation_flag THEN 1.0 ELSE 0.0 END)
            / NULLIF(COUNT(st.ticket_id), 0) AS escalation_rate
    FROM support_tickets st
    CROSS JOIN lookback lb
    WHERE st.submitted_at >= lb.start_date::TIMESTAMP
    GROUP BY st.account_id
),
scores AS (
    SELECT
        a.account_id,
        a.plan_tier,
        a.mrr_amount,
        LEAST(100.0, COALESCE(u.total_usage, 0) / 100.0 * 100.0) AS usage_score,
        (COALESCE(ss.avg_csat, 3.0) / 5.0) * 100.0 AS csat_score,
        GREATEST(0.0, 100.0 - COALESCE(u.avg_errors, 0) * 10.0) AS error_score,
        GREATEST(0.0, 100.0 - COALESCE(ss.escalation_rate, 0) * 100.0) AS escalation_score
    FROM active_accounts a
    LEFT JOIN usage_stats u ON a.account_id = u.account_id
    LEFT JOIN support_stats ss ON a.account_id = ss.account_id
)
SELECT
    account_id,
    plan_tier,
    mrr_amount,
    ROUND(usage_score, 2) AS usage_score,
    ROUND(csat_score, 2) AS csat_score,
    ROUND(error_score, 2) AS error_score,
    ROUND(escalation_score, 2) AS escalation_score,
    ROUND(
        usage_score * 0.40
        + csat_score * 0.30
        + error_score * 0.15
        + escalation_score * 0.15,
        2
    ) AS health_score
FROM scores
ORDER BY health_score ASC;

-- =============================================================
-- SECTION 6 — Customer risk register (one row per account)
-- Accounts with multiple active subscriptions are collapsed using
-- DISTINCT ON — highest tier wins, total MRR is summed via window
-- function. This gives exactly 500 rows matching the accounts table.
-- Risk thresholds: < 40 = High Risk, 40–70 = Medium Risk, > 70 = Healthy.
-- LTV estimated as: MRR * gross_margin / monthly_churn_rate.
-- =============================================================
WITH lookback AS (
    SELECT
        '2024-12-31'::DATE AS report_date,
        '2024-10-02'::DATE AS start_date
),
active_raw AS (
    SELECT
        s.account_id,
        s.plan_tier,
        s.mrr_amount,
        CASE s.plan_tier
            WHEN 'Enterprise' THEN 3
            WHEN 'Pro' THEN 2
            ELSE 1
        END AS tier_rank
    FROM subscriptions s
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
      AND s.start_date <= '2024-12-31'::DATE
      AND (s.end_date IS NULL OR s.end_date > '2024-12-31'::DATE)
),
active_accounts AS (
    SELECT DISTINCT ON (account_id)
        account_id,
        plan_tier,
        SUM(mrr_amount) OVER (PARTITION BY account_id) AS mrr_amount
    FROM active_raw
    ORDER BY account_id, tier_rank DESC, mrr_amount DESC
),
usage_stats AS (
    SELECT
        s.account_id,
        SUM(fu.usage_count) AS total_usage,
        AVG(fu.error_count) AS avg_errors
    FROM feature_usage fu
    JOIN subscriptions s ON fu.subscription_id = s.subscription_id
    CROSS JOIN lookback lb
    WHERE fu.usage_date >= lb.start_date
    GROUP BY s.account_id
),
support_stats AS (
    SELECT
        st.account_id,
        AVG(COALESCE(st.satisfaction_score, 3.0)) AS avg_csat,
        SUM(CASE WHEN st.escalation_flag THEN 1.0 ELSE 0.0 END)
            / NULLIF(COUNT(st.ticket_id), 0) AS escalation_rate
    FROM support_tickets st
    CROSS JOIN lookback lb
    WHERE st.submitted_at >= lb.start_date::TIMESTAMP
    GROUP BY st.account_id
),
scores AS (
    SELECT
        a.account_id,
        a.plan_tier,
        a.mrr_amount,
        LEAST(100.0, COALESCE(u.total_usage, 0) / 100.0 * 100.0) AS usage_score,
        (COALESCE(ss.avg_csat, 3.0) / 5.0) * 100.0 AS csat_score,
        GREATEST(0.0, 100.0 - COALESCE(u.avg_errors, 0) * 10.0) AS error_score,
        GREATEST(0.0, 100.0 - COALESCE(ss.escalation_rate, 0) * 100.0) AS escalation_score
    FROM active_accounts a
    LEFT JOIN usage_stats u ON a.account_id = u.account_id
    LEFT JOIN support_stats ss ON a.account_id = ss.account_id
),
health AS (
    SELECT
        account_id,
        plan_tier,
        mrr_amount,
        ROUND(
            usage_score * 0.40
            + csat_score * 0.30
            + error_score * 0.15
            + escalation_score * 0.15,
            2
        ) AS health_score
    FROM scores
)
SELECT
    a.account_name,
    h.plan_tier,
    h.health_score,
    CASE
        WHEN h.health_score < 40 THEN 'High Risk'
        WHEN h.health_score <= 70 THEN 'Medium Risk'
        ELSE 'Healthy'
    END AS risk_category,
    h.mrr_amount AS revenue_at_stake_usd,
    ROUND(
        h.mrr_amount * 0.80
        / CASE h.plan_tier
            WHEN 'Enterprise' THEN 0.01
            WHEN 'Pro' THEN 0.03
            ELSE 0.05
        END,
        2
    ) AS estimated_ltv_usd,
    ce.reason_code AS last_churn_reason
FROM health h
JOIN accounts a ON h.account_id = a.account_id
LEFT JOIN (
    SELECT DISTINCT ON (account_id) account_id, reason_code
    FROM churn_events
    ORDER BY account_id, churn_date DESC
) ce ON h.account_id = ce.account_id
ORDER BY h.health_score ASC, h.mrr_amount DESC;

-- =============================================================
-- SECTION 7 — Feature adoption by plan tier
-- Top features by usage volume and avg session duration.
-- Beta features tracked separately — they have higher error rates
-- which feeds into the "features" churn reason (19% of churn).
-- =============================================================
WITH feature_totals AS (
    SELECT
        fu.feature_name,
        s.plan_tier,
        COUNT(fu.usage_id)                          AS event_count,
        SUM(fu.usage_count)                         AS total_usage,
        ROUND(AVG(fu.usage_duration_secs), 1)       AS avg_duration_secs,
        ROUND(AVG(fu.error_count), 2)               AS avg_errors,
        SUM(CASE WHEN fu.is_beta_feature THEN 1 ELSE 0 END) AS beta_events,
        MAX(fu.is_beta_feature::INT)                AS is_beta_feature
    FROM feature_usage fu
    JOIN subscriptions s ON fu.subscription_id = s.subscription_id
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
    GROUP BY fu.feature_name, s.plan_tier
),
feature_rank AS (
    SELECT
        feature_name,
        plan_tier,
        event_count,
        total_usage,
        avg_duration_secs,
        avg_errors,
        is_beta_feature,
        RANK() OVER (ORDER BY total_usage DESC) AS usage_rank
    FROM feature_totals
)
SELECT
    feature_name,
    plan_tier,
    event_count,
    total_usage,
    avg_duration_secs,
    avg_errors,
    is_beta_feature,
    usage_rank
FROM feature_rank
ORDER BY usage_rank, plan_tier;

-- =============================================================
-- SECTION 8 — Support SLA performance
-- Avg resolution time and first response time by priority.
-- SLA thresholds used: urgent < 4h, high < 8h, medium < 24h, low < 48h.
-- Escalation rate shows % of tickets that required escalation.
-- ~22% of tickets have no satisfaction score (open or no response).
-- =============================================================
WITH ticket_metrics AS (
    SELECT
        priority,
        COUNT(ticket_id)                                        AS total_tickets,
        ROUND(AVG(resolution_time_hours), 1)                   AS avg_resolution_hrs,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP
              (ORDER BY resolution_time_hours), 1)             AS median_resolution_hrs,
        ROUND(AVG(first_response_time_minutes), 0)             AS avg_first_response_mins,
        ROUND(AVG(COALESCE(satisfaction_score, 3.0)), 2)       AS avg_csat,
        ROUND(
            SUM(CASE WHEN escalation_flag THEN 1.0 ELSE 0.0 END)
            / NULLIF(COUNT(ticket_id), 0) * 100, 1
        )                                                       AS escalation_rate_pct,
        -- SLA breach: ticket resolved but took longer than threshold
        SUM(CASE
            WHEN priority = 'urgent' AND resolution_time_hours > 4   THEN 1
            WHEN priority = 'high'   AND resolution_time_hours > 8   THEN 1
            WHEN priority = 'medium' AND resolution_time_hours > 24  THEN 1
            WHEN priority = 'low'    AND resolution_time_hours > 48  THEN 1
            ELSE 0
        END)                                                    AS sla_breaches,
        COUNT(CASE WHEN closed_at IS NULL THEN 1 END)          AS open_tickets
    FROM support_tickets
    GROUP BY priority
)
SELECT
    priority,
    total_tickets,
    avg_resolution_hrs,
    median_resolution_hrs,
    avg_first_response_mins,
    avg_csat,
    escalation_rate_pct,
    sla_breaches,
    ROUND(sla_breaches * 100.0 / NULLIF(total_tickets, 0), 1) AS sla_breach_pct,
    open_tickets
FROM ticket_metrics
ORDER BY
    CASE priority
        WHEN 'urgent' THEN 1
        WHEN 'high'   THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low'    THEN 4
    END;

-- =============================================================
-- SECTION 9 — Upgrade and downgrade funnel
-- Uses upgrade_flag and downgrade_flag on the subscriptions table.
-- Net expansion = upgrades minus downgrades per plan tier.
-- Helps identify which tiers are growing and which industries drive movement.
-- =============================================================
WITH movement AS (
    SELECT
        s.account_id,
        s.plan_tier,
        s.mrr_amount,
        a.industry,
        s.upgrade_flag,
        s.downgrade_flag,
        DATE_TRUNC('month', s.start_date)::DATE AS movement_month
    FROM subscriptions s
    JOIN accounts a ON s.account_id = a.account_id
    WHERE s.is_trial = FALSE
      AND s.mrr_amount > 0
      AND (s.upgrade_flag = TRUE OR s.downgrade_flag = TRUE)
)
SELECT
    plan_tier,
    industry,
    movement_month,
    COUNT(CASE WHEN upgrade_flag   THEN 1 END) AS upgrades,
    COUNT(CASE WHEN downgrade_flag THEN 1 END) AS downgrades,
    COUNT(CASE WHEN upgrade_flag   THEN 1 END)
        - COUNT(CASE WHEN downgrade_flag THEN 1 END) AS net_expansion,
    ROUND(SUM(CASE WHEN upgrade_flag   THEN mrr_amount ELSE 0 END), 2) AS upgrade_mrr,
    ROUND(SUM(CASE WHEN downgrade_flag THEN mrr_amount ELSE 0 END), 2) AS downgrade_mrr
FROM movement
GROUP BY plan_tier, industry, movement_month
ORDER BY movement_month, plan_tier;

-- =============================================================
-- SECTION 10 — Churn deep-dive: reason × plan tier + reactivations
-- Cross-tab shows whether Enterprise churns for different reasons
-- than Basic/Pro. preceding_upgrade/downgrade flags show whether
-- a plan change preceded the churn — useful for identifying
-- downgrade-to-churn patterns.
-- Reactivation rate: accounts with is_reactivation = TRUE
-- came back after a previous churn event.
-- =============================================================
WITH churn_detail AS (
    SELECT
        ce.account_id,
        a.plan_tier,
        a.industry,
        ce.reason_code,
        ce.churn_date,
        ce.refund_amount_usd,
        ce.preceding_upgrade_flag,
        ce.preceding_downgrade_flag,
        ce.is_reactivation,
        DATE_TRUNC('month', ce.churn_date)::DATE AS churn_month,
        DATE_TRUNC('quarter', ce.churn_date)::DATE AS churn_quarter
    FROM churn_events ce
    JOIN accounts a ON ce.account_id = a.account_id
)
SELECT
    plan_tier,
    reason_code,
    COUNT(*)                                                AS churn_events,
    COUNT(DISTINCT account_id)                             AS unique_accounts,
    ROUND(AVG(refund_amount_usd), 2)                       AS avg_refund_usd,
    SUM(CASE WHEN preceding_downgrade_flag THEN 1 ELSE 0 END) AS preceded_by_downgrade,
    SUM(CASE WHEN preceding_upgrade_flag   THEN 1 ELSE 0 END) AS preceded_by_upgrade,
    SUM(CASE WHEN is_reactivation          THEN 1 ELSE 0 END) AS reactivations,
    ROUND(
        SUM(CASE WHEN is_reactivation THEN 1.0 ELSE 0.0 END)
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                       AS reactivation_rate_pct
FROM churn_detail
GROUP BY plan_tier, reason_code
ORDER BY plan_tier, churn_events DESC;
