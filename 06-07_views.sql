CREATE OR REPLACE VIEW vw_customer_accounts AS
SELECT
    c.customer_id,
    c.first_name,
    c.last_name,
    c.email,
    c.country_code,
    c.is_active,
    a.account_id,
    a.account_number,
    a.currency,
    a.balance,
    a.status AS account_status,
    a.opened_at
FROM customers c
LEFT JOIN accounts a ON a.customer_id = c.customer_id;

CREATE OR REPLACE VIEW vw_recent_transactions AS
SELECT
    t.transaction_id,
    t.transaction_at,
    t.amount,
    t.currency,
    t.merchant_category,
    t.merchant_country,
    t.status,
    t.risk_score,
    a.account_id,
    a.account_number,
    c.customer_id,
    c.first_name,
    c.last_name,
    cd.card_id,
    cd.card_type,
    cd.status AS card_status
FROM transactions t
JOIN accounts a ON a.account_id = t.account_id
JOIN customers c ON c.customer_id = a.customer_id
LEFT JOIN cards cd ON cd.card_id = t.card_id
WHERE t.transaction_at >= NOW() - INTERVAL '30 days';

CREATE OR REPLACE VIEW vw_flagged_transactions AS
SELECT
    t.transaction_id,
    t.transaction_at,
    t.amount,
    t.currency,
    t.merchant_category,
    t.merchant_country,
    t.status,
    t.risk_score,
    a.account_id,
    a.account_number,
    c.customer_id,
    c.first_name,
    c.last_name,
    fa.alert_id,
    fa.alert_status,
    fa.reason,
    fa.created_at AS alert_created_at
FROM transactions t
JOIN accounts a ON a.account_id = t.account_id
JOIN customers c ON c.customer_id = a.customer_id
LEFT JOIN LATERAL (
    SELECT fa1.*
    FROM fraud_alerts fa1
    WHERE fa1.transaction_id = t.transaction_id
    ORDER BY fa1.created_at DESC
    LIMIT 1
) fa ON TRUE
WHERE t.status = 'FLAGGED';

CREATE OR REPLACE VIEW vw_customer_risk_profile AS
SELECT
    c.customer_id,
    c.first_name,
    c.last_name,
    c.country_code,
    c.is_active,
    COUNT(t.transaction_id) AS total_transactions,
    COUNT(*) FILTER (WHERE t.status = 'FLAGGED') AS flagged_transactions,
    COALESCE(ROUND(AVG(t.risk_score)::NUMERIC, 2), 0) AS avg_risk_score,
    COALESCE(SUM(t.amount), 0) AS total_transaction_amount,
    MAX(t.transaction_at) AS last_transaction_at,
    COUNT(*) FILTER (WHERE is_high_risk_country(t.merchant_country)) AS high_risk_country_transactions
FROM customers c
LEFT JOIN accounts a ON a.customer_id = c.customer_id
LEFT JOIN transactions t ON t.account_id = a.account_id
GROUP BY
    c.customer_id,
    c.first_name,
    c.last_name,
    c.country_code,
    c.is_active;

DROP MATERIALIZED VIEW IF EXISTS mv_daily_fraud_summary;
CREATE MATERIALIZED VIEW mv_daily_fraud_summary AS
WITH base AS (
    SELECT
        t.transaction_id,
        t.transaction_at::date AS transaction_date,
        t.amount,
        t.risk_score,
        t.status,
        a.customer_id,
        c.first_name,
        c.last_name
    FROM transactions t
    JOIN accounts a ON a.account_id = t.account_id
    JOIN customers c ON c.customer_id = a.customer_id
),
daily AS (
    SELECT
        transaction_date,
        COUNT(*) AS total_transactions,
        COALESCE(SUM(amount), 0) AS total_transaction_amount,
        COUNT(*) FILTER (WHERE status = 'FLAGGED') AS flagged_transactions,
        COALESCE(SUM(amount) FILTER (WHERE status = 'FLAGGED'), 0) AS suspicious_transaction_amount,
        COALESCE(ROUND(AVG(risk_score)::NUMERIC, 2), 0) AS avg_risk_score
    FROM base
    GROUP BY transaction_date
),
daily_alerts AS (
    SELECT
        t.transaction_at::date AS transaction_date,
        COUNT(fa.alert_id) AS total_fraud_alerts
    FROM transactions t
    JOIN fraud_alerts fa ON fa.transaction_id = t.transaction_id
    GROUP BY t.transaction_at::date
),
top_customers AS (
    SELECT
        transaction_date,
        STRING_AGG(customer_label, ', ' ORDER BY avg_risk_score DESC, customer_id) AS top_risky_customers
    FROM (
        SELECT
            b.transaction_date,
            b.customer_id,
            b.first_name,
            b.last_name,
            ROUND(AVG(b.risk_score)::NUMERIC, 2) AS avg_risk_score,
            (b.first_name || ' ' || b.last_name || ' (' || b.customer_id || ')') AS customer_label,
            ROW_NUMBER() OVER (
                PARTITION BY b.transaction_date
                ORDER BY AVG(b.risk_score) DESC, b.customer_id
            ) AS rn
        FROM base b
        GROUP BY b.transaction_date, b.customer_id, b.first_name, b.last_name
    ) ranked
    WHERE rn <= 3
    GROUP BY transaction_date
)
SELECT
    d.transaction_date,
    d.total_transactions,
    d.total_transaction_amount,
    d.flagged_transactions,
    d.suspicious_transaction_amount,
    d.avg_risk_score,
    COALESCE(tc.top_risky_customers, '') AS top_risky_customers,
    COALESCE(da.total_fraud_alerts, 0) AS total_fraud_alerts
FROM daily d
LEFT JOIN top_customers tc ON tc.transaction_date = d.transaction_date
LEFT JOIN daily_alerts da ON da.transaction_date = d.transaction_date
ORDER BY d.transaction_date;

CREATE INDEX IF NOT EXISTS idx_mv_daily_fraud_summary_date
ON mv_daily_fraud_summary (transaction_date);
