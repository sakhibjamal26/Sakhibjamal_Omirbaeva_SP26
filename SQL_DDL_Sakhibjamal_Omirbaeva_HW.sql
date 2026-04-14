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
-- a car in the wrong zone on the map. Not a huge deal but
-- DECIMAL is just cleaner for this.
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
-- if the business adds a new role later (like "fleet manager")
-- I can just insert a new value — I don't need to change the
-- schema. ENUM would require ALTER TYPE every time.
-- ============================================================

CREATE TABLE employees (
    employee_id SERIAL          PRIMARY KEY,
    first_name  VARCHAR(100)    NOT NULL,
    last_name   VARCHAR(100)    NOT NULL,
    role        VARCHAR(100)    NOT NULL
                    CHECK (role IN ('mechanic', 'inspector', 'dispatcher')),
        -- I added a CHECK here to make sure only valid role names
        -- can be inserted. Without it, someone could type "Mechanic"
        -- with a capital letter or "tech" and it would go through —
        -- then role-based filtering would silently miss those rows.
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
-- own — they can register and never take a single trip, and their
-- account still needs to be stored. If I merged users into trips
-- I'd have NULL-heavy rows for registered-but-never-booked users
-- and I'd repeat the same name and email on every trip they take.
--
-- A few data type choices worth explaining:
-- VARCHAR(255) for email: that's the standard max for email
-- addresses, so I went with that. TEXT would technically work
-- but allows unlimited length which feels wrong for an email field.
-- VARCHAR(20) for phone: phone numbers include + and spaces like
-- "+998 90 123 45 67", so I can't use INTEGER — that would lose
-- the + sign and leading zeros. VARCHAR is the right call here.
-- BOOLEAN for is_active: just true or false. Using SMALLINT (0/1)
-- would technically work but allows values like 2 or -1 which
-- don't mean anything, so BOOLEAN is cleaner.
-- ============================================================

CREATE TABLE users (
    user_id           SERIAL          PRIMARY KEY,
    first_name        VARCHAR(100)    NOT NULL,
    last_name         VARCHAR(100)    NOT NULL,
    email             VARCHAR(255)    NOT NULL UNIQUE,
        -- UNIQUE on email: two users can't share an email because
        -- it's used for login and notifications. Without this,
        -- one user could get another person's booking emails,
        -- which is both annoying and a privacy problem.
    phone             VARCHAR(20)     NOT NULL,
    driver_license_no VARCHAR(50)     NOT NULL UNIQUE,
        -- UNIQUE on license: each driver's license belongs to
        -- one person in real life, so it should be unique here too.
        -- Without this, someone could create multiple accounts
        -- with the same license and bypass identity checks.
    registered_at     TIMESTAMP       NOT NULL DEFAULT NOW(),
        -- DEFAULT NOW() means I don't have to pass this value
        -- from the app — the database fills it in automatically
        -- when a new row is inserted. Handy and consistent.
    is_active         BOOLEAN         NOT NULL DEFAULT TRUE
        -- new accounts start as active by default, makes sense.
        -- NOT NULL here is important — if this were nullable,
        -- a query like WHERE is_active = TRUE would miss NULL rows
        -- and I'd never know those accounts existed.
);

-- ============================================================
-- TABLE: vehicles
-- Child of vehicle_types, parent of trips / vehicle_status_log
-- / maintenance_records. Has to come after vehicle_types.
--
-- I decided not to put a status column directly on this table.
-- My first idea was to have a status column here and just update
-- it every time the car becomes available or goes to maintenance.
-- But then I realised you lose all history — you can't answer
-- "what was this car's status last Tuesday?" which the assignment
-- specifically asks for. So status lives in vehicle_status_log
-- instead, and I query the current status as the row where
-- valid_to IS NULL.
--
-- SMALLINT for year: manufacturing years fit comfortably in the
-- SMALLINT range and it's smaller than INTEGER. If I used TEXT,
-- someone could type '202O' (letter O instead of zero) and it
-- would pass, which SMALLINT prevents.
-- ============================================================

CREATE TABLE vehicles (
    vehicle_id    SERIAL          PRIMARY KEY,
    type_id       INTEGER         NOT NULL
                      REFERENCES vehicle_types(type_id),
        -- FK to vehicle_types: if this FK didn't exist, I could
        -- insert a vehicle with a type_id that points to nothing.
        -- Then when I try to look up the price for a trip, the
        -- JOIN would return NULL and billing would break silently.
    make          VARCHAR(100)    NOT NULL,
    model         VARCHAR(100)    NOT NULL,
    year          SMALLINT        NOT NULL
                      CHECK (year >= 2000),
        -- we only use cars from 2000 onwards, so anything earlier
        -- is a data entry mistake. This prevents someone from
        -- accidentally entering 1985 or leaving it as 0.
    license_plate VARCHAR(20)     NOT NULL UNIQUE,
        -- UNIQUE: each car has exactly one plate in real life.
        -- Without this I could end up with two different cars
        -- having the same plate, which would cause serious
        -- confusion when trying to identify vehicles in the field.
    color         VARCHAR(50)     NOT NULL
);

-- ============================================================
-- TABLE: pricing_history
-- Child of vehicle_types. I created this as a separate table
-- to keep historical pricing intact.
-- If I just updated price_per_minute on vehicle_types directly,
-- old trips would retroactively show the new price in billing
-- reports, which is wrong — a trip from 2023 should always show
-- the 2023 price. This table lets me close the old price with a
-- valid_to timestamp and add a new row for the new price,
-- so history is always preserved.
-- valid_to = NULL means this is the price currently in effect.
-- ============================================================

CREATE TABLE pricing_history (
    price_id         SERIAL          PRIMARY KEY,
    type_id          INTEGER         NOT NULL
                         REFERENCES vehicle_types(type_id),
        -- FK: without this, a pricing row could reference a
        -- vehicle type that was deleted. Then historical price
        -- lookups for billing would return nothing.
    price_per_minute NUMERIC(8,2)    NOT NULL CHECK (price_per_minute > 0),
    price_per_km     NUMERIC(8,2)    NOT NULL CHECK (price_per_km > 0),
    valid_from       TIMESTAMP       NOT NULL
                         CHECK (valid_from > '2000-01-01'),
        -- same as elsewhere — pricing before 2000 isn't possible
        -- for this business, so it's a data entry error if it appears.
    valid_to         TIMESTAMP       NULL
        -- NULL here means "this price is still active, no end date yet".
        -- It's intentionally nullable — not a missing value.
);

-- ============================================================
-- TABLE: vehicle_status_log
-- Child of vehicles and employees.
-- Every status change is a new row — I never overwrite old ones.
-- Current status = the row where valid_to IS NULL.
-- This way I can always answer historical availability questions.
--
-- employee_id is nullable here because not every status change
-- is triggered by an employee — for example, the system sets
-- status to 'in_use' automatically when a user starts a trip.
-- Only maintenance-related changes have an employee attached.
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
        -- I added CHECK here because only these four statuses
        -- are valid in the business logic. Without it, someone
        -- could insert 'free' or 'broken' and the availability
        -- filter queries would silently not work correctly.
    valid_from  TIMESTAMP       NOT NULL
                    CHECK (valid_from > '2000-01-01'),
    valid_to    TIMESTAMP       NULL,
        -- NULL = this status is still active right now.
        -- When the status changes, I set valid_to on this row
        -- and insert a new row for the new status.
    employee_id INTEGER         NULL
                    REFERENCES employees(employee_id)
        -- nullable FK: system events have no employee,
        -- maintenance events do. Without the FK, I could reference
        -- an employee that was deleted and lose the audit trail.
);

