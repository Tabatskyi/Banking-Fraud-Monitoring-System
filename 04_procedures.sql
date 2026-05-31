CREATE OR REPLACE PROCEDURE create_fraud_alert(
    p_transaction_id BIGINT,
    p_reason TEXT,
    p_risk_score INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM fraud_alerts fa
        WHERE fa.transaction_id = p_transaction_id
          AND fa.alert_status = 'OPEN'
    ) THEN
        RETURN;
    END IF;

    INSERT INTO fraud_alerts (
        transaction_id,
        rule_id,
        reason,
        risk_score,
        alert_status,
        created_at
    ) VALUES (
        p_transaction_id,
        NULL,
        p_reason,
        p_risk_score,
        'OPEN',
        NOW()
    );
END;
$$;

CREATE OR REPLACE PROCEDURE freeze_account(p_account_id BIGINT)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE accounts
    SET status = 'FROZEN'
    WHERE account_id = p_account_id
      AND status <> 'FROZEN';
END;
$$;

CREATE OR REPLACE PROCEDURE process_transaction(p_transaction_id BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_risk_score INT;
    v_current_status TEXT;
    v_risk_threshold INT := 70;
BEGIN
    SELECT t.status
    INTO v_current_status
    FROM transactions t
    WHERE t.transaction_id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_current_status NOT IN ('PENDING', 'FLAGGED') THEN
        RETURN;
    END IF;

    v_risk_score := calculate_transaction_risk_score(p_transaction_id);

    IF v_risk_score >= v_risk_threshold THEN
        UPDATE transactions
        SET risk_score = v_risk_score,
            status = 'FLAGGED'
        WHERE transaction_id = p_transaction_id;

        CALL create_fraud_alert(
            p_transaction_id,
            'Auto-flagged: risk_score >= ' || v_risk_threshold,
            v_risk_score
        );
    ELSE
        UPDATE transactions
        SET risk_score = v_risk_score,
            status = 'APPROVED'
        WHERE transaction_id = p_transaction_id;
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE approve_pending_transactions()
LANGUAGE plpgsql
AS $$
DECLARE
    v_transaction_id BIGINT;
BEGIN
    FOR v_transaction_id IN
        SELECT t.transaction_id
        FROM transactions t
        WHERE t.status = 'PENDING'
    LOOP
        CALL process_transaction(v_transaction_id);
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE refresh_fraud_dashboard()
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE 'REFRESH MATERIALIZED VIEW mv_daily_fraud_summary';
END;
$$;
