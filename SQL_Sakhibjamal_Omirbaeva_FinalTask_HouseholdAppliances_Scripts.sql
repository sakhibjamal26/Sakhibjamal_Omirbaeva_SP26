-- ============================================================
-- SQL Final Task
-- Author: Sakhibjamal Omirbaeva
-- Topic: appliance_store
-- Standard: 3NF
-- ============================================================
--
-- Note about creating the database:
-- The CREATE DATABASE statement cannot be executed from inside the
-- same database, so I run it manually once before running this script.
-- I keep it here as a comment for documentation:
--
--   CREATE DATABASE appliance_store
--       WITH OWNER = postgres
--       ENCODING = 'UTF8'
--       LC_COLLATE = 'en_US.UTF-8'
--       LC_CTYPE = 'en_US.UTF-8';
--
-- After the database is created, I connect to it and run this script
-- which creates the schema and everything inside it.
-- ============================================================

-- I drop and recreate the schema every time so the script stays
-- rerunnable. CASCADE removes everything inside (tables, functions,
-- views, etc.) so I don't have to drop them one by one.
DROP SCHEMA IF EXISTS appliance_store CASCADE;
CREATE SCHEMA appliance_store;
SET search_path TO appliance_store;


-- ============================================================
-- A note about the order of CREATE TABLE statements:
-- PostgreSQL checks foreign key references at the time the table
-- is created. So if I try to create products before categories,
-- I get "relation categories does not exist". That's why I always
-- create parent tables first and child tables after.
--
-- Build order in this file:
--   1. categories     (no FK)
--   2. suppliers      (no FK)
--   3. warehouses     (no FK)
--   4. customers      (no FK)
--   5. employees      (no FK)
--   6. products       -> categories
--   7. product_suppliers -> products, suppliers   (M:N)
--   8. inventory      -> products, warehouses     (M:N)
--   9. orders         -> customers, employees, warehouses
--  10. order_items    -> orders, products         (M:N)
-- ============================================================


-- ============================================================
-- TABLE: categories
-- I created this first because products references it. If I had
-- a category name on every product row, then renaming a category
-- would mean updating hundreds of products. With this table I
-- update one row and all related products see the new name.
-- ============================================================
CREATE TABLE categories (
    category_id     SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL UNIQUE,
    -- UNIQUE on name: I don't want two rows both called 'Refrigerators'
    -- because then a JOIN by name returns duplicates and reporting breaks.
    description     TEXT NULL,
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW()
    -- TIMESTAMPTZ instead of DATE so I can see the exact moment a row
    -- was created. With DATE I'd lose the order of inserts on the same day.
);