-- ============================================================
-- TABLE: trips
-- Child of users, vehicles, and locations (twice — once for
-- start, once for end). This is the main table of the whole model.
--
-- end_location_id and ended_at are nullable because they're
-- unknown while the trip is still in progress — they get filled
-- in when the user returns the car.
--
-- The rating columns (rating_score, rating_comment, rated_at)
-- used to be a separate ratings table in my original design.
-- After reviewer feedback I merged them here as nullable columns.
-- A rating is just optional extra info about a trip, so it makes
-- sense to keep it in the same row. Unrated trips just have NULL
-- in those three columns, which is fine.
--
-- NUMERIC(10,2) for cost: trip costs in UZS can be large numbers
-- like 245000.00, so I needed more digits than vehicle_types prices.
-- FLOAT would cause rounding errors in billing, INTEGER would lose
-- the decimal part. NUMERIC is the right choice.
-- ============================================================

CREATE TABLE trips (
    trip_id           SERIAL          PRIMARY KEY,
    user_id           INTEGER         NOT NULL
                          REFERENCES users(user_id),
        -- FK: without this, a trip could belong to a user that
        -- no longer exists. User history and billing reports
        -- would have orphaned rows with no user to attach to.
    vehicle_id        INTEGER         NOT NULL
                          REFERENCES vehicles(vehicle_id),
        -- FK: without this, a trip could reference a vehicle that
        -- was removed from the fleet. Fleet utilization reports
        -- would silently miss those trips or throw errors.
    start_location_id INTEGER         NOT NULL
                          REFERENCES locations(location_id),
    end_location_id   INTEGER         NULL
                          REFERENCES locations(location_id),
        -- nullable: we don't know the end location until the
        -- trip is completed. Both location FKs make sure we can't
        -- reference a zone that doesn't exist in the locations table.
    started_at        TIMESTAMP       NOT NULL
                          CHECK (started_at > '2000-01-01'),
        -- same date check as elsewhere — trips before 2000 aren't
        -- possible, and this prevents things like epoch timestamps
        -- (1970-01-01) from getting in if something goes wrong in the app.
    ended_at          TIMESTAMP       NULL,
        -- NULL while the trip is still ongoing
    distance_km       NUMERIC(8,2)    NULL
                          CHECK (distance_km IS NULL OR distance_km >= 0),
        -- distance can't be negative — that's physically impossible.
        -- I allow NULL because it's not known until the trip ends.
        -- Without the check, a pipeline bug could insert -5.00 km
        -- and the cost calculation would give a wrong result.
    duration_min      NUMERIC(8,2)    NULL
                          CHECK (duration_min IS NULL OR duration_min >= 0),
    cost              NUMERIC(10,2)   NULL
                          CHECK (cost IS NULL OR cost >= 0),
    rating_score      SMALLINT        NULL
                          CHECK (rating_score IS NULL OR rating_score BETWEEN 1 AND 5),
        -- rating is 1 to 5 stars. Without the check, a user could
        -- submit 0 or 10 and the average rating calculation
        -- would be completely off.
    rating_comment    TEXT            NULL,
    rated_at          TIMESTAMP       NULL
        -- these three rating columns are all nullable because
        -- not every trip gets rated — that's totally normal.
);

