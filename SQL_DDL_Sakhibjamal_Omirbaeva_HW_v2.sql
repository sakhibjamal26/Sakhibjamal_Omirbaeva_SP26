-- ============================================================
-- SQL DDL Homework
-- Physical Database: Car Sharing Service
-- Schema: car_sharing
-- Author: Sakhibjamal Omirbaeva
-- Standard: 3NF
-- ============================================================

-- I need to drop and recreate the schema every time I run this
-- so the script doesn't break on reruns. CASCADE drops everything
-- inside it automatically, so I don't have to drop tables one by one.
-- This way I can run the whole file multiple times without errors.
DROP SCHEMA IF EXISTS car_sharing CASCADE;
CREATE SCHEMA car_sharing;
SET search_path TO car_sharing;

-- A note on why the order of CREATE TABLE statements matters:
-- PostgreSQL checks foreign key references at the moment you create the table.
-- So if I try to create vehicles before vehicle_types exists, I'll get an error
-- like: "relation vehicle_types does not exist".
-- That's why I always create parent tables first, then child tables after.
-- If I get the order wrong, I have to drop everything and start over —
-- which is exactly why I put the DROP SCHEMA at the top.

-- ============================================================
-- TABLE: vehicle_types
-- I'm creating this one first because vehicles and pricing_history
-- both reference it, so it has to exist before those tables.
--
-- I decided to keep vehicle types separate from the vehicles table
-- because many cars share the same type. If I put price_per_minute
-- directly on each vehicle row, then every time the Economy rate
-- changes I'd have to update every single Economy car — that's an
-- update anomaly and exactly what 3NF is supposed to prevent.
-- With this table I just update one row and all Economy cars
-- automatically get the new price.
--
-- For prices I used NUMERIC(8,2) instead of FLOAT because FLOAT
-- can cause tiny rounding errors like storing 500.00 as 499.999999.
-- That kind of thing would cause billing bugs that are really hard
-- to debug, so exact decimal type is safer here.
-- ============================================================

CREATE TABLE vehicle_types (
    type_id          SERIAL          PRIMARY KEY,
    name             VARCHAR(100)    NOT NULL UNIQUE,
        -- UNIQUE on name: I don't want two rows both called "Economy"
        -- because then when I look up pricing by type name I'd get
        -- duplicate results and the billing would be wrong.
        -- Without this constraint that could silently happen.
    price_per_minute NUMERIC(8,2)    NOT NULL CHECK (price_per_minute > 0),
        -- CHECK > 0: a price of zero would mean the ride is free,
        -- and a negative price makes no sense at all.
        -- Without this check, someone could accidentally insert 0
        -- or even a negative number and it would just go through.
    price_per_km     NUMERIC(8,2)    NOT NULL CHECK (price_per_km > 0)
        -- same reasoning as price_per_minute above
);

-- ============================================================
-- TABLE: locations
-- This one is also a parent table — trips references it twice
-- (for start and end location), so it needs to come before trips.
--
-- I separated locations from trips because the same zone gets
-- used over and over across thousands of trips. If I stored the
-- address and coordinates in every trip row, that's a lot of
-- repeated data, and if a zone's address changes I'd have to
-- update hundreds of rows. One table, one update.
--
-- I used DECIMAL(9,6) for coordinates because GPS needs about
-- 6 decimal places to be accurate to ~10cm. FLOAT could work too
-- but it has rounding issues, and a small GPS error could place
-- a car in the wrong zone on the map. DECIMAL is just cleaner here.
-- ============================================================

CREATE TABLE locations (
    location_id SERIAL          PRIMARY KEY,
    name        VARCHAR(200)    NOT NULL,
    latitude    DECIMAL(9,6)    NOT NULL,
    longitude   DECIMAL(9,6)    NOT NULL,
    address     VARCHAR(300)    NOT NULL
);

-- ============================================================
-- TABLE: employees
-- Parent table for vehicle_status_log and maintenance_records.
-- I kept employees completely separate from users because they're
-- just different things — employees have a role and a hire date,
-- users have a driver's license and booking history. If I merged
-- them into one table I'd have a lot of NULLs and weird
-- conditional logic everywhere, which breaks 3NF.
--
-- I used VARCHAR(100) for role instead of an ENUM type because
-- if the business adds a new role later I can just insert a new
-- value without changing the schema. ENUM would require ALTER TYPE.
-- ============================================================

