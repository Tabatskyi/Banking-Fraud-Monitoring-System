CREATE OR REPLACE FUNCTION is_high_risk_country(p_country_code TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT upper(trim(p_country_code)) = ANY (
        ARRAY['IR', 'KP', 'SY', 'AF', 'IQ', 'SO', 'SD', 'SS', 'YE', 'RU', 'BY', 'VE']
    );
$$;

CREATE OR REPLACE FUNCTION mask_card_number(p_card_number TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_card_number IS NULL THEN NULL
        WHEN length(p_card_number) <= 4 THEN p_card_number
        ELSE repeat('X', length(p_card_number) - 4) || right(p_card_number, 4)
    END;
$$;

CREATE OR REPLACE FUNCTION get_customer_age(p_customer_id BIGINT)
RETURNS INT
LANGUAGE SQL
STABLE
AS $$
    SELECT EXTRACT(YEAR FROM age(current_date, c.birth_date))::INT
    FROM customers c
    WHERE c.customer_id = p_customer_id;
$$;

CREATE OR REPLACE FUNCTION calculate_customer_daily_volume(
    p_customer_id BIGINT,
    p_target_date DATE
)
RETURNS NUMERIC
LANGUAGE SQL
STABLE
AS $$
    SELECT COALESCE(SUM(t.amount), 0)
    FROM accounts a
    JOIN transactions t ON t.account_id = a.account_id
    WHERE a.customer_id = p_customer_id
      AND t.transaction_at::date = p_target_date
      AND t.status IN ('PENDING', 'APPROVED', 'FLAGGED');
$$;

CREATE OR REPLACE FUNCTION calculate_transaction_risk_score(p_transaction_id BIGINT)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_amount NUMERIC;
    v_country CHAR(2);
    v_currency CHAR(3);
    v_account_currency CHAR(3);
    v_account_status TEXT;
    v_card_status TEXT;
    v_customer_id BIGINT;
    v_transaction_date DATE;
    v_daily_volume NUMERIC := 0;
    v_score INT := 0;
BEGIN
    SELECT
        t.amount,
        t.merchant_country,
        t.currency,
        a.currency,
        a.status,
        c.status,
        a.customer_id,
        t.transaction_at::date
    INTO
        v_amount,
        v_country,
        v_currency,
        v_account_currency,
        v_account_status,
        v_card_status,
        v_customer_id,
        v_transaction_date
    FROM transactions t
    JOIN accounts a ON a.account_id = t.account_id
    JOIN cards c ON c.card_id = t.card_id
    WHERE t.transaction_id = p_transaction_id;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    IF is_high_risk_country(v_country) THEN
        v_score := v_score + 35;
    END IF;

    IF v_amount >= 10000 THEN
        v_score := v_score + 30;
    ELSIF v_amount >= 5000 THEN
        v_score := v_score + 20;
    ELSIF v_amount >= 1000 THEN
        v_score := v_score + 10;
    END IF;

    IF v_currency IS DISTINCT FROM v_account_currency THEN
        v_score := v_score + 10;
    END IF;

    IF v_account_status <> 'ACTIVE' THEN
        v_score := v_score + 20;
    END IF;

    IF v_card_status <> 'ACTIVE' THEN
        v_score := v_score + 15;
    END IF;

    v_daily_volume := calculate_customer_daily_volume(v_customer_id, v_transaction_date);

    IF v_daily_volume >= 20000 THEN
        v_score := v_score + 20;
    ELSIF v_daily_volume >= 10000 THEN
        v_score := v_score + 10;
    END IF;

    RETURN LEAST(v_score, 100);
END;
$$;