-- ============================================================
-- TABLE: payments
-- Child of trips and users.
-- I kept payments separate from trips because a payment has its
-- own lifecycle — it can be pending, failed, or refunded, which
-- doesn't map cleanly onto trip status. Also, if I put payment
-- info inside the trips table, handling refunds would be messy
-- (you'd need to add extra columns or overwrite data).
-- Having it as a separate table keeps things clean.
--
-- I stored user_id here directly (in addition to trip_id) so I
-- can query a user's payment history without always joining
-- through trips.
-- ============================================================

CREATE TABLE payments (
    payment_id SERIAL          PRIMARY KEY,
    trip_id    INTEGER         NOT NULL
                   REFERENCES trips(trip_id),
        -- FK: without this, a payment could reference a trip
        -- that doesn't exist. Financial reconciliation would
        -- find payment rows with nothing to match against.
    user_id    INTEGER         NOT NULL
                   REFERENCES users(user_id),
        -- FK: same idea — if user is deleted, we'd lose track
        -- of who made this payment.
    amount     NUMERIC(10,2)   NOT NULL
                   CHECK (amount >= 0),
        -- amount can be 0 (e.g. a promo ride) but never negative.
        -- Without this, a refund logic bug could insert -127500.00
        -- and mess up revenue totals completely.
    method     VARCHAR(50)     NOT NULL
                   CHECK (method IN ('card', 'mobile', 'cash')),
        -- only these three methods are accepted. Without the check,
        -- anything could be inserted and payment reporting would
        -- group things incorrectly.
    status     VARCHAR(20)     NOT NULL
                   CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
        -- same idea as vehicle status — only valid states allowed.
        -- Without this, invalid values like 'done' or 'ok' could
        -- enter the system and break dashboard filters.
    paid_at    TIMESTAMP       NULL
        -- NULL while the payment is still pending or failed.
        -- Gets set when payment is confirmed as completed.
);

-- ============================================================
-- TABLE: maintenance_records
-- Child of vehicles and employees. Created last because it
-- depends on both.
-- Every service event is a new row here so I have a full history.
-- I can also use next_due_at to schedule future maintenance.
-- ============================================================

CREATE TABLE maintenance_records (
    record_id    SERIAL          PRIMARY KEY,
    vehicle_id   INTEGER         NOT NULL
                     REFERENCES vehicles(vehicle_id),
        -- FK: without this, I could have service records for
        -- vehicles that no longer exist in the fleet. The
        -- maintenance history would have orphaned rows.
    employee_id  INTEGER         NOT NULL
                     REFERENCES employees(employee_id),
        -- FK: same — if an employee is removed, I'd lose track
        -- of who actually performed the service. That's important
        -- for accountability.
    type         VARCHAR(100)    NOT NULL,
    description  TEXT            NULL,
        -- free-form notes, so TEXT makes sense here.
        -- nullable because sometimes there's nothing extra to add.
    performed_at TIMESTAMP       NOT NULL
                     CHECK (performed_at > '2000-01-01'),
    next_due_at  TIMESTAMP       NULL
        -- nullable: some one-off repairs don't have a next due date.
);

-- ============================================================
-- STEP 9: ADD record_ts TO ALL TABLES
-- The task says to add a record_ts field to each table using
-- ALTER TABLE, set the default to CURRENT_DATE, and make it
-- NOT NULL. I'm doing this after all tables are created so the
-- ALTER statements run cleanly without any dependency issues.
--
-- I used DATE (not TIMESTAMP) since the task says "current_date"
-- which is a date value in PostgreSQL. This column basically just
-- tracks what date each row was inserted or last touched —
-- useful for auditing and incremental data pipelines.
-- ============================================================

ALTER TABLE vehicle_types       ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE locations           ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE employees           ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE users               ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE vehicles            ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE pricing_history     ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE vehicle_status_log  ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE trips               ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE payments            ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;
ALTER TABLE maintenance_records ADD COLUMN record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

-- quick check to make sure record_ts got set for all existing rows.
-- all counts should be 0 (no NULLs) since we set a DEFAULT.
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
-- A few things I'm doing to keep inserts safe and rerunnable:
-- 1. ON CONFLICT DO NOTHING — if the row already exists, skip it.
--    This way I can run the script multiple times without errors
--    or duplicate rows.
-- 2. No hardcoded IDs in child tables. Instead I JOIN on natural
--    keys (like email, license_plate, name) to look up the real
--    PK values. This means if IDs shift for any reason, the inserts
--    still work correctly because they look up by something meaningful.
-- 3. WHERE NOT EXISTS — extra safety net for tables where
--    ON CONFLICT alone isn't enough (e.g. when there's no unique
--    constraint to conflict on).
-- ============================================================