CREATE TABLE employees (
    employee_id SERIAL          PRIMARY KEY,
    first_name  VARCHAR(100)    NOT NULL,
    last_name   VARCHAR(100)    NOT NULL,
    role        VARCHAR(100)    NOT NULL
                    CHECK (role IN ('mechanic', 'inspector', 'dispatcher')),
        -- CHECK on role: only valid role names can be inserted.
        -- Without it, someone could type "Mechanic" with a capital
        -- letter or "tech" and it would go through — then role-based
        -- filtering would silently miss those rows.
    hired_at    TIMESTAMP       NOT NULL
                    CHECK (hired_at > '2000-01-01')
        -- The business didn't exist before 2000, so any hire date
        -- before that is clearly a mistake. This prevents things like
        -- '1970-01-01' (Unix epoch default) from sneaking in.
);

-- ============================================================
-- TABLE: users
-- Parent table — trips and payments both reference it.
-- I kept users separate from trips because a user exists on their
-- own — they can register and never take a single trip. If I merged
-- users into trips I'd have NULL-heavy rows for never-booked users
-- and I'd repeat the same name and email on every trip they take.
--
-- VARCHAR(255) for email: that's the standard max length.
-- VARCHAR(20) for phone: numbers include + and spaces like
-- "+998 90 123 45 67", so INTEGER wouldn't work — it would lose
-- the + sign and leading zeros.
-- BOOLEAN for is_active: just true or false. SMALLINT (0/1)
-- technically works but allows values like 2 or -1 which don't
-- mean anything, so BOOLEAN is cleaner.
-- ============================================================

CREATE TABLE users (
    user_id           SERIAL          PRIMARY KEY,
    first_name        VARCHAR(100)    NOT NULL,
    last_name         VARCHAR(100)    NOT NULL,
    email             VARCHAR(255)    NOT NULL UNIQUE,
        -- UNIQUE on email: two users can't share an email because
        -- it's used for login and notifications. Without this,
        -- one user could get another person's booking emails —
        -- that's both annoying and a privacy problem.
    phone             VARCHAR(20)     NOT NULL,
    driver_license_no VARCHAR(50)     NOT NULL UNIQUE,
        -- UNIQUE on license: each driver's license belongs to
        -- one person in real life, so it should be unique here too.
        -- Without this UNIQUE, one person could create multiple
        -- accounts with the same license, bypassing identity
        -- verification and potentially accumulating debt across
        -- fake accounts.
    registered_at     TIMESTAMP       NOT NULL DEFAULT NOW(),
        -- DEFAULT NOW() means I don't have to pass this value
        -- from the app — the database fills it in automatically.
    is_active         BOOLEAN         NOT NULL DEFAULT TRUE
        -- new accounts start as active by default.
        -- NOT NULL is important here — if this were nullable,
        -- a query like WHERE is_active = TRUE would miss NULL rows
        -- and those accounts would be invisible.
);

-- ============================================================
-- TABLE: vehicles
-- Child of vehicle_types, parent of trips / vehicle_status_log
-- / maintenance_records. Has to come after vehicle_types.
--
-- I decided not to put a status column directly on this table.
-- My first idea was to add a status column here and update it
-- every time the car's state changes. But then you lose all
-- history — you can't answer "what was this car's status last
-- Tuesday?". So status lives in vehicle_status_log instead,
-- and the current status is just the row where valid_to IS NULL.
--
-- SMALLINT for year: fits the range and is smaller than INTEGER.
-- If I used TEXT, someone could type '202O' (letter O) and it
-- would pass — SMALLINT prevents that.
-- ============================================================

CREATE TABLE vehicles (
    vehicle_id    SERIAL          PRIMARY KEY,
    type_id       INTEGER         NOT NULL
                      REFERENCES vehicle_types(type_id),
        -- FK to vehicle_types: without this I could insert a vehicle
        -- with a type_id that points to nothing. Then when I try to
        -- look up the price for a trip, the JOIN returns NULL and
        -- billing breaks silently.
    make          VARCHAR(100)    NOT NULL,
    model         VARCHAR(100)    NOT NULL,
    year          SMALLINT        NOT NULL
                      CHECK (year >= 2000),
        -- we only use cars from 2000 onwards, so anything earlier
        -- is a data entry mistake.
    license_plate VARCHAR(20)     NOT NULL UNIQUE,
        -- UNIQUE: each car has exactly one plate in real life.
        -- Without this UNIQUE, two vehicles could share the same
        -- plate. When a user reports damage or a traffic violation,
        -- we wouldn't know which physical car to assign it to.
    color         VARCHAR(50)     NOT NULL
);

