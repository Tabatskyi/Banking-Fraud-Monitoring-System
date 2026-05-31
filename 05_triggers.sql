CREATE OR REPLACE FUNCTION trg_transactions_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_risk_score INT;
    v_threshold INT;
BEGIN
    SELECT fr.threshold_value
    INTO v_threshold
    FROM fraud_rules fr
    WHERE fr.is_active
      AND fr.rule_type = 'RISK_SCORE'
    ORDER BY fr.rule_id
    LIMIT 1;

    IF v_threshold IS NULL THEN
        v_threshold := 70;
    END IF;

    v_risk_score := calculate_transaction_risk_score(NEW.transaction_id);

    IF NEW.status NOT IN ('PENDING', 'FLAGGED') THEN
        UPDATE transactions
        SET risk_score = v_risk_score
        WHERE transaction_id = NEW.transaction_id;
        RETURN NEW;
    END IF;

    IF v_risk_score >= v_threshold THEN
        UPDATE transactions
        SET risk_score = v_risk_score,
            status = 'FLAGGED'
        WHERE transaction_id = NEW.transaction_id;

        IF NOT EXISTS (
            SELECT 1
            FROM fraud_alerts fa
            WHERE fa.transaction_id = NEW.transaction_id
              AND fa.alert_status = 'OPEN'
        ) THEN
            INSERT INTO fraud_alerts (
                transaction_id,
                rule_id,
                reason,
                risk_score,
                alert_status,
                created_at
            ) VALUES (
                NEW.transaction_id,
                NULL,
                'Auto-flagged: risk_score >= ' || v_threshold,
                v_risk_score,
                'OPEN',
                NOW()
            );
        END IF;
    ELSE
        UPDATE transactions
        SET risk_score = v_risk_score,
            status = 'APPROVED'
        WHERE transaction_id = NEW.transaction_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_transactions_after_insert ON transactions;
CREATE TRIGGER tr_transactions_after_insert
AFTER INSERT ON transactions
FOR EACH ROW
EXECUTE FUNCTION trg_transactions_after_insert();

CREATE OR REPLACE FUNCTION trg_transactions_status_history()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO transaction_status_history (
            transaction_id,
            old_status,
            new_status,
            changed_at,
            changed_by
        ) VALUES (
            NEW.transaction_id,
            OLD.status,
            NEW.status,
            NOW(),
            COALESCE(current_setting('app.user', true), current_user)
        );
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_transactions_status_history ON transactions;
CREATE TRIGGER tr_transactions_status_history
AFTER UPDATE OF status ON transactions
FOR EACH ROW
EXECUTE FUNCTION trg_transactions_status_history();

CREATE OR REPLACE FUNCTION trg_transactions_update_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_account_currency CHAR(3);
BEGIN
    IF NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM NEW.status THEN
        SELECT a.currency
        INTO v_account_currency
        FROM accounts a
        WHERE a.account_id = NEW.account_id
        FOR UPDATE;

        IF v_account_currency IS DISTINCT FROM NEW.currency THEN
            RAISE EXCEPTION 'Transaction currency % does not match account currency %',
                NEW.currency, v_account_currency;
        END IF;

        UPDATE accounts
        SET balance = balance - NEW.amount
        WHERE account_id = NEW.account_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_transactions_update_balance ON transactions;
CREATE TRIGGER tr_transactions_update_balance
AFTER UPDATE OF status ON transactions
FOR EACH ROW
EXECUTE FUNCTION trg_transactions_update_balance();

CREATE OR REPLACE FUNCTION prevent_customer_delete_with_active_accounts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM accounts a
        WHERE a.customer_id = OLD.customer_id
          AND a.status <> 'CLOSED'
    ) THEN
        RAISE EXCEPTION 'Cannot delete customer %: active accounts exist', OLD.customer_id;
    END IF;

    RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS tr_customers_prevent_delete ON customers;
CREATE TRIGGER tr_customers_prevent_delete
BEFORE DELETE ON customers
FOR EACH ROW
EXECUTE FUNCTION prevent_customer_delete_with_active_accounts();

CREATE OR REPLACE FUNCTION audit_log_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id BIGINT;
    v_account_id BIGINT;
    v_old JSONB;
    v_new JSONB;
    v_row JSONB;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_new := to_jsonb(NEW);
        v_row := v_new;
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_new := to_jsonb(NEW);
        v_row := v_new;
    ELSE
        v_old := to_jsonb(OLD);
        v_row := v_old;
    END IF;

    IF v_row ? 'customer_id' THEN
        v_customer_id := (v_row->>'customer_id')::BIGINT;
    ELSIF v_row ? 'account_id' THEN
        v_account_id := (v_row->>'account_id')::BIGINT;
        SELECT a.customer_id
        INTO v_customer_id
        FROM accounts a
        WHERE a.account_id = v_account_id;
    ELSE
        v_customer_id := NULL;
    END IF;

    INSERT INTO audit_log (
        customer_id,
        table_name,
        operation,
        old_value,
        new_value,
        changed_at
    ) VALUES (
        v_customer_id,
        TG_TABLE_NAME,
        TG_OP,
        v_old,
        v_new,
        NOW()
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_audit_customers ON customers;
CREATE TRIGGER tr_audit_customers
AFTER INSERT OR UPDATE OR DELETE ON customers
FOR EACH ROW
EXECUTE FUNCTION audit_log_trigger();

DROP TRIGGER IF EXISTS tr_audit_accounts ON accounts;
CREATE TRIGGER tr_audit_accounts
AFTER INSERT OR UPDATE OR DELETE ON accounts
FOR EACH ROW
EXECUTE FUNCTION audit_log_trigger();

DROP TRIGGER IF EXISTS tr_audit_cards ON cards;
CREATE TRIGGER tr_audit_cards
AFTER INSERT OR UPDATE OR DELETE ON cards
FOR EACH ROW
EXECUTE FUNCTION audit_log_trigger();

DROP TRIGGER IF EXISTS tr_audit_transactions ON transactions;
CREATE TRIGGER tr_audit_transactions
AFTER INSERT OR UPDATE OR DELETE ON transactions
FOR EACH ROW
EXECUTE FUNCTION audit_log_trigger();

DROP TRIGGER IF EXISTS tr_audit_fraud_rules ON fraud_rules;
CREATE TRIGGER tr_audit_fraud_rules
AFTER INSERT OR UPDATE OR DELETE ON fraud_rules
FOR EACH ROW
EXECUTE FUNCTION audit_log_trigger();

DROP TRIGGER IF EXISTS tr_audit_fraud_alerts ON fraud_alerts;
CREATE TRIGGER tr_audit_fraud_alerts
AFTER INSERT OR UPDATE OR DELETE ON fraud_alerts
FOR EACH ROW
EXECUTE FUNCTION audit_log_trigger();
