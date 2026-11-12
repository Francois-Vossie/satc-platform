-- =============================================================================
-- SATC e-commerce platform - RDS PostgreSQL 16 schema (database "satc")
-- Relational store for transactional data that needs ACID guarantees:
-- customers, orders, order lines, payments, shipments and the audit log.
-- Product catalogue and live stock levels live in DynamoDB (see README).
-- =============================================================================
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- query performance analysis
CREATE SCHEMA IF NOT EXISTS satc;
SET search_path = satc, public;
ALTER DATABASE satc SET search_path = satc, public;   -- new sessions (Lambda, EC2) resolve tables in satc

-- ----------------------------------------------------------------------------- reference data
CREATE TABLE production_centres (
    centre_code     varchar(10)  PRIMARY KEY,                 -- e.g. BW-GAB, ZA-JHB
    name            varchar(120) NOT NULL,
    country_code    char(2)      NOT NULL CHECK (country_code IN ('BW', 'ZA', 'ZW', 'NA')),
    created_at      timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE artisans (
    artisan_id      uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    centre_code     varchar(10)  NOT NULL REFERENCES production_centres (centre_code),
    display_name    varchar(120) NOT NULL,
    craft           varchar(30)  NOT NULL CHECK (craft IN ('pottery', 'textiles', 'leather', 'wood-carvings', 'skincare', 'jewellery')),
    joined_on       date         NOT NULL DEFAULT current_date,
    active          boolean      NOT NULL DEFAULT true
);
CREATE INDEX ix_artisans_centre ON artisans (centre_code) WHERE active;

-- ----------------------------------------------------------------------------- customers (personal data - POPIA / GDPR)
CREATE TABLE customers (
    customer_sub    varchar(64)  PRIMARY KEY,                 -- Cognito user "sub" (no passwords stored here)
    email           varchar(254),
    full_name       varchar(160),
    country_code    char(2),
    marketing_opt_in boolean     NOT NULL DEFAULT false,      -- explicit consent, default off
    created_at      timestamptz  NOT NULL DEFAULT now(),
    anonymised_at   timestamptz                               -- set by anonymise_customer() (right to erasure)
);
CREATE UNIQUE INDEX ux_customers_email ON customers (lower(email)) WHERE email IS NOT NULL;

-- ----------------------------------------------------------------------------- orders
CREATE TABLE orders (
    order_id        uuid         PRIMARY KEY,
    customer_sub    varchar(64)  NOT NULL,
    status          varchar(20)  NOT NULL DEFAULT 'pending_payment'
                    CHECK (status IN ('pending_payment', 'paid', 'packed', 'shipped', 'delivered', 'cancelled', 'refunded')),
    payment_method  varchar(20)  NOT NULL CHECK (payment_method IN ('card', 'mobile_money')),
    shipping_country char(2)     NOT NULL,
    total_cents     integer      NOT NULL CHECK (total_cents >= 0),
    currency        char(3)      NOT NULL DEFAULT 'USD',
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now()
);
-- "my orders" page: newest first for one customer
CREATE INDEX ix_orders_customer_created ON orders (customer_sub, created_at DESC);
-- operations queue: only open orders are indexed (small, hot partial index)
CREATE INDEX ix_orders_open_status ON orders (status, created_at)
    WHERE status IN ('pending_payment', 'paid', 'packed');
-- monthly revenue reporting on the read replica
CREATE INDEX ix_orders_created_brin ON orders USING brin (created_at);

CREATE TABLE order_items (
    order_id        uuid         NOT NULL REFERENCES orders (order_id) ON DELETE CASCADE,
    sku             varchar(20)  NOT NULL,
    centre_code     varchar(10)  NOT NULL REFERENCES production_centres (centre_code),
    quantity        smallint     NOT NULL CHECK (quantity BETWEEN 1 AND 50),
    unit_price_cents integer     NOT NULL CHECK (unit_price_cents >= 0),
    PRIMARY KEY (order_id, sku)
);
-- sales per product and per production centre (artisan income reporting)
CREATE INDEX ix_order_items_sku ON order_items (sku);
CREATE INDEX ix_order_items_centre ON order_items (centre_code);

-- ----------------------------------------------------------------------------- payments (tokens only - no card numbers: PCI-DSS SAQ-A)
CREATE TABLE payments (
    payment_id      uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        uuid         NOT NULL REFERENCES orders (order_id),
    provider        varchar(20)  NOT NULL CHECK (provider IN ('stripe', 'mpesa', 'ecocash', 'orange_money')),
    provider_ref    varchar(100) NOT NULL,                    -- PaymentIntent id / mobile-money transaction id
    amount_cents    integer      NOT NULL CHECK (amount_cents >= 0),
    status          varchar(20)  NOT NULL CHECK (status IN ('initiated', 'succeeded', 'failed', 'refunded')),
    created_at      timestamptz  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_payments_provider_ref ON payments (provider, provider_ref);   -- idempotent webhooks
CREATE INDEX ix_payments_order ON payments (order_id);

-- ----------------------------------------------------------------------------- shipments
CREATE TABLE shipments (
    shipment_id     uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        uuid         NOT NULL REFERENCES orders (order_id),
    carrier         varchar(40)  NOT NULL,
    tracking_number varchar(60),
    dispatched_at   timestamptz,
    delivered_at    timestamptz
);
CREATE INDEX ix_shipments_order ON shipments (order_id);
CREATE UNIQUE INDEX ux_shipments_tracking ON shipments (carrier, tracking_number) WHERE tracking_number IS NOT NULL;

-- ----------------------------------------------------------------------------- audit log (append-only)
CREATE TABLE audit_log (
    audit_id        bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz  NOT NULL DEFAULT now(),
    actor           varchar(64)  NOT NULL,
    action          varchar(40)  NOT NULL,
    entity          varchar(40)  NOT NULL,
    entity_id       varchar(64)  NOT NULL,
    detail          jsonb
);
CREATE INDEX ix_audit_entity ON audit_log (entity, entity_id);

-- keep updated_at current
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;
CREATE TRIGGER trg_orders_touch BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ----------------------------------------------------------------------------- GDPR / POPIA data-subject rights
-- Right to erasure: personal data is removed, order rows are kept (tax law) but de-identified.
CREATE OR REPLACE FUNCTION anonymise_customer(p_sub varchar) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_pseudonym varchar := 'erased-' || substr(md5(p_sub), 1, 12);
BEGIN
    UPDATE customers
       SET email = NULL, full_name = NULL, marketing_opt_in = false, anonymised_at = now()
     WHERE customer_sub = p_sub;
    UPDATE orders SET customer_sub = v_pseudonym WHERE customer_sub = p_sub;
    INSERT INTO audit_log (actor, action, entity, entity_id) VALUES ('dpo', 'erasure', 'customer', v_pseudonym);
END $$;

-- Right to data portability: one machine-readable JSON document per customer.
CREATE OR REPLACE FUNCTION export_customer(p_sub varchar) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'customer', (SELECT to_jsonb(c) FROM customers c WHERE c.customer_sub = p_sub),
        'orders', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'order', to_jsonb(o),
                       'items', (SELECT jsonb_agg(to_jsonb(i)) FROM order_items i WHERE i.order_id = o.order_id)))
              FROM orders o WHERE o.customer_sub = p_sub), '[]'::jsonb)
    );
$$;

-- ----------------------------------------------------------------------------- least-privilege database roles
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user LOGIN;                 -- least-privilege application login (production)
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'report_reader') THEN
        CREATE ROLE report_reader LOGIN;            -- dashboards on the read replica
    END IF;
END $$;
GRANT USAGE ON SCHEMA satc TO app_user, report_reader;
GRANT SELECT, INSERT, UPDATE ON orders, order_items, payments, shipments, customers TO app_user;
GRANT INSERT ON audit_log TO app_user;
GRANT SELECT ON ALL TABLES IN SCHEMA satc TO report_reader;

COMMIT;