-- ============================================================
-- TABLE: pricing_history
-- Child of vehicle_types. I created this as a separate table
-- to keep historical pricing intact. If I just updated
-- price_per_minute on vehicle_types directly, old trips would
-- retroactively show the new price — a trip from 2023 should
-- always show the 2023 price.
-- valid_to = NULL means this is the price currently in effect.
--
-- My mentor asked why I didn't just use a trigger on vehicle_types
-- to archive old prices. My answer: an explicit table makes the
-- temporal pattern queryable and visible — you can SELECT * FROM
-- pricing_history and immediately see the full history.
-- A trigger hides the archiving logic inside the database engine,
-- making it invisible to anyone reading the schema, harder to
-- debug, and impossible to query directly.
-- ============================================================

CREATE TABLE pricing_history (
    price_id         SERIAL          PRIMARY KEY,
    type_id          INTEGER         NOT NULL
                         REFERENCES vehicle_types(type_id),
        -- FK: without this, a pricing row could reference a vehicle
        -- type that was deleted. Historical price lookups for billing
        -- would return nothing.
    price_per_minute NUMERIC(8,2)    NOT NULL CHECK (price_per_minute > 0),
    price_per_km     NUMERIC(8,2)    NOT NULL CHECK (price_per_km > 0),
    valid_from       TIMESTAMP       NOT NULL
                         CHECK (valid_from > '2000-01-01'),
    valid_to         TIMESTAMP       NULL,
        -- NULL means this price is still active.
        CONSTRAINT chk_pricing_period CHECK (valid_to IS NULL OR valid_to > valid_from)
        -- My mentor pointed out I was missing this check.
        -- Without it, a pricing period could end before it starts.
        -- Temporal queries like "what was the price on date X" would
        -- return wrong or overlapping results and billing would break.
);

-- ============================================================
-- TABLE: vehicle_status_log
-- Child of vehicles and employees.
-- Every status change is a new row — I never overwrite old ones.
-- Current status = the row where valid_to IS NULL.
--
-- employee_id is nullable because not every status change is
-- triggered by an employee — the system sets status to 'in_use'
-- automatically when a user starts a trip. Only maintenance-related
-- changes have an employee attached.
-- ============================================================

CREATE TABLE vehicle_status_log (
    log_id      SERIAL          PRIMARY KEY,
    vehicle_id  INTEGER         NOT NULL
                    REFERENCES vehicles(vehicle_id),
        -- FK: without this I could have status log entries for
        -- vehicles that don't exist anymore. Availability queries
        -- would return orphaned rows with no matching vehicle.
    status      VARCHAR(20)     NOT NULL
                    CHECK (status IN ('available', 'reserved', 'in_use', 'maintenance')),
        -- CHECK: only these four statuses are valid in the business
        -- logic. Without it, someone could insert 'free' or 'broken'
        -- and availability filter queries would silently not work.
    valid_from  TIMESTAMP       NOT NULL
                    CHECK (valid_from > '2000-01-01'),
    valid_to    TIMESTAMP       NULL,
        -- NULL = this status is still active right now.
        CONSTRAINT chk_status_period CHECK (valid_to IS NULL OR valid_to > valid_from),
        -- My mentor pointed out I was missing this check too.
        -- Without it, a status period could go backwards in time,
        -- completely breaking availability queries that rely on
        -- valid_from/valid_to ranges.
    employee_id INTEGER         NULL
                    REFERENCES employees(employee_id)
        -- nullable: system events have no employee, maintenance does.
        -- Without the REFERENCES, employee_id = 999 could be inserted
        -- for someone who doesn't exist. Maintenance audit reports
        -- would have orphaned rows with no employee to trace back to.
);

