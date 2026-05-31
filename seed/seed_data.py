#!/usr/bin/env python3
import os
import random
import string
import hashlib
from datetime import datetime, timedelta, timezone

import psycopg


def env_int(name, default):
    value = os.getenv(name)
    if value is None or value == "":
        return default
    try:
        return int(value)
    except ValueError:
        return default


def env_float(name, default):
    value = os.getenv(name)
    if value is None or value == "":
        return default
    try:
        return float(value)
    except ValueError:
        return default


def random_date_within(days):
    offset = random.randint(0, max(days, 1) - 1)
    seconds = random.randint(0, 86399)
    return datetime.now(timezone.utc) - timedelta(days=offset, seconds=seconds)


def random_email(first_name, last_name, index):
    suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=4))
    return f"{first_name}.{last_name}.{index}.{suffix}@example.com".lower()


def hash_card_number(card_number):
    return hashlib.sha256(card_number.encode("utf-8")).hexdigest()


def main():
    random_seed = os.getenv("SEED_RANDOM")
    if random_seed is not None:
        random.seed(random_seed)

    customers_count = env_int("SEED_CUSTOMERS", 20)
    accounts_per_customer = env_int("SEED_ACCOUNTS_PER_CUSTOMER", 2)
    cards_per_account = env_int("SEED_CARDS_PER_ACCOUNT", 2)
    transactions_per_account = env_int("SEED_TRANSACTIONS_PER_ACCOUNT", 15)
    high_risk_ratio = env_float("SEED_HIGH_RISK_RATIO", 0.15)
    reset_data = os.getenv("SEED_RESET", "0") == "1"

    dsn = {
        "host": os.getenv("PGHOST", "postgres"),
        "port": os.getenv("PGPORT", "5432"),
        "dbname": os.getenv("PGDATABASE", "postgres"),
        "user": os.getenv("PGUSER", "postgres"),
        "password": os.getenv("PGPASSWORD", "supersecretpassword"),
    }

    first_names = [
        "Alex", "Jordan", "Morgan", "Taylor", "Sam",
        "Casey", "Jamie", "Riley", "Avery", "Dakota",
        "Cameron", "Parker", "Quinn", "Hayden", "Rowan",
    ]
    last_names = [
        "Smith", "Johnson", "Williams", "Brown", "Jones",
        "Miller", "Davis", "Garcia", "Rodriguez", "Wilson",
        "Anderson", "Thomas", "Jackson", "White", "Harris",
    ]
    safe_countries = ["US", "GB", "DE", "FR", "NL", "SE", "PL", "UA", "CA", "AU"]
    high_risk_countries = ["IR", "KP", "SY", "AF", "IQ", "SO", "SD", "SS", "YE", "RU", "BY", "VE"]
    currencies = ["UAH", "USD", "EUR"]
    merchant_categories = [
        "GROCERY", "ELECTRONICS", "TRAVEL", "FUEL", "RESTAURANT",
        "ONLINE", "HEALTH", "RETAIL", "ENTERTAINMENT", "TRANSFER",
    ]

    used_card_hashes = set()
    used_account_numbers = set()

    with psycopg.connect(**dsn) as conn:
        with conn.cursor() as cur:
            if reset_data:
                cur.execute(
                    """
                    TRUNCATE TABLE
                        fraud_alerts,
                        transaction_status_history,
                        transactions,
                        cards,
                        accounts,
                        customers,
                        fraud_rules,
                        audit_log
                    RESTART IDENTITY CASCADE;
                    """
                )

            cur.execute(
                """
                INSERT INTO fraud_rules (rule_name, rule_type, threshold_value, is_active)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (rule_name) DO NOTHING;
                """,
                ("default_risk_threshold", "RISK_SCORE", 70, True),
            )

            customers = []
            accounts = []
            cards_by_account = {}

            for i in range(customers_count):
                first_name = random.choice(first_names)
                last_name = random.choice(last_names)
                email = random_email(first_name, last_name, i + 1)
                birth_date = datetime.now().date() - timedelta(days=random.randint(22 * 365, 65 * 365))
                country_code = random.choice(safe_countries)

                cur.execute(
                    """
                    INSERT INTO customers (first_name, last_name, email, birth_date, country_code)
                    VALUES (%s, %s, %s, %s, %s)
                    RETURNING customer_id;
                    """,
                    (first_name, last_name, email, birth_date, country_code),
                )
                customer_id = cur.fetchone()[0]
                customers.append(customer_id)

                account_count = max(1, accounts_per_customer)
                for a_idx in range(account_count):
                    account_number = f"ACCT-{customer_id}-{a_idx + 1:03d}"
                    while account_number in used_account_numbers:
                        account_number = f"ACCT-{customer_id}-{random.randint(100, 999)}"
                    used_account_numbers.add(account_number)

                    currency = random.choice(currencies)
                    balance = round(random.uniform(20000, 80000), 2)
                    status = "ACTIVE"

                    cur.execute(
                        """
                        INSERT INTO accounts (customer_id, account_number, currency, balance, status)
                        VALUES (%s, %s, %s, %s, %s)
                        RETURNING account_id;
                        """,
                        (customer_id, account_number, currency, balance, status),
                    )
                    account_id = cur.fetchone()[0]
                    accounts.append({
                        "account_id": account_id,
                        "customer_id": customer_id,
                        "currency": currency,
                        "balance": balance,
                    })

                    card_count = max(1, cards_per_account)
                    cards = []
                    for c_idx in range(card_count):
                        card_number = "".join(random.choices(string.digits, k=16))
                        card_hash = hash_card_number(card_number)
                        while card_hash in used_card_hashes:
                            card_number = "".join(random.choices(string.digits, k=16))
                            card_hash = hash_card_number(card_number)
                        used_card_hashes.add(card_hash)

                        card_type = random.choice(["DEBIT", "CREDIT", "VIRTUAL"])
                        card_status = "ACTIVE"
                        if c_idx == 0 and card_count > 1:
                            card_status = "BLOCKED"
                        expiration_date = (datetime.now().date() + timedelta(days=365 * random.randint(1, 4)))

                        cur.execute(
                            """
                            INSERT INTO cards (account_id, card_number_hash, card_type, status, expiration_date)
                            VALUES (%s, %s, %s, %s, %s)
                            RETURNING card_id;
                            """,
                            (account_id, card_hash, card_type, card_status, expiration_date),
                        )
                        card_id = cur.fetchone()[0]
                        cards.append({"card_id": card_id, "status": card_status})

                    cards_by_account[account_id] = cards

            for account in accounts:
                account_id = account["account_id"]
                currency = account["currency"]
                balance = account["balance"]
                cards = cards_by_account[account_id]
                active_cards = [c for c in cards if c["status"] == "ACTIVE"]
                blocked_cards = [c for c in cards if c["status"] == "BLOCKED"]

                for _ in range(max(1, transactions_per_account)):
                    is_high_risk = random.random() < high_risk_ratio

                    if is_high_risk and blocked_cards:
                        card = random.choice(blocked_cards)
                        amount = round(random.uniform(12000, 25000), 2)
                        merchant_country = random.choice(high_risk_countries)
                    else:
                        card = random.choice(active_cards or cards)
                        amount = round(random.uniform(5, 500), 2)
                        merchant_country = random.choice(safe_countries)
                        if balance <= amount:
                            amount = max(1, round(balance * 0.5, 2))

                    merchant_category = random.choice(merchant_categories)
                    transaction_at = random_date_within(30)

                    cur.execute(
                        """
                        INSERT INTO transactions (
                            account_id,
                            card_id,
                            amount,
                            currency,
                            merchant_category,
                            merchant_country,
                            transaction_at
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s);
                        """,
                        (
                            account_id,
                            card["card_id"],
                            amount,
                            currency,
                            merchant_category,
                            merchant_country,
                            transaction_at,
                        ),
                    )

                    if not is_high_risk:
                        balance = round(balance - amount, 2)
                        if balance < 0:
                            balance = 0

            print(
                f"Seeded {customers_count} customers, "
                f"{len(accounts)} accounts, "
                f"{len(accounts) * max(1, cards_per_account)} cards, "
                f"{len(accounts) * max(1, transactions_per_account)} transactions."
            )


if __name__ == "__main__":
    main()
