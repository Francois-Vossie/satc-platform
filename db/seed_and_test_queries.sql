-- Sample data and the test queries used for the database functional test (Deliverable 5).
SET search_path = satc, public;

INSERT INTO production_centres (centre_code, name, country_code) VALUES
    ('BW-GAB', 'Gaborone Pottery Centre', 'BW'),
    ('BW-MAU', 'Maun Basketry and Leather', 'BW'),
    ('ZA-JHB', 'Johannesburg Textile Studio', 'ZA'),
    ('ZA-CPT', 'Cape Town Skincare Workshop', 'ZA'),
    ('ZW-BUL', 'Bulawayo Wood Carvers', 'ZW'),
    ('ZW-HRE', 'Harare Jewellery Collective', 'ZW'),
    ('NA-WDH', 'Windhoek Leather Works', 'NA'),
    ('NA-SWP', 'Swakopmund Craft Hub', 'NA')
ON CONFLICT DO NOTHING;

INSERT INTO customers (customer_sub, email, full_name, country_code, marketing_opt_in) VALUES
    ('test-sub-001', 'lerato@example.com', 'Lerato M', 'ZA', true),
    ('test-sub-002', 'jonas@example.de', 'Jonas K', 'DE', false)
ON CONFLICT DO NOTHING;

INSERT INTO orders (order_id, customer_sub, status, payment_method, shipping_country, total_cents) VALUES
    ('7b0c3a2e-1d4f-4a51-9f1e-000000000001', 'test-sub-001', 'paid', 'mobile_money', 'ZA', 21000),
    ('7b0c3a2e-1d4f-4a51-9f1e-000000000002', 'test-sub-002', 'pending_payment', 'card', 'DE', 12000)
ON CONFLICT DO NOTHING;

INSERT INTO order_items (order_id, sku, centre_code, quantity, unit_price_cents) VALUES
    ('7b0c3a2e-1d4f-4a51-9f1e-000000000001', 'POT-001', 'BW-GAB', 2, 4500),
    ('7b0c3a2e-1d4f-4a51-9f1e-000000000001', 'TEX-010', 'ZA-JHB', 1, 12000),
    ('7b0c3a2e-1d4f-4a51-9f1e-000000000002', 'TEX-010', 'ZA-JHB', 1, 12000)
ON CONFLICT DO NOTHING;

-- Q1: connection and TLS check (expect ssl = t)
SELECT current_user, inet_server_addr(), ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid();

-- Q2: revenue per production centre (artisan income reporting)
SELECT c.name, sum(i.quantity * i.unit_price_cents) / 100.0 AS revenue_usd
  FROM order_items i JOIN production_centres c USING (centre_code)
 GROUP BY c.name ORDER BY revenue_usd DESC;

-- Q3: prove the partial index is used for the open-orders queue (screenshot the plan)
EXPLAIN ANALYZE
SELECT order_id, status, created_at FROM orders
 WHERE status IN ('pending_payment', 'paid') ORDER BY created_at LIMIT 50;

-- Q4: data portability export for one customer
SELECT export_customer('test-sub-002');

-- Q5: slowest statements (pg_stat_statements)
SELECT left(query, 60) AS query, calls, round(mean_exec_time::numeric, 2) AS mean_ms
  FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 5;