-- ============================================================
-- TABLE: trips
-- Child of users, vehicles, and locations (twice).
-- This is the main table of the whole model.
--
-- end_location_id and ended_at are nullable because they're
-- unknown while the trip is still in progress.
--
-- The rating columns used to be a separate ratings table in my
-- original design. After reviewer feedback I merged them here
-- as nullable columns. Unrated trips just have NULL in those
-- three columns.
--
-- NUMERIC(10,2) for cost: trip costs in UZS can be large numbers
-- like 245000.00, so I needed more digits than vehicle_types prices.
-- FLOAT would cause rounding errors in billing, INTEGER would lose
-- the decimal part.
--
-- duration_min: originally I had this as a regular nullable column.
-- My mentor pointed out that storing it manually creates a risk of
-- inconsistency — someone could insert duration=999 while the actual
-- timestamps say 45 minutes. So I changed it to GENERATED ALWAYS AS,
-- which means PostgreSQL always computes it from ended_at - started_at
-- automatically. I can't insert a value into this column manually —
-- PostgreSQL will throw an error if I try. While the trip is still
-- in progress ended_at IS NULL, so duration_min will be NULL too,
-- which is the correct behaviour.
-- ============================================================

CREATE TABLE trips (
    trip_id           SERIAL          PRIMARY KEY,
    user_id           INTEGER         NOT NULL
                          REFERENCES users(user_id),
        -- FK: without this, a trip could belong to a user that no
        -- longer exists. User history and billing would have orphaned
        -- rows with no user to attach to.
    vehicle_id        INTEGER         NOT NULL
                          REFERENCES vehicles(vehicle_id),
        -- FK: without this, a trip could reference a vehicle removed
        -- from the fleet. Fleet utilization reports would silently
        -- miss those trips or throw errors.
    start_location_id INTEGER         NOT NULL
                          REFERENCES locations(location_id),
    end_location_id   INTEGER         NULL
                          REFERENCES locations(location_id),
        -- nullable: we don't know the end location until the trip
        -- is completed. Both location FKs prevent referencing a zone
        -- that doesn't exist in the locations table.
    started_at        TIMESTAMP       NOT NULL
                          CHECK (started_at > '2000-01-01'),
        -- trips before 2000 aren't possible — prevents epoch
        -- timestamps (1970-01-01) from sneaking in if something
        -- goes wrong in the app.
    ended_at          TIMESTAMP       NULL,
        -- NULL while the trip is still ongoing.
        CONSTRAINT chk_trip_times CHECK (ended_at IS NULL OR ended_at > started_at),
        -- My mentor asked me to add this. Without it, a "time-travel
        -- trip" could be inserted where ended_at is before started_at.
        -- duration_min would become negative, cost calculation would
        -- be wrong, and all duration-based reports would be meaningless.
    distance_km       NUMERIC(8,2)    NULL
                          CHECK (distance_km IS NULL OR distance_km >= 0),
        -- distance can't be negative — physically impossible.
        -- NULL until the trip ends. Without the check, a pipeline bug
        -- could insert -5.00 km and cost calculation would break.
    duration_min      NUMERIC(8,2)    GENERATED ALWAYS AS
                          (EXTRACT(EPOCH FROM (ended_at - started_at)) / 60) STORED,
        -- GENERATED ALWAYS AS: always derived from the timestamps,
        -- never stored manually. This prevents inconsistency between
        -- the stored duration and the actual timestamps.
        -- STORED means PostgreSQL computes it on write and saves it
        -- physically — queryable like a regular column.
        -- Important: this column must NOT appear in INSERT statements.
    cost              NUMERIC(10,2)   NULL
                          CHECK (cost IS NULL OR cost >= 0),
    rating_score      SMALLINT        NULL
                          CHECK (rating_score IS NULL OR rating_score BETWEEN 1 AND 5),
        -- 1 to 5 stars only. Without this, someone could submit 0 or
        -- 10 and average rating calculations would be completely off.
    rating_comment    TEXT            NULL,
    rated_at          TIMESTAMP       NULL
        -- all three rating columns are nullable — not every trip
        -- gets rated and that's normal.
);

-- ============================================================
-- TABLE: payments
-- Child of trips and users.
-- I kept payments separate from trips because a payment has its
-- own lifecycle — pending, failed, refunded — which doesn't map
-- cleanly onto trip status. Also handling refunds inside the trips
-- table would be messy.
--
-- I stored user_id here directly so I can query a user's payment
-- history without always joining through trips.
-- ============================================================