-- vehicle_types first since everything else depends on it
INSERT INTO vehicle_types (name, price_per_minute, price_per_km) VALUES
    ('Economy',  500.00,  800.00),
    ('SUV',      900.00, 1400.00),
    ('Electric', 650.00,  950.00)
ON CONFLICT (name) DO NOTHING;

-- locations — no FK dependencies, safe to insert early
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

-- vehicles — needs vehicle_types to exist first.
-- I'm joining on type name instead of hardcoding the type_id,
-- so this stays correct even if IDs change.
INSERT INTO vehicles (type_id, make, model, year, license_plate, color)
SELECT t.type_id, v.make, v.model, v.year, v.license_plate, v.color
FROM (VALUES
    ('Economy',  'Chevrolet', 'Cobalt',    2021, '01A111AA', 'White'),
    ('SUV',      'Toyota',    'Fortuner',  2022, '10B222BB', 'Black'),
    ('Economy',  'Daewoo',    'Nexia 3',   2020, '75C333CC', 'Silver'),
    ('Electric', 'BYD',       'Atto 3',    2023, '30D444DD', 'Blue'),
    ('SUV',      'Haval',     'H6',        2021, '55E555EE', 'White')
) AS v(type_name, make, model, year, license_plate, color)
JOIN vehicle_types t ON t.name = v.type_name
WHERE NOT EXISTS (
    SELECT 1 FROM vehicles WHERE license_plate = v.license_plate
);

-- pricing_history — needs vehicle_types.
-- I'm keeping old Economy pricing (2023) and the current prices (2024)
-- to show the temporal pattern: valid_to = NULL means still active.
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

-- vehicle_status_log — needs vehicles to exist first.
-- I'm inserting a few status transitions for one car (01A111AA)
-- to show how the valid_from/valid_to pattern works in practice.
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

