-- ICT371 QUESTION 1: PHARMACY STOCK AND DAILY SALES
-- PostgreSQL / PLpgSQL. Run this whole file in pgAdmin Query Tool.

DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path TO q1_pharmacy;

CREATE TABLE medicines (
    medicine_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id BIGINT NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on TIMESTAMP NOT NULL
);
CREATE TABLE stock_audit (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id BIGINT NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty BIGINT NOT NULL,
    total_amount NUMERIC(14,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol', 2.50, 100),
('Amoxicillin', 8.00, 60),
('Vitamin C', 5.00, 40);

-- (b) Function: returns current price x quantity.
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id BIGINT, p_quantity INTEGER)
RETURNS NUMERIC(14,2)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive integer';
    END IF;
    SELECT unit_price INTO v_price
    FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine ID: %', p_medicine_id; END IF;
    RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure: lock row, check stock, record sale, deduct stock once.
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id BIGINT, p_quantity INTEGER, p_sold_on TIMESTAMP
)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 OR p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Quantity must be positive and sale date is required';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine ID: %', p_medicine_id; END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Available %, requested %', v_stock, p_quantity;
    END IF;
    INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger: audit only actual stock changes.
CREATE OR REPLACE FUNCTION fn_audit_stock_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_audit_stock_change
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION fn_audit_stock_change();

-- (e) View.
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines WHERE stock_qty < 10;

-- (f) Index and demonstration query.
CREATE INDEX idx_sales_medicine_sold_on
ON sales(medicine_id, sold_on);
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on >= TIMESTAMP '2026-01-01 00:00:00'
  AND sold_on <  TIMESTAMP '2027-01-01 00:00:00';

-- Load six sales through the procedure (not direct INSERT).
CALL pr_record_sale(1, 5, TIMESTAMP '2026-11-20 09:00:00');
CALL pr_record_sale(2, 2, TIMESTAMP '2026-11-20 10:00:00');
CALL pr_record_sale(3, 4, TIMESTAMP '2026-11-20 11:00:00');
CALL pr_record_sale(1, 3, TIMESTAMP '2026-11-21 09:30:00');
CALL pr_record_sale(2, 1, TIMESTAMP '2026-11-21 10:30:00');
CALL pr_record_sale(3, 2, TIMESTAMP '2026-11-21 11:30:00');

-- (g) Idempotent daily refresh: delete/replace that date's summary.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN RAISE EXCEPTION 'Date is required'; END IF;
    INSERT INTO daily_sales(sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on >= p_day::timestamp
      AND sold_on < (p_day + 1)::timestamp
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Test results.
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;
SELECT * FROM v_low_stock;
CALL pr_refresh_sales(DATE '2026-11-20');
SELECT * FROM daily_sales ORDER BY sales_date;

-- pg_cron scheduling is shown in README.md. It requires server-side installation.