CREATE TABLE payments (
    payment_id SERIAL          PRIMARY KEY,
    trip_id    INTEGER         NOT NULL
                   REFERENCES trips(trip_id),
        -- FK: without this, a payment could reference a trip that
        -- doesn't exist. Financial reconciliation would find payment
        -- rows with nothing to match against.
    user_id    INTEGER         NOT NULL
                   REFERENCES users(user_id),
        -- FK: if user is deleted, we'd lose track of who made
        -- this payment.
    amount     NUMERIC(10,2)   NOT NULL
                   CHECK (amount >= 0),
        -- amount can be 0 (e.g. promo ride) but never negative.
        -- Without this, a refund bug could insert -127500.00 and
        -- mess up revenue totals completely.
    method     VARCHAR(50)     NOT NULL
                   CHECK (method IN ('card', 'mobile', 'cash')),
        -- only these three methods accepted. Without the check,
        -- anything could be inserted and payment reporting would
        -- group things incorrectly.
    status     VARCHAR(20)     NOT NULL
                   CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
        -- only valid states allowed. Without this, values like
        -- 'done' or 'ok' could enter the system and break filters.
    paid_at    TIMESTAMP       NULL
        -- NULL while the payment is pending or failed.
        -- Gets set when payment is confirmed as completed.
);

-- ============================================================
-- TABLE: maintenance_records
-- Child of vehicles and employees. Created last because it
-- depends on both. Every service event is a new row so I have
-- full history. next_due_at lets me schedule future maintenance.
-- ============================================================

CREATE TABLE maintenance_records (
    record_id    SERIAL          PRIMARY KEY,
    vehicle_id   INTEGER         NOT NULL
                     REFERENCES vehicles(vehicle_id),
        -- FK: without this, service records could exist for vehicles
        -- no longer in the fleet — orphaned rows in maintenance history.
    employee_id  INTEGER         NOT NULL
                     REFERENCES employees(employee_id),
        -- FK: if an employee is removed, I'd lose track of who
        -- performed the service — important for accountability.
    type         VARCHAR(100)    NOT NULL,
    description  TEXT            NULL,
        -- free-form notes, nullable because sometimes there's
        -- nothing extra to add.
    performed_at TIMESTAMP       NOT NULL
                     CHECK (performed_at > '2000-01-01'),
    next_due_at  TIMESTAMP       NULL
        -- nullable: some one-off repairs don't have a next due date.
);

-- ============================================================
-- STEP 9: ADD record_ts TO ALL TABLES
-- Adding record_ts via ALTER TABLE after all tables are created.
--
-- I originally used DATE with DEFAULT CURRENT_DATE, but my mentor
-- pointed out that this loses time precision. If 100 records are
-- inserted on the same day, DATE gives no way to know their order —
-- useless for audit trails and incremental data pipelines. I need
-- to know not just what day but the exact moment a record was created.
-- So I changed it to TIMESTAMPTZ with DEFAULT NOW().
-- TIMESTAMPTZ also stores timezone info, which matters if the app
-- ever runs across multiple regions.
-- ============================================================

ALTER TABLE vehicle_types       ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE locations           ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE employees           ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE users               ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE vehicles            ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE pricing_history     ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE vehicle_status_log  ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE trips               ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE payments            ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE maintenance_records ADD COLUMN record_ts TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- quick check: all counts should be 0 since we set a DEFAULT.
SELECT 'vehicle_types'       AS tbl, COUNT(*) FILTER (WHERE record_ts IS NULL) AS nulls FROM vehicle_types
UNION ALL SELECT 'locations',           COUNT(*) FILTER (WHERE record_ts IS NULL) FROM locations
UNION ALL SELECT 'employees',           COUNT(*) FILTER (WHERE record_ts IS NULL) FROM employees
UNION ALL SELECT 'users',               COUNT(*) FILTER (WHERE record_ts IS NULL) FROM users
UNION ALL SELECT 'vehicles',            COUNT(*) FILTER (WHERE record_ts IS NULL) FROM vehicles
UNION ALL SELECT 'pricing_history',     COUNT(*) FILTER (WHERE record_ts IS NULL) FROM pricing_history
UNION ALL SELECT 'vehicle_status_log',  COUNT(*) FILTER (WHERE record_ts IS NULL) FROM vehicle_status_log
UNION ALL SELECT 'trips',               COUNT(*) FILTER (WHERE record_ts IS NULL) FROM trips
UNION ALL SELECT 'payments',            COUNT(*) FILTER (WHERE record_ts IS NULL) FROM payments
UNION ALL SELECT 'maintenance_records', COUNT(*) FILTER (WHERE record_ts IS NULL) FROM maintenance_records;

-- ============================================================
-- SAMPLE DATA
-- To keep inserts safe and rerunnable:
-- 1. ON CONFLICT DO NOTHING — skip if row already exists.
-- 2. No hardcoded IDs — I JOIN on natural keys (email,
--    license_plate, name) to look up real PK values.
-- 3. WHERE NOT EXISTS — extra safety for tables without a
--    unique constraint to conflict on.
-- 4. trips + payments use a CTE with RETURNING — my mentor
--    suggested this is safer than joining on email + started_at
--    to find trip_id, because if two users start trips at the
--    exact same timestamp the old approach could match the wrong row.
--    With RETURNING I get the exact trip_id values just inserted.
-- ============================================================

-- vehicle_types first — everything else depends on it
INSERT INTO vehicle_types (name, price_per_minute, price_per_km) VALUES
    ('Economy',  500.00,  800.00),
    ('SUV',      900.00, 1400.00),
    ('Electric', 650.00,  950.00)
ON CONFLICT (name) DO NOTHING;

-- locations — no FK dependencies
INSERT INTO locations (name, latitude, longitude, address) VALUES
    ('Chorsu Bazaar Zone',  41.326500, 69.228900, 'Chorsu, Tashkent'),
    ('Tashkent Airport',    41.257600, 69.281100, 'TAS Airport, Tashkent'),
    ('Amir Temur Square',   41.299700, 69.240200, 'Amir Temur ko''chasi, Tashkent'),
    ('Yunusobod Mall',      41.336100, 69.284400, 'Yunusobod, Tashkent'),
    ('Minor Mosque Zone',   41.304100, 69.256700, 'Minor, Tashkent')
ON CONFLICT DO NOTHING;

-- employees — no FK dependencies
INSERT INTO employees (first_name, last_name, role, hired_at) VALUES
    ('Mansur',  'Holiqov',  'mechanic',   '2022-03-01 00:00:00'),
    ('Zulfiya', 'Nazarova', 'inspector',  '2021-07-15 00:00:00'),
    ('Sherzod', 'Ergashev', 'dispatcher', '2023-01-10 00:00:00')
ON CONFLICT DO NOTHING;

-- users — no FK dependencies
INSERT INTO users (first_name, last_name, email, phone, driver_license_no) VALUES
    ('Jasur',   'Toshmatov', 'jasur.t@mail.uz',   '+998901234567', 'UZ-DL-001122'),
    ('Nilufar', 'Yusupova',  'nilufar.y@mail.uz', '+998712345678', 'UZ-DL-003344'),
    ('Bobur',   'Karimov',   'bobur.k@mail.uz',   '+998931112233', 'UZ-DL-005566'),
    ('Dilnoza', 'Rahimova',  'dilnoza.r@mail.uz', '+998901239999', 'UZ-DL-007788'),
    ('Otabek',  'Sobirov',   'otabek.s@mail.uz',  '+998971230000', 'UZ-DL-009900')
ON CONFLICT (email) DO NOTHING;

-- vehicles — joining on type name to avoid hardcoding type_id
INSERT INTO vehicles (type_id, make, model, year, license_plate, color)
SELECT t.type_id, v.make, v.model, v.year, v.license_plate, v.color
FROM (VALUES
    ('Economy',  'Chevrolet', 'Cobalt',   2021, '01A111AA', 'White'),
    ('SUV',      'Toyota',    'Fortuner', 2022, '10B222BB', 'Black'),
    ('Economy',  'Daewoo',    'Nexia 3',  2020, '75C333CC', 'Silver'),
    ('Electric', 'BYD',       'Atto 3',   2023, '30D444DD', 'Blue'),
    ('SUV',      'Haval',     'H6',       2021, '55E555EE', 'White')
) AS v(type_name, make, model, year, license_plate, color)
JOIN vehicle_types t ON t.name = v.type_name
WHERE NOT EXISTS (
    SELECT 1 FROM vehicles WHERE license_plate = v.license_plate
);

-- pricing_history — old Economy price (2023) + current prices (2024)
-- to show the temporal pattern: valid_to = NULL means still active
INSERT INTO pricing_history (type_id, price_per_minute, price_per_km, valid_from, valid_to)
SELECT t.type_id, p.price_per_minute, p.price_per_km, p.valid_from::TIMESTAMP, p.valid_to::TIMESTAMP
FROM (VALUES
    ('Economy',  400.00,  650.00, '2023-01-01', '2023-12-31 23:59:59'),
    ('Economy',  500.00,  800.00, '2024-01-01', NULL),
    ('SUV',      900.00, 1400.00, '2024-01-01', NULL),
    ('Electric', 650.00,  950.00, '2024-01-01', NULL)
) AS p(type_name, price_per_minute, price_per_km, valid_from, valid_to)
JOIN vehicle_types t ON t.name = p.type_name
WHERE NOT EXISTS (
    SELECT 1 FROM pricing_history ph
    WHERE ph.type_id = t.type_id AND ph.valid_from = p.valid_from::TIMESTAMP
);

-- vehicle_status_log — a few transitions for 01A111AA to show
-- how valid_from/valid_to pattern works
INSERT INTO vehicle_status_log (vehicle_id, status, valid_from, valid_to, employee_id)
SELECT v.vehicle_id, s.status, s.valid_from::TIMESTAMP, s.valid_to::TIMESTAMP, NULL
FROM (VALUES
    ('01A111AA', 'available',   '2024-03-10 08:00:00', '2024-03-10 10:30:00'),
    ('01A111AA', 'in_use',      '2024-03-10 10:30:00', '2024-03-10 12:15:00'),
    ('01A111AA', 'available',   '2024-03-10 12:15:00', NULL),
    ('10B222BB', 'available',   '2024-03-10 08:00:00', NULL),
    ('75C333CC', 'maintenance', '2024-03-09 09:00:00', '2024-03-10 09:00:00'),
    ('75C333CC', 'available',   '2024-03-10 09:00:00', NULL)
) AS s(plate, status, valid_from, valid_to)
JOIN vehicles v ON v.license_plate = s.plate
WHERE NOT EXISTS (
    SELECT 1 FROM vehicle_status_log l
    WHERE l.vehicle_id = v.vehicle_id AND l.valid_from = s.valid_from::TIMESTAMP
);

-- trips + payments via CTE with RETURNING
-- I insert trips first and capture the generated trip_id values
-- via RETURNING, then use those directly in the payments INSERT.
-- Note: duration_min is NOT in the INSERT column list because it's
-- GENERATED ALWAYS AS — PostgreSQL computes it automatically.
-- If I include it, PostgreSQL will throw an error.
WITH inserted_trips AS (
    INSERT INTO trips (
        user_id, vehicle_id, start_location_id, end_location_id,
        started_at, ended_at, distance_km, cost,
        rating_score, rating_comment, rated_at
    )
    SELECT
        u.user_id,
        v.vehicle_id,
        sl.location_id,
        el.location_id,
        t.started_at::TIMESTAMP,
        t.ended_at::TIMESTAMP,
        t.distance_km::NUMERIC,
        t.cost::NUMERIC,
        t.rating_score::SMALLINT,
        t.rating_comment,
        t.rated_at::TIMESTAMP
    FROM (VALUES
        ('jasur.t@mail.uz',   '01A111AA', 'Chorsu Bazaar Zone', 'Amir Temur Square',
         '2024-03-10 10:30:00', '2024-03-10 12:15:00', 12.50, 127500.00, 5,   'Mashina juda toza edi, yoqdi', '2024-03-10 12:30:00'),
        ('nilufar.y@mail.uz', '75C333CC', 'Tashkent Airport',   'Yunusobod Mall',
         '2024-03-11 09:00:00', '2024-03-11 10:40:00',  9.80,  98200.00, 4,   'Yaxshi, lekin GPS kechikdi',   '2024-03-11 11:00:00'),
        ('bobur.k@mail.uz',   '10B222BB', 'Amir Temur Square',  'Tashkent Airport',
         '2024-03-12 15:10:00', '2024-03-12 17:00:00', 22.30, 245000.00, NULL, NULL,                           NULL),
        ('dilnoza.r@mail.uz', '30D444DD', 'Minor Mosque Zone',  'Chorsu Bazaar Zone',
         '2024-03-13 08:00:00', '2024-03-13 09:10:00',  7.20,  75400.00, 5,   'Elektr mashina juda qulay',    '2024-03-13 09:30:00'),
        ('otabek.s@mail.uz',  '55E555EE', 'Yunusobod Mall',     'Minor Mosque Zone',
         '2024-03-14 11:00:00', '2024-03-14 12:30:00', 14.10, 153000.00, 3,   'Normal, lekin salon changli',  '2024-03-14 13:00:00')
    ) AS t(email, plate, start_loc, end_loc, started_at, ended_at, distance_km, cost, rating_score, rating_comment, rated_at)
    JOIN users     u  ON u.email         = t.email
    JOIN vehicles  v  ON v.license_plate = t.plate
    JOIN locations sl ON sl.name         = t.start_loc
    JOIN locations el ON el.name         = t.end_loc
    WHERE NOT EXISTS (
        SELECT 1 FROM trips tr
        WHERE tr.user_id = u.user_id AND tr.started_at = t.started_at::TIMESTAMP
    )
    RETURNING trip_id, user_id, started_at
)
INSERT INTO payments (trip_id, user_id, amount, method, status, paid_at)
SELECT
    it.trip_id,
    it.user_id,
    p.amount::NUMERIC,
    p.method,
    p.status,
    p.paid_at::TIMESTAMP
FROM (VALUES
    ('jasur.t@mail.uz',   '2024-03-10 10:30:00', 127500.00, 'card',   'completed', '2024-03-10 12:16:00'),
    ('nilufar.y@mail.uz', '2024-03-11 09:00:00',  98200.00, 'mobile', 'completed', '2024-03-11 10:41:00'),
    ('bobur.k@mail.uz',   '2024-03-12 15:10:00', 245000.00, 'card',   'completed', '2024-03-12 17:02:00'),
    ('dilnoza.r@mail.uz', '2024-03-13 08:00:00',  75400.00, 'mobile', 'completed', '2024-03-13 09:11:00'),
    ('otabek.s@mail.uz',  '2024-03-14 11:00:00', 153000.00, 'cash',   'completed', '2024-03-14 12:31:00')
) AS p(email, started_at, amount, method, status, paid_at)
JOIN users u ON u.email = p.email
JOIN inserted_trips it  ON it.user_id    = u.user_id
                       AND it.started_at = p.started_at::TIMESTAMP
WHERE NOT EXISTS (
    SELECT 1 FROM payments pm WHERE pm.trip_id = it.trip_id
);

-- maintenance_records — lookup by license plate + employee name
INSERT INTO maintenance_records (vehicle_id, employee_id, type, description, performed_at, next_due_at)
SELECT v.vehicle_id, e.employee_id, m.type, m.description, m.performed_at::TIMESTAMP, m.next_due_at::TIMESTAMP
FROM (VALUES
    ('01A111AA', 'Mansur',  'Holiqov',  'oil change', 'Replaced engine oil and filter',         '2024-01-10 09:00:00', '2024-07-10 09:00:00'),
    ('10B222BB', 'Zulfiya', 'Nazarova', 'inspection', 'Full pre-season safety check completed', '2024-02-01 10:00:00', '2025-02-01 10:00:00'),
    ('75C333CC', 'Mansur',  'Holiqov',  'tire change', 'Winter tires replaced with summer set', '2024-03-05 11:30:00', '2025-03-05 11:30:00'),
    ('30D444DD', 'Zulfiya', 'Nazarova', 'inspection', 'Battery and motor system check',         '2024-03-08 14:00:00', '2025-03-08 14:00:00'),
    ('55E555EE', 'Mansur',  'Holiqov',  'oil change', 'Oil change and brake pad inspection',    '2024-03-09 10:00:00', '2024-09-09 10:00:00')
) AS m(plate, first_name, last_name, type, description, performed_at, next_due_at)
JOIN vehicles  v ON v.license_plate = m.plate
JOIN employees e ON e.first_name    = m.first_name AND e.last_name = m.last_name
WHERE NOT EXISTS (
    SELECT 1 FROM maintenance_records mr
    WHERE mr.vehicle_id = v.vehicle_id AND mr.performed_at = m.performed_at::TIMESTAMP
);

-- final row count check
SELECT 'vehicle_types'       AS tbl, COUNT(*) AS rows FROM vehicle_types
UNION ALL SELECT 'locations',           COUNT(*) FROM locations
UNION ALL SELECT 'employees',           COUNT(*) FROM employees
UNION ALL SELECT 'users',               COUNT(*) FROM users
UNION ALL SELECT 'vehicles',            COUNT(*) FROM vehicles
UNION ALL SELECT 'pricing_history',     COUNT(*) FROM pricing_history
UNION ALL SELECT 'vehicle_status_log',  COUNT(*) FROM vehicle_status_log
UNION ALL SELECT 'trips',               COUNT(*) FROM trips
UNION ALL SELECT 'payments',            COUNT(*) FROM payments
UNION ALL SELECT 'maintenance_records', COUNT(*) FROM maintenance_records;