-- trips — depends on users, vehicles, and locations.
-- I'm looking up all FK values by natural keys (email, plate, location name)
-- so I'm not hardcoding any IDs.
-- Bobur's trip has NULL rating columns — intentional, to show that
-- unrated trips just leave those columns empty.
INSERT INTO trips (
    user_id, vehicle_id, start_location_id, end_location_id,
    started_at, ended_at, distance_km, duration_min, cost,
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
    t.duration_min::NUMERIC,
    t.cost::NUMERIC,
    t.rating_score::SMALLINT,
    t.rating_comment,
    t.rated_at::TIMESTAMP
FROM (VALUES
    ('jasur.t@mail.uz',   '01A111AA', 'Chorsu Bazaar Zone', 'Amir Temur Square',
     '2024-03-10 10:30:00', '2024-03-10 12:15:00', 12.50, 105.0, 127500.00, 5,   'Mashina juda toza edi, yoqdi', '2024-03-10 12:30:00'),
    ('nilufar.y@mail.uz', '75C333CC', 'Tashkent Airport',   'Yunusobod Mall',
     '2024-03-11 09:00:00', '2024-03-11 10:40:00',  9.80, 100.0,  98200.00, 4,   'Yaxshi, lekin GPS kechikdi',   '2024-03-11 11:00:00'),
    ('bobur.k@mail.uz',   '10B222BB', 'Amir Temur Square',  'Tashkent Airport',
     '2024-03-12 15:10:00', '2024-03-12 17:00:00', 22.30, 110.0, 245000.00, NULL, NULL,                           NULL),
    ('dilnoza.r@mail.uz', '30D444DD', 'Minor Mosque Zone',  'Chorsu Bazaar Zone',
     '2024-03-13 08:00:00', '2024-03-13 09:10:00',  7.20,  70.0,  75400.00, 5,   'Elektr mashina juda qulay',    '2024-03-13 09:30:00'),
    ('otabek.s@mail.uz',  '55E555EE', 'Yunusobod Mall',     'Minor Mosque Zone',
     '2024-03-14 11:00:00', '2024-03-14 12:30:00', 14.10,  90.0, 153000.00, 3,   'Normal, lekin salon changli',  '2024-03-14 13:00:00')
) AS t(email, plate, start_loc, end_loc, started_at, ended_at, distance_km, duration_min, cost, rating_score, rating_comment, rated_at)
JOIN users     u  ON u.email          = t.email
JOIN vehicles  v  ON v.license_plate  = t.plate
JOIN locations sl ON sl.name          = t.start_loc
JOIN locations el ON el.name          = t.end_loc
WHERE NOT EXISTS (
    SELECT 1 FROM trips tr
    WHERE tr.user_id = u.user_id AND tr.started_at = t.started_at::TIMESTAMP
);

-- payments — depends on trips and users.
-- I'm matching each payment to its trip by joining on user email
-- + started_at timestamp, which together uniquely identify a trip.
-- No hardcoded trip_id values.
INSERT INTO payments (trip_id, user_id, amount, method, status, paid_at)
SELECT
    tr.trip_id,
    u.user_id,
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
JOIN users u  ON u.email       = p.email
JOIN trips tr ON tr.user_id    = u.user_id
             AND tr.started_at = p.started_at::TIMESTAMP
WHERE NOT EXISTS (
    SELECT 1 FROM payments pm WHERE pm.trip_id = tr.trip_id
);

-- maintenance_records — depends on vehicles and employees.
-- looking up both vehicle_id and employee_id by natural keys
-- (license plate, first + last name) to avoid hardcoding.
INSERT INTO maintenance_records (vehicle_id, employee_id, type, description, performed_at, next_due_at)
SELECT v.vehicle_id, e.employee_id, m.type, m.description, m.performed_at::TIMESTAMP, m.next_due_at::TIMESTAMP
FROM (VALUES
    ('01A111AA', 'Mansur',  'Holiqov',  'oil change',  'Replaced engine oil and filter',         '2024-01-10 09:00:00', '2024-07-10 09:00:00'),
    ('10B222BB', 'Zulfiya', 'Nazarova', 'inspection',  'Full pre-season safety check completed', '2024-02-01 10:00:00', '2025-02-01 10:00:00'),
    ('75C333CC', 'Mansur',  'Holiqov',  'tire change',  'Winter tires replaced with summer set', '2024-03-05 11:30:00', '2025-03-05 11:30:00'),
    ('30D444DD', 'Zulfiya', 'Nazarova', 'inspection',  'Battery and motor system check',         '2024-03-08 14:00:00', '2025-03-08 14:00:00'),
    ('55E555EE', 'Mansur',  'Holiqov',  'oil change',  'Oil change and brake pad inspection',    '2024-03-09 10:00:00', '2024-09-09 10:00:00')
) AS m(plate, first_name, last_name, type, description, performed_at, next_due_at)
JOIN vehicles  v ON v.license_plate = m.plate
JOIN employees e ON e.first_name    = m.first_name AND e.last_name = m.last_name
WHERE NOT EXISTS (
    SELECT 1 FROM maintenance_records mr
    WHERE mr.vehicle_id = v.vehicle_id AND mr.performed_at = m.performed_at::TIMESTAMP
);

-- final row count check — all tables should have at least 2 rows,
-- and the total across all tables should be 20+.
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