-- ============================================================
-- TABLE: suppliers
-- Independent table. A supplier exists on its own even before any
-- product is linked to them. The product_suppliers junction handles
-- which products come from which supplier.
-- ============================================================
CREATE TABLE suppliers (
    supplier_id     SERIAL PRIMARY KEY,
    company_name    VARCHAR(150) NOT NULL UNIQUE,
    -- UNIQUE: two suppliers can't have the exact same registered name
    -- in the system, otherwise procurement reports would be ambiguous.
    contact_phone   VARCHAR(20) NOT NULL,
    -- VARCHAR for phone since numbers contain '+' and spaces like
    -- '+998 71 150 30 30'. INTEGER would lose the '+' and any leading zeros.
    email           VARCHAR(255) NOT NULL UNIQUE,
    country         VARCHAR(100) NOT NULL,
    city            VARCHAR(100) NOT NULL,
    address         VARCHAR(300) NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    -- new suppliers start as active by default. NOT NULL is important —
    -- if it were nullable, WHERE is_active = TRUE would silently miss
    -- NULL rows and those suppliers would become invisible.
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- TABLE: warehouses
-- Independent table. Warehouses exist on their own — empty
-- warehouses are valid (just no inventory yet).
--
-- I picked NUMERIC(8,2) for capacity_m3 because volume can be a
-- decimal number like 4500.50 m³ and I need exact storage, not float.
-- ============================================================
CREATE TABLE warehouses (
    warehouse_id    SERIAL PRIMARY KEY,
    name            VARCHAR(150) NOT NULL UNIQUE,
    address         VARCHAR(300) NOT NULL,
    city            VARCHAR(100) NOT NULL,
    capacity_m3     NUMERIC(8,2) NOT NULL,
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- TABLE: customers
-- A customer can register and never place an order, so they exist
-- independently from orders.
-- ============================================================
CREATE TABLE customers (
    customer_id     SERIAL PRIMARY KEY,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    phone           VARCHAR(20) NOT NULL UNIQUE,
    -- UNIQUE phone: each phone number belongs to one customer in real
    -- life. Without UNIQUE, one person could register many accounts
    -- with the same phone and get duplicate promotions or skip limits.
    email           VARCHAR(255) NULL UNIQUE,
    -- email is nullable because not every walk-in customer gives one,
    -- but if they do give it, it must be unique.
    address         VARCHAR(300) NULL,
    -- address optional: walk-in customers buying in store and taking
    -- the appliance themselves don't need to give a delivery address.
    registered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- DEFAULT NOW() so the app doesn't have to send this value —
    -- the database fills it in automatically when the row is created.
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- TABLE: employees
-- I used VARCHAR(50) for role rather than an ENUM type because
-- if the business adds a new role later (say 'delivery') I just
-- update the CHECK constraint instead of running ALTER TYPE.
-- ============================================================
CREATE TABLE employees (
    employee_id     SERIAL PRIMARY KEY,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    role            VARCHAR(50) NOT NULL,
    -- specific allowed values are enforced by an ALTER TABLE CHECK
    -- constraint added later in this file (chk_employees_role_valid).
    phone           VARCHAR(20) NOT NULL UNIQUE,
    hired_at        TIMESTAMPTZ NOT NULL,
    -- the date constraint (hire date must be > 2026-01-01) is added
    -- via ALTER TABLE later, so all CHECK constraints live in one place.
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- TABLE: products
-- Child of categories. Has to be created after categories.
--
-- I chose NUMERIC(14,2) for price because UZS prices for appliances
-- can be 12,500,000.00 (premium fridge) or higher. NUMERIC(10,2)
-- only fits up to 99,999,999.99 which is risky for high-end models.
-- FLOAT would cause rounding errors in billing — never use FLOAT
-- for money.
--
-- I added a UNIQUE constraint on (brand, model) because each
-- brand+model pair represents one specific product in our catalogue.
-- Without this UNIQUE, the same model could be inserted twice and
-- inventory + sales reports would split across the duplicates.
-- ============================================================
CREATE TABLE products (
    product_id      SERIAL PRIMARY KEY,
    category_id     INTEGER NOT NULL
                    REFERENCES categories(category_id),
    -- FK to categories: without this I could insert a product with
    -- a category_id that points to nothing. Reports grouped by
    -- category would have orphan rows with no name to show.
    brand           VARCHAR(100) NOT NULL,
    model           VARCHAR(150) NOT NULL,
    price           NUMERIC(14,2) NOT NULL,
    warranty_months SMALLINT NOT NULL,
    color           VARCHAR(50) NULL,
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_products_brand_model UNIQUE (brand, model)
);


-- ============================================================
-- TABLE: product_suppliers
-- Junction table for the M:N between products and suppliers.
-- One product can come from multiple suppliers (e.g. Samsung
-- fridges supplied by both the official distributor and a
-- secondary wholesaler), and one supplier provides many products.
--
-- supply_price is the cost we pay the supplier — different from
-- the retail price on the products table. I store it here because
-- the same product from two different suppliers can have different
-- supply prices.
-- ============================================================
CREATE TABLE product_suppliers (
    product_supplier_id SERIAL PRIMARY KEY,
    product_id      INTEGER NOT NULL
                    REFERENCES products(product_id),
    supplier_id     INTEGER NOT NULL
                    REFERENCES suppliers(supplier_id),
    supply_price    NUMERIC(14,2) NOT NULL,
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_supplier UNIQUE (product_id, supplier_id)
    -- the same product+supplier pair should appear only once.
    -- Without this UNIQUE, the same supply relationship could be
    -- inserted multiple times and procurement totals would double-count.
);


-- ============================================================
-- TABLE: inventory
-- Junction table for the M:N between products and warehouses.
-- One product is stored in multiple warehouses, one warehouse
-- holds many products. stock_quantity is the count at this
-- specific warehouse.
--
-- I considered putting stock_quantity directly on products, but
-- then I couldn't track stock per location, which is what the
-- store actually needs to fulfil orders from the right warehouse.
-- ============================================================
CREATE TABLE inventory (
    inventory_id    SERIAL PRIMARY KEY,
    product_id      INTEGER NOT NULL
                    REFERENCES products(product_id),
    warehouse_id    INTEGER NOT NULL
                    REFERENCES warehouses(warehouse_id),
    stock_quantity  INTEGER NOT NULL,
    -- non-negative check is added via ALTER TABLE later.
    last_restocked_at TIMESTAMPTZ NULL,
    -- nullable because a brand-new inventory row may not have been
    -- restocked yet — initial stock counts as the first delivery.
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_inventory_product_warehouse UNIQUE (product_id, warehouse_id)
);


-- ============================================================
-- TABLE: orders
-- Child of customers, employees, and warehouses. The transaction
-- table — every order is one purchase event.
--
-- total_amount is a regular NUMERIC column rather than GENERATED
-- ALWAYS AS because it sums child rows in order_items, and Postgres
-- doesn't allow GENERATED columns to reference other tables. I keep
-- it consistent through the add_order() function which calculates
-- the sum on insert.
--
-- I picked status as VARCHAR(20) with a CHECK constraint (added via
-- ALTER TABLE later) instead of an ENUM type because adding new
-- statuses in the future is just an UPDATE to the constraint
-- definition, not an ALTER TYPE.
-- ============================================================
CREATE TABLE orders (
    order_id        SERIAL PRIMARY KEY,
    customer_id     INTEGER NOT NULL
                    REFERENCES customers(customer_id),
    employee_id     INTEGER NOT NULL
                    REFERENCES employees(employee_id),
    -- the salesperson responsible for this order. If they leave the
    -- company, we still need to know who handled past orders for
    -- accountability, so we just keep the FK and don't cascade delete.
    warehouse_id    INTEGER NOT NULL
                    REFERENCES warehouses(warehouse_id),
    -- which warehouse the order ships from.
    order_date      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- DEFAULT NOW() so most inserts don't need to specify the date.
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',
    -- DEFAULT 'pending' because new orders always start in this
    -- status — the app doesn't have to send it explicitly.
    total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- TABLE: order_items
-- Junction table for the M:N between orders and products.
-- One order has many products, one product appears on many orders.
--
-- unit_price is a snapshot of the product price at the time of
-- the order. I copy it here even though products.price exists
-- because if the retail price changes later, old orders should
-- still show what the customer actually paid — not the new price.
--
-- line_total is GENERATED ALWAYS AS so it can never be inconsistent
-- with quantity * unit_price. STORED means Postgres physically saves
-- the value and I can query it like a regular column.
-- IMPORTANT: I cannot insert into line_total directly — Postgres
-- will throw an error. The DML inserts below leave it out.
-- ============================================================
CREATE TABLE order_items (
    order_item_id   SERIAL PRIMARY KEY,
    order_id        INTEGER NOT NULL
                    REFERENCES orders(order_id),
    product_id      INTEGER NOT NULL
                    REFERENCES products(product_id),
    quantity        INTEGER NOT NULL,
    unit_price      NUMERIC(14,2) NOT NULL,
    line_total      NUMERIC(14,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    record_ts       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_order_items_order_product UNIQUE (order_id, product_id)
    -- same product appears at most once per order — if a customer
    -- wants two of the same fridge, that's quantity = 2, not two
    -- separate rows. Without this UNIQUE, summing quantities per
    -- order would over-count.
);


-- ============================================================
-- ALTER TABLE: CHECK CONSTRAINTS
--
-- The task asks for at least 5 named CHECK constraints added via
-- ALTER TABLE. I keep them in this dedicated section so they're
-- easy to find and review together rather than scattered inside
-- each CREATE TABLE block.
-- ============================================================

-- 1. Date constraint: orders cannot be dated before 2026-01-01
ALTER TABLE orders
    ADD CONSTRAINT chk_orders_date_after_2026
    CHECK (order_date > '2026-01-01'::TIMESTAMPTZ);
-- without this, a bug in the app could insert epoch dates like
-- 1970-01-01 which would silently distort all time-based reports.

-- 2. Date constraint: employees cannot be hired before 2026-01-01
ALTER TABLE employees
    ADD CONSTRAINT chk_employees_hired_after_2026
    CHECK (hired_at > '2026-01-01'::TIMESTAMPTZ);

-- 3. Non-negative measured value: stock can never be negative
ALTER TABLE inventory
    ADD CONSTRAINT chk_inventory_stock_nonneg
    CHECK (stock_quantity >= 0);
-- physically impossible to have negative stock; without this check,
-- a bug in the order pipeline could oversell and create -3 units,
-- breaking inventory reports.

-- 4. Non-negative measured value: prices must be strictly positive
ALTER TABLE products
    ADD CONSTRAINT chk_products_price_positive
    CHECK (price > 0);
-- a free product (0) or a negative price makes no business sense.

-- 5. Specific value: order status only takes these four values
ALTER TABLE orders
    ADD CONSTRAINT chk_orders_status_valid
    CHECK (status IN ('pending', 'shipped', 'delivered', 'cancelled'));
-- without this, someone could insert 'done' or 'OK' and status-based
-- filters would silently miss those orders.

-- 6. Specific value: employee role only takes these four values
ALTER TABLE employees
    ADD CONSTRAINT chk_employees_role_valid
    CHECK (role IN ('sales', 'manager', 'logistics', 'cashier'));

-- 7. Non-negative: order line quantity must be at least 1
ALTER TABLE order_items
    ADD CONSTRAINT chk_order_items_qty_positive
    CHECK (quantity > 0);
-- nobody buys zero or negative units of a fridge.

-- 8. Non-negative: warranty in months can be 0 (no warranty) or more
ALTER TABLE products
    ADD CONSTRAINT chk_products_warranty_nonneg
    CHECK (warranty_months >= 0);

-- 9. Non-negative: warehouse capacity has to be positive
ALTER TABLE warehouses
    ADD CONSTRAINT chk_warehouses_capacity_positive
    CHECK (capacity_m3 > 0);

-- 10. Non-negative: order total cannot be negative (refunds are
-- handled separately, not by negative totals on existing rows)
ALTER TABLE orders
    ADD CONSTRAINT chk_orders_total_nonneg
    CHECK (total_amount >= 0);


-- ============================================================
-- SAMPLE DATA
--
-- Rules I follow throughout the inserts:
--   1. Surrogate keys (the SERIAL PK columns) are NEVER inserted
--      manually — Postgres generates them. This is what the task
--      requires and also avoids ID collisions if the table already
--      has data.
--   2. Foreign keys are looked up by natural keys (name, phone,
--      brand+model) inside the SELECT. Nothing is hardcoded.
--   3. WHERE NOT EXISTS makes every block rerunnable — running
--      the script twice doesn't insert duplicates.
--   4. DEFAULT values are used wherever applicable so I don't
--      have to repeat them in the INSERT (record_ts, is_active,
--      registered_at, order status, etc.)
--   5. All dates fall within the last 3 months (Feb–Apr 2026)
--      so the time window matches the task requirement.
-- ============================================================


-- ============================================================
-- categories: 6 product categories
-- ============================================================
INSERT INTO categories (name, description) VALUES
    ('Refrigerators',    'Single-door, double-door and side-by-side refrigerators'),
    ('Washing Machines', 'Front-load and top-load washing machines for home use'),
    ('Televisions',      'LED, OLED and Smart TVs from 32 to 75 inches'),
    ('Air Conditioners', 'Split and window air conditioners with inverter and non-inverter types'),
    ('Microwaves',       'Solo, grill and convection microwave ovens'),
    ('Vacuum Cleaners',  'Bagged, bagless, robotic and handheld vacuum cleaners')
ON CONFLICT (name) DO NOTHING;


-- ============================================================
-- suppliers: 6 suppliers covering local and international brands
-- ============================================================
INSERT INTO suppliers (company_name, contact_phone, email, country, city, address) VALUES
    ('Samsung Electronics Uz',   '+998711503030', 'b2b@samsung.uz',  'South Korea',  'Tashkent', 'Mirobod district, Shevchenko 29'),
    ('LG Distributors Uz',       '+998712021515', 'sales@lg.uz',     'South Korea',  'Tashkent', 'Yashnobod district, Tarakkiyot 14'),
    ('Artel JSC',                '+998712007777', 'orders@artel.uz', 'Uzbekistan',   'Tashkent', 'Sergeli district, Yangi Sergeli 78'),
    ('Beko Trading LLC',         '+998711507722', 'info@beko.uz',    'Turkey',       'Tashkent', 'Yunusobod district, Amir Temur 124'),
    ('Bosch Home Tashkent',      '+998711405060', 'b2b@bosch.uz',    'Germany',      'Tashkent', 'Mirzo Ulugbek district, Buyuk Ipak Yoli 41'),
    ('Haier Asia Distribution',  '+998712201212', 'sales@haier.uz',  'China',        'Tashkent', 'Chilonzor district, Bunyodkor 33')
ON CONFLICT (company_name) DO NOTHING;


-- ============================================================
-- warehouses: 6 storage locations across Tashkent and regions
-- ============================================================
INSERT INTO warehouses (name, address, city, capacity_m3) VALUES
    ('Tashkent Central Warehouse',    'Yashnobod district, Korasuv 1',       'Tashkent',  5000.00),
    ('Yunusobod Storage Hub',         'Yunusobod district, Niyozbek yoli 7', 'Tashkent',  3500.00),
    ('Sergeli Logistics Center',      'Sergeli district, Yangi Sergeli 12',  'Tashkent',  4200.00),
    ('Chilonzor Branch Warehouse',    'Chilonzor district, Bunyodkor 88',    'Tashkent',  2800.00),
    ('Samarkand Distribution Point',  'Samarkand, Registan 5',               'Samarkand', 3000.00),
    ('Fergana Regional Warehouse',    'Fergana, Mustaqillik 22',             'Fergana',   2500.00)
ON CONFLICT (name) DO NOTHING;


-- ============================================================
-- customers: 8 customers
-- email and address are optional in the schema but I provide them
-- here to make the test data more realistic.
-- registered_at uses DEFAULT NOW() (not specified in INSERT).
-- ============================================================
INSERT INTO customers (first_name, last_name, phone, email, address) VALUES
    ('Jasur',   'Toshmatov', '+998901234567', 'jasur.t@mail.uz',   'Tashkent, Yunusobod, Niyozbek 14, apt. 22'),
    ('Nilufar', 'Yusupova',  '+998712345678', 'nilufar.y@mail.uz', 'Tashkent, Mirobod, Shevchenko 8, apt. 5'),
    ('Bobur',   'Karimov',   '+998931112233', 'bobur.k@mail.uz',   'Tashkent, Chilonzor, Bunyodkor 45, apt. 102'),
    ('Dilnoza', 'Rahimova',  '+998901239999', 'dilnoza.r@mail.uz', 'Tashkent, Sergeli, Yangi Sergeli 19, apt. 11'),
    ('Otabek',  'Sobirov',   '+998971230000', 'otabek.s@mail.uz',  'Samarkand, Registan 12, apt. 3'),
    ('Madina',  'Saidova',   '+998935551122', 'madina.s@mail.uz',  'Tashkent, Yashnobod, Korasuv 6, apt. 18'),
    ('Kamol',   'Tursunov',  '+998997773344', 'kamol.t@mail.uz',   'Fergana, Mustaqillik 8, apt. 9'),
    ('Sevara',  'Ergasheva', '+998951115566', 'sevara.e@mail.uz',  'Tashkent, Mirzo Ulugbek, Buyuk Ipak 14, apt. 7')
ON CONFLICT (phone) DO NOTHING;


-- ============================================================
-- employees: 6 employees with different roles
-- All hired in 2026, after the chk_employees_hired_after_2026 limit.
-- ============================================================
INSERT INTO employees (first_name, last_name, role, phone, hired_at) VALUES
    ('Mansur',   'Holiqov',   'sales',     '+998901114455', '2026-01-15 09:00:00+05'),
    ('Zulfiya',  'Nazarova',  'manager',   '+998935550011', '2026-01-20 09:00:00+05'),
    ('Sherzod',  'Ergashev',  'sales',     '+998971234455', '2026-02-01 09:00:00+05'),
    ('Aziza',    'Yusupova',  'logistics', '+998975551122', '2026-02-10 09:00:00+05'),
    ('Aziz',     'Saidov',    'sales',     '+998901567788', '2026-02-15 09:00:00+05'),
    ('Mavluda',  'Rasulova',  'cashier',   '+998937776655', '2026-03-01 09:00:00+05')
ON CONFLICT (phone) DO NOTHING;


-- ============================================================
-- products: 10 products across all 6 categories
-- I look up category_id by category name so no IDs are hardcoded.
-- prices are in UZS (Uzbek soum), realistic for the Tashkent market.
-- ============================================================
INSERT INTO products (category_id, brand, model, price, warranty_months, color)
SELECT c.category_id, p.brand, p.model, p.price::NUMERIC, p.warranty::SMALLINT, p.color
FROM (VALUES
    ('Refrigerators',     'Samsung', 'RB37K5440SS',     12500000.00, 24, 'Silver'),
    ('Refrigerators',     'LG',      'GR-B459SLCL',     11800000.00, 24, 'Black'),
    ('Washing Machines',  'Samsung', 'WW80T4040EE',      6500000.00, 24, 'White'),
    ('Washing Machines',  'Artel',   'TF-50WM',          3200000.00, 12, 'White'),
    ('Televisions',       'Samsung', 'UE55AU7100UXCE',   8900000.00, 12, 'Black'),
    ('Televisions',       'LG',      '50UQ7500PSF',      7400000.00, 12, 'Black'),
    ('Air Conditioners',  'Haier',   'HSU-12HEK03',      4800000.00, 36, 'White'),
    ('Microwaves',        'Beko',    'MCF25210X',        1250000.00, 24, 'Steel'),
    ('Vacuum Cleaners',   'Bosch',   'BGS05A220',        2100000.00, 24, 'Red'),
    ('Vacuum Cleaners',   'Artel',   'VC-1800',           980000.00, 12, 'Blue')
) AS p(category_name, brand, model, price, warranty, color)
JOIN categories c ON c.name = p.category_name
WHERE NOT EXISTS (
    SELECT 1 FROM products pr WHERE pr.brand = p.brand AND pr.model = p.model
);


-- ============================================================
-- product_suppliers: 10 supply relationships (M:N)
-- supply_price is the cost we pay; retail price is on products.
-- ============================================================
INSERT INTO product_suppliers (product_id, supplier_id, supply_price)
SELECT p.product_id, s.supplier_id, ps.supply_price::NUMERIC
FROM (VALUES
    ('Samsung', 'RB37K5440SS',    'Samsung Electronics Uz',   10500000.00),
    ('LG',      'GR-B459SLCL',    'LG Distributors Uz',        9800000.00),
    ('Samsung', 'WW80T4040EE',    'Samsung Electronics Uz',    5200000.00),
    ('Artel',   'TF-50WM',        'Artel JSC',                 2400000.00),
    ('Samsung', 'UE55AU7100UXCE', 'Samsung Electronics Uz',    7100000.00),
    ('LG',      '50UQ7500PSF',    'LG Distributors Uz',        5800000.00),
    ('Haier',   'HSU-12HEK03',    'Haier Asia Distribution',   3800000.00),
    ('Beko',    'MCF25210X',      'Beko Trading LLC',           980000.00),
    ('Bosch',   'BGS05A220',      'Bosch Home Tashkent',       1650000.00),
    ('Artel',   'VC-1800',        'Artel JSC',                  720000.00)
) AS ps(brand, model, supplier_name, supply_price)
JOIN products p   ON p.brand = ps.brand AND p.model = ps.model
JOIN suppliers s  ON s.company_name = ps.supplier_name
WHERE NOT EXISTS (
    SELECT 1 FROM product_suppliers pps
    WHERE pps.product_id = p.product_id AND pps.supplier_id = s.supplier_id
);


-- ============================================================
-- inventory: 12 stock rows across products and warehouses
-- Some products are stocked in 2 warehouses (a true M:N case).
-- ============================================================
INSERT INTO inventory (product_id, warehouse_id, stock_quantity, last_restocked_at)
SELECT p.product_id, w.warehouse_id, inv.qty::INTEGER, inv.last_restock::TIMESTAMPTZ
FROM (VALUES
    ('Samsung', 'RB37K5440SS',    'Tashkent Central Warehouse',    25, '2026-02-05 10:00:00+05'),
    ('Samsung', 'RB37K5440SS',    'Yunusobod Storage Hub',         12, '2026-02-10 10:00:00+05'),
    ('LG',      'GR-B459SLCL',    'Tashkent Central Warehouse',    18, '2026-02-08 10:00:00+05'),
    ('Samsung', 'WW80T4040EE',    'Sergeli Logistics Center',      30, '2026-02-12 10:00:00+05'),
    ('Artel',   'TF-50WM',        'Tashkent Central Warehouse',    50, '2026-02-15 10:00:00+05'),
    ('Artel',   'TF-50WM',        'Samarkand Distribution Point',  20, '2026-02-15 10:00:00+05'),
    ('Samsung', 'UE55AU7100UXCE', 'Yunusobod Storage Hub',         15, '2026-03-01 10:00:00+05'),
    ('LG',      '50UQ7500PSF',    'Chilonzor Branch Warehouse',    22, '2026-03-05 10:00:00+05'),
    ('Haier',   'HSU-12HEK03',    'Tashkent Central Warehouse',    40, '2026-03-10 10:00:00+05'),
    ('Beko',    'MCF25210X',      'Yunusobod Storage Hub',         60, '2026-03-15 10:00:00+05'),
    ('Bosch',   'BGS05A220',      'Sergeli Logistics Center',      35, '2026-03-20 10:00:00+05'),
    ('Artel',   'VC-1800',        'Fergana Regional Warehouse',    45, '2026-03-25 10:00:00+05')
) AS inv(brand, model, warehouse_name, qty, last_restock)
JOIN products p   ON p.brand = inv.brand AND p.model = inv.model
JOIN warehouses w ON w.name = inv.warehouse_name
WHERE NOT EXISTS (
    SELECT 1 FROM inventory ii
    WHERE ii.product_id = p.product_id AND ii.warehouse_id = w.warehouse_id
);


-- ============================================================
-- orders + order_items
-- I use a CTE with RETURNING here so I don't have to look up
-- the order_id by joining on customer + order_date later. The
-- RETURNING gives me exactly the IDs I just inserted, which is
-- safer than guessing them by timestamp.
--
-- Note: order_items.line_total is GENERATED ALWAYS AS, so I
-- don't include it in the INSERT. Postgres calculates it
-- automatically from quantity * unit_price.
--
-- All order dates fall in Feb–Apr 2026 (last 3 months as of
-- today, 2026-04-26).
-- ============================================================

WITH inserted_orders AS (
    INSERT INTO orders (customer_id, employee_id, warehouse_id, order_date, status, total_amount)
    SELECT c.customer_id, e.employee_id, w.warehouse_id,
           o.order_date::TIMESTAMPTZ, o.status, 0  -- total filled in below
    FROM (VALUES
        ('+998901234567', '+998901114455', 'Tashkent Central Warehouse', '2026-02-05 11:00:00+05', 'delivered'),
        ('+998712345678', '+998971234455', 'Yunusobod Storage Hub',      '2026-02-12 14:30:00+05', 'delivered'),
        ('+998931112233', '+998901567788', 'Sergeli Logistics Center',   '2026-02-20 10:15:00+05', 'delivered'),
        ('+998901239999', '+998901114455', 'Tashkent Central Warehouse', '2026-03-03 16:45:00+05', 'delivered'),
        ('+998971230000', '+998971234455', 'Chilonzor Branch Warehouse', '2026-03-15 12:00:00+05', 'shipped'),
        ('+998935551122', '+998901114455', 'Yunusobod Storage Hub',      '2026-03-25 09:30:00+05', 'delivered'),
        ('+998997773344', '+998901567788', 'Tashkent Central Warehouse', '2026-04-05 15:20:00+05', 'shipped'),
        ('+998951115566', '+998971234455', 'Sergeli Logistics Center',   '2026-04-15 11:50:00+05', 'pending')
    ) AS o(customer_phone, employee_phone, warehouse_name, order_date, status)
    JOIN customers c  ON c.phone = o.customer_phone
    JOIN employees e  ON e.phone = o.employee_phone
    JOIN warehouses w ON w.name  = o.warehouse_name
    WHERE NOT EXISTS (
        SELECT 1 FROM orders ord
        WHERE ord.customer_id = c.customer_id
          AND ord.order_date  = o.order_date::TIMESTAMPTZ
    )
    RETURNING order_id, customer_id, order_date
),
inserted_items AS (
    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    SELECT io.order_id, p.product_id, oi.qty::INTEGER, p.price
    FROM (VALUES
        -- order 1 (Jasur, 2026-02-05): 1 Samsung fridge + 1 Beko microwave
        ('+998901234567', '2026-02-05 11:00:00+05', 'Samsung', 'RB37K5440SS',    1),
        ('+998901234567', '2026-02-05 11:00:00+05', 'Beko',    'MCF25210X',      1),
        -- order 2 (Nilufar, 2026-02-12): 1 LG fridge + 1 Samsung washing machine
        ('+998712345678', '2026-02-12 14:30:00+05', 'LG',      'GR-B459SLCL',    1),
        ('+998712345678', '2026-02-12 14:30:00+05', 'Samsung', 'WW80T4040EE',    1),
        -- order 3 (Bobur, 2026-02-20): 2 Artel washers
        ('+998931112233', '2026-02-20 10:15:00+05', 'Artel',   'TF-50WM',        2),
        -- order 4 (Dilnoza, 2026-03-03): 1 Samsung TV + 1 Bosch vacuum
        ('+998901239999', '2026-03-03 16:45:00+05', 'Samsung', 'UE55AU7100UXCE', 1),
        ('+998901239999', '2026-03-03 16:45:00+05', 'Bosch',   'BGS05A220',      1),
        -- order 5 (Otabek, 2026-03-15): 1 LG TV
        ('+998971230000', '2026-03-15 12:00:00+05', 'LG',      '50UQ7500PSF',    1),
        -- order 6 (Madina, 2026-03-25): 2 Haier ACs + 1 Beko microwave
        ('+998935551122', '2026-03-25 09:30:00+05', 'Haier',   'HSU-12HEK03',    2),
        ('+998935551122', '2026-03-25 09:30:00+05', 'Beko',    'MCF25210X',      1),
        -- order 7 (Kamol, 2026-04-05): 3 Artel vacuums
        ('+998997773344', '2026-04-05 15:20:00+05', 'Artel',   'VC-1800',        3),
        -- order 8 (Sevara, 2026-04-15): 1 Samsung washing machine + 1 Artel vacuum
        ('+998951115566', '2026-04-15 11:50:00+05', 'Samsung', 'WW80T4040EE',    1),
        ('+998951115566', '2026-04-15 11:50:00+05', 'Artel',   'VC-1800',        1)
    ) AS oi(customer_phone, order_date, brand, model, qty)
    JOIN customers c    ON c.phone = oi.customer_phone
    JOIN inserted_orders io
                        ON io.customer_id = c.customer_id
                       AND io.order_date  = oi.order_date::TIMESTAMPTZ
    JOIN products p     ON p.brand = oi.brand AND p.model = oi.model
    RETURNING order_id, line_total
)
-- update each order's total_amount with the sum of its lines
UPDATE orders o
SET total_amount = sub.total
FROM (
    SELECT order_id, SUM(line_total) AS total
    FROM inserted_items
    GROUP BY order_id
) sub
WHERE o.order_id = sub.order_id;


-- quick sanity check: every table should have 6+ rows
SELECT 'categories'         AS tbl, COUNT(*) AS rows FROM categories
UNION ALL SELECT 'suppliers',          COUNT(*) FROM suppliers
UNION ALL SELECT 'warehouses',         COUNT(*) FROM warehouses
UNION ALL SELECT 'customers',          COUNT(*) FROM customers
UNION ALL SELECT 'employees',          COUNT(*) FROM employees
UNION ALL SELECT 'products',           COUNT(*) FROM products
UNION ALL SELECT 'product_suppliers',  COUNT(*) FROM product_suppliers
UNION ALL SELECT 'inventory',          COUNT(*) FROM inventory
UNION ALL SELECT 'orders',             COUNT(*) FROM orders
UNION ALL SELECT 'order_items',        COUNT(*) FROM order_items;


-- ============================================================
-- FUNCTION 5.1: update_product_value
--
-- The task asks for a function that takes:
--   - the primary key value of the row to update
--   - the name of the column to update
--   - the new value for that column
-- and updates the specified column on that row.
--
-- I built this for the products table since price changes,
-- color updates, and warranty edits are common operations.
--
-- Why I use format() with %I and %L:
--   - %I quotes the column name as an identifier (safe against
--     names with spaces or reserved words).
--   - %L quotes the value as a literal (safe against SQL injection
--     in the value text).
-- Why I added a whitelist of allowed columns:
--   - even with %I, dynamic column names should be validated
--     so the function can't be misused to modify primary keys
--     or audit columns like record_ts.
-- ============================================================
CREATE OR REPLACE FUNCTION update_product_value(
    p_product_id   INTEGER,
    p_column_name  TEXT,
    p_new_value    TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_query        TEXT;
    v_row_count    INTEGER;
BEGIN
    -- whitelist of columns I'm willing to update through this function.
    -- record_ts and product_id are intentionally excluded.
    IF p_column_name NOT IN ('brand', 'model', 'price', 'warranty_months', 'color', 'category_id') THEN
        RAISE EXCEPTION 'Column "%" is not allowed to be updated by this function', p_column_name;
    END IF;

    -- check the row actually exists before trying to update
    IF NOT EXISTS (SELECT 1 FROM appliance_store.products WHERE product_id = p_product_id) THEN
        RAISE EXCEPTION 'Product with product_id = % does not exist', p_product_id;
    END IF;

    -- build and run the dynamic UPDATE
    v_query := format(
        'UPDATE appliance_store.products SET %I = %L WHERE product_id = %L',
        p_column_name, p_new_value, p_product_id
    );
    EXECUTE v_query;

    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    RAISE NOTICE 'Updated % row(s): products.% = % for product_id = %',
                 v_row_count, p_column_name, p_new_value, p_product_id;
END;
$$;

-- example calls (commented out so the script runs cleanly):
-- SELECT update_product_value(1, 'price', '13000000');
-- SELECT update_product_value(2, 'color', 'Graphite');


-- ============================================================
-- FUNCTION 5.2: add_order
--
-- Adds a new order plus its line items in one call. All inputs
-- are natural keys (phone numbers, names, brand+model) so the
-- caller never has to know the surrogate IDs.
--
-- Input arguments:
--   p_customer_phone   - customer's phone number
--   p_employee_phone   - phone of the salesperson
--   p_warehouse_name   - which warehouse the order ships from
--   p_items            - JSONB array of {brand, model, quantity}
--   p_status           - optional, defaults to 'pending'
--
-- Returns the new order_id so the caller can confirm/look it up.
-- Uses RAISE NOTICE for the success message as the task asks.
--
-- I chose JSONB for the items array because it lets the caller
-- pass any number of products in one call without me having to
-- define a fixed-size argument list.
-- ============================================================
CREATE OR REPLACE FUNCTION add_order(
    p_customer_phone  TEXT,
    p_employee_phone  TEXT,
    p_warehouse_name  TEXT,
    p_items           JSONB,
    p_status          TEXT DEFAULT 'pending'
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id   INTEGER;
    v_employee_id   INTEGER;
    v_warehouse_id  INTEGER;
    v_order_id      INTEGER;
    v_item          JSONB;
    v_product_id    INTEGER;
    v_unit_price    NUMERIC(14,2);
    v_quantity      INTEGER;
    v_total         NUMERIC(14,2) := 0;
BEGIN
    -- step 1: resolve natural keys
    SELECT customer_id INTO v_customer_id
    FROM appliance_store.customers
    WHERE phone = p_customer_phone;
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'Customer with phone % not found', p_customer_phone;
    END IF;

    SELECT employee_id INTO v_employee_id
    FROM appliance_store.employees
    WHERE phone = p_employee_phone;
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Employee with phone % not found', p_employee_phone;
    END IF;

    SELECT warehouse_id INTO v_warehouse_id
    FROM appliance_store.warehouses
    WHERE name = p_warehouse_name;
    IF v_warehouse_id IS NULL THEN
        RAISE EXCEPTION 'Warehouse "%" not found', p_warehouse_name;
    END IF;

    -- step 2: insert the order header (total_amount filled in at the end)
    INSERT INTO appliance_store.orders (
        customer_id, employee_id, warehouse_id, status, total_amount
    )
    VALUES (
        v_customer_id, v_employee_id, v_warehouse_id, p_status, 0
    )
    RETURNING order_id INTO v_order_id;

    -- step 3: loop over the items array, insert each line, build up total
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        SELECT product_id, price INTO v_product_id, v_unit_price
        FROM appliance_store.products
        WHERE brand = v_item->>'brand' AND model = v_item->>'model';

        IF v_product_id IS NULL THEN
            RAISE EXCEPTION 'Product %/% not found',
                v_item->>'brand', v_item->>'model';
        END IF;

        v_quantity := (v_item->>'quantity')::INTEGER;

        INSERT INTO appliance_store.order_items (
            order_id, product_id, quantity, unit_price
        )
        VALUES (
            v_order_id, v_product_id, v_quantity, v_unit_price
        );

        v_total := v_total + v_unit_price * v_quantity;
    END LOOP;

    -- step 4: write the final total back to the order header
    UPDATE appliance_store.orders
    SET total_amount = v_total
    WHERE order_id = v_order_id;

    -- success confirmation
    RAISE NOTICE 'Order #% created for customer % | items: % | total: % UZS',
                 v_order_id, p_customer_phone, jsonb_array_length(p_items), v_total;

    RETURN v_order_id;
END;
$$;

-- example call (commented out):
-- SELECT add_order(
--     '+998901234567',
--     '+998901114455',
--     'Tashkent Central Warehouse',
--     '[{"brand":"LG","model":"GR-B459SLCL","quantity":1},
--       {"brand":"Beko","model":"MCF25210X","quantity":2}]'::JSONB,
--     'pending'
-- );


-- ============================================================
-- VIEW: v_recent_quarter_analytics
--
-- Shows analytics for the most recently active quarter in the
-- orders table. I pick the quarter dynamically from MAX(order_date)
-- so the view stays correct as new orders come in — I don't want
-- to hardcode 'Q2 2026'.
--
-- The view aggregates by category and brand and shows:
--   - number of orders
--   - units sold
--   - total revenue
--   - average unit price
--
-- Surrogate keys (category_id, product_id, etc.) are excluded, and
-- the GROUP BY guarantees no duplicate rows.
-- Cancelled orders are excluded since they aren't real revenue.
-- ============================================================
CREATE OR REPLACE VIEW v_recent_quarter_analytics AS
WITH recent_quarter AS (
    -- find the start and end of the most recent quarter that has data
    SELECT
        DATE_TRUNC('quarter', MAX(order_date))                       AS q_start,
        DATE_TRUNC('quarter', MAX(order_date)) + INTERVAL '3 months' AS q_end
    FROM appliance_store.orders
    WHERE status <> 'cancelled'
)
SELECT
    c.name                                AS category_name,
    p.brand                               AS brand,
    COUNT(DISTINCT o.order_id)            AS orders_count,
    SUM(oi.quantity)                      AS units_sold,
    SUM(oi.line_total)                    AS total_revenue_uzs,
    ROUND(AVG(oi.unit_price), 2)          AS avg_unit_price_uzs
FROM appliance_store.orders o
JOIN appliance_store.order_items oi  ON oi.order_id = o.order_id
JOIN appliance_store.products p      ON p.product_id = oi.product_id
JOIN appliance_store.categories c    ON c.category_id = p.category_id
JOIN recent_quarter rq
     ON o.order_date >= rq.q_start
    AND o.order_date <  rq.q_end
WHERE o.status <> 'cancelled'
GROUP BY c.name, p.brand;
-- I deliberately don't include ORDER BY in the view definition —
-- consumers can sort however they need. Adding ORDER BY inside a
-- view definition can also be ignored by the planner anyway.


-- ============================================================
-- READ-ONLY ROLE: appliance_manager
--
-- The manager needs SELECT access only — no INSERT, UPDATE, or
-- DELETE. They should also be able to log in.
--
-- Security best practices I applied:
--   - NOSUPERUSER: cannot bypass any checks
--   - NOCREATEDB / NOCREATEROLE: cannot create new databases or roles
--   - NOINHERIT: doesn't automatically inherit privileges from any
--     future parent role
--   - CONNECTION LIMIT 5: caps simultaneous logins
--   - explicit GRANT for SELECT only
--   - ALTER DEFAULT PRIVILEGES so future tables get SELECT too,
--     without me having to remember to grant access manually
--
-- I drop the role first so the script stays rerunnable.
-- The DO block handles "role does not exist yet" cleanly on the
-- first run.
-- ============================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'appliance_manager') THEN
        -- revoke privileges first so DROP ROLE doesn't fail with
        -- "role cannot be dropped because some objects depend on it"
        EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA appliance_store FROM appliance_manager';
        EXECUTE 'REVOKE ALL ON SCHEMA appliance_store FROM appliance_manager';
        EXECUTE 'REVOKE ALL ON DATABASE appliance_store FROM appliance_manager';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA appliance_store REVOKE SELECT ON TABLES FROM appliance_manager';
        DROP ROLE appliance_manager;
    END IF;
END $$;

CREATE ROLE appliance_manager LOGIN PASSWORD 'ManagerPass2026!'
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
    CONNECTION LIMIT 5;

-- connect privilege: needed to log into the database at all
GRANT CONNECT ON DATABASE appliance_store TO appliance_manager;

-- usage on schema: needed to "see" tables exist
GRANT USAGE ON SCHEMA appliance_store TO appliance_manager;

-- read access on all current tables and the analytics view
GRANT SELECT ON ALL TABLES IN SCHEMA appliance_store TO appliance_manager;

-- read access on tables created in the future (so I don't have
-- to remember to re-grant every time a new table is added)
ALTER DEFAULT PRIVILEGES IN SCHEMA appliance_store
    GRANT SELECT ON TABLES TO appliance_manager;

-- I deliberately did NOT grant EXECUTE on functions: the manager
-- shouldn't be able to call add_order() or update_product_value().
-- They are a read-only role.