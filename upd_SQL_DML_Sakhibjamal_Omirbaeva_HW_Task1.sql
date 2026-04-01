-- ============================================================
-- TCL & DML Homework
-- Database: dvdrental
-- Author: Sakhibjamal Omirbaeva
-- ============================================================


-- ============================================================
-- SUBTASK 1
-- Adding my 3 favorite movies to the film table:
-- Inception (2010, Action), Super Nevestka (2008, Drama),
-- Avatar (2009, Sci-Fi)
--
-- Why a separate transaction:
-- I put all 3 films in one transaction so they either all get added
-- or none of them do. If something goes wrong with the second or third
-- insert, I don't want the first one to stay in the table on its own.
--
-- What would happen if the transaction fails:
-- Postgres rolls back everything and the film table stays exactly
-- as it was before. No half-inserted data gets left behind.
--
-- Rollback:
-- Yes, fully possible. If for example the second film insert fails,
-- the first one also rolls back automatically. Nothing from this
-- block ends up in the database.
--
-- How referential integrity is preserved:
-- I look up language_id from the language table by name instead of
-- hardcoding it, so the FK reference is always valid. Category links
-- are handled separately in subtask 2 after the films are saved.
--
-- How duplicates are avoided:
-- I used WHERE NOT EXISTS on the title before each insert, so if I
-- run the script again it just skips films that are already there.
--
-- Why INSERT INTO ... SELECT instead of INSERT INTO ... VALUES:
-- With SELECT I can generate film_id dynamically using MAX(film_id) + 1
-- and look up language_id by name. If I hardcoded the IDs and someone
-- already has a film with that ID, the insert would fail or create a conflict.
-- Mentor noted that in high-concurrency environments MAX(film_id) + 1 can
-- cause race conditions if two transactions run at the same time.
-- The safer approach is nextval('film_film_id_seq') which is what I use below.
-- For this assignment MAX() + 1 would also work fine but I switched to nextval
-- to follow PostgreSQL best practice.
-- ============================================================

BEGIN;

-- verify what I am about to insert before committing
SELECT title, release_year, rental_rate, rental_duration
FROM public.film
WHERE title IN ('Inception', 'Super Nevestka', 'Avatar');

-- Inception (2010) — Action, rental rate 4.99, 1 week rental
INSERT INTO public.film (film_id, title, description, release_year, language_id,
                         rental_duration, rental_rate, replacement_cost,
                         rating, last_update)
SELECT
    nextval('film_film_id_seq'),
    'Inception',
    'A thief who steals corporate secrets through dream-sharing technology is given the task of planting an idea.',
    2010,
    (SELECT language_id FROM public.language WHERE name = 'English             '),
    7,       -- 1 week
    4.99,
    19.99,
    'PG-13',
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film WHERE title = 'Inception'
)
RETURNING film_id, title, release_year, rental_rate;

-- Super Nevestka (2008) — Drama, rental rate 9.99, 2 weeks rental
INSERT INTO public.film (film_id, title, description, release_year, language_id,
                         rental_duration, rental_rate, replacement_cost,
                         rating, last_update)
SELECT
    nextval('film_film_id_seq'),
    'Super Nevestka',
    'A beloved Uzbek romantic comedy about a young bride navigating family life with humor and heart.',
    2008,
    (SELECT language_id FROM public.language WHERE name = 'English             '),
    14,      -- 2 weeks
    9.99,
    19.99,
    'G',
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film WHERE title = 'Super Nevestka'
)
RETURNING film_id, title, release_year, rental_rate;

-- Avatar (2009) — Sci-Fi, rental rate 19.99, 3 weeks rental
INSERT INTO public.film (film_id, title, description, release_year, language_id,
                         rental_duration, rental_rate, replacement_cost,
                         rating, last_update)
SELECT
    nextval('film_film_id_seq'),
    'Avatar',
    'A paraplegic Marine is sent to the moon Pandora on a mission that puts him in conflict with the native Na''vi people.',
    2009,
    (SELECT language_id FROM public.language WHERE name = 'English             '),
    21,      -- 3 weeks
    19.99,
    19.99,
    'PG-13',
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film WHERE title = 'Avatar'
)
RETURNING film_id, title, release_year, rental_rate;

COMMIT;


-- ============================================================
-- SUBTASK 2
-- Linking each film to its category in film_category.
-- Inception -> Action, Super Nevestka -> Drama, Avatar -> Sci-Fi
--
-- Why a separate transaction:
-- Category links depend on the films being there first (subtask 1).
-- I kept this separate so if something fails here, the films I added
-- in subtask 1 are already safely committed and won't roll back.
--
-- What happens if the transaction fails:
-- All 3 category links roll back together. The film table stays intact.
-- No partial linking happens — either all 3 are linked or none.
--
-- Rollback:
-- Yes, fully possible. No partial state gets left behind.
--
-- How referential integrity is preserved:
-- I look up film_id by title (must exist from subtask 1) and
-- category_id by name (always exists in the category table).
-- So both FK references are valid before the insert runs.
--
-- How duplicates are avoided:
-- WHERE NOT EXISTS checks the film_id + category_id pair before each
-- insert, so re-running the script won't create duplicate links.
--
-- Why INSERT INTO ... SELECT instead of INSERT INTO ... VALUES:
-- I look up film_id and category_id by name dynamically instead of
-- hardcoding numbers. This works correctly even if IDs are different
-- in another database instance.
-- ============================================================

BEGIN;

-- verify before inserting
SELECT f.title, c.name AS category
FROM public.film f
JOIN public.film_category fc ON f.film_id = fc.film_id
JOIN public.category c ON fc.category_id = c.category_id
WHERE f.title IN ('Inception', 'Super Nevestka', 'Avatar');

-- Inception -> Action
INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT
    (SELECT film_id FROM public.film WHERE title = 'Inception'),
    (SELECT category_id FROM public.category WHERE name = 'Action'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_category
    WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
      AND category_id = (SELECT category_id FROM public.category WHERE name = 'Action')
)
RETURNING film_id, category_id;

-- Super Nevestka -> Drama
INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT
    (SELECT film_id FROM public.film WHERE title = 'Super Nevestka'),
    (SELECT category_id FROM public.category WHERE name = 'Drama'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_category
    WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
      AND category_id = (SELECT category_id FROM public.category WHERE name = 'Drama')
)
RETURNING film_id, category_id;

-- Avatar -> Sci-Fi
INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT
    (SELECT film_id FROM public.film WHERE title = 'Avatar'),
    (SELECT category_id FROM public.category WHERE name = 'Sci-Fi'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_category
    WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
      AND category_id = (SELECT category_id FROM public.category WHERE name = 'Sci-Fi')
)
RETURNING film_id, category_id;

COMMIT;


-- ============================================================
-- SUBTASK 3
-- Adding 8 real actors to the actor table (task requires 6 minimum):
-- Inception: Leonardo DiCaprio, Joseph Gordon-Levitt, Elliot Page, Tom Hardy
-- Super Nevestka: Yulduz Rajabova, Bahrom Matchanov
-- Avatar: Sam Worthington, Zoe Saldana
--
-- Why a separate transaction:
-- Actors are independent from films so I kept them in their own block.
-- If this fails, the films and categories from subtasks 1 and 2
-- are already safely committed and won't be affected.
--
-- What happens if the transaction fails:
-- All actor inserts roll back together. No partial actor list is saved.
-- Films stay in the database, actors just don't get added.
--
-- Rollback:
-- Yes, fully possible. No side effects on any previous subtask.
--
-- How referential integrity is preserved:
-- The film_actor inserts below look up actor_id and film_id by name.
-- Since actors and films are both committed before film_actor runs,
-- the FK references are guaranteed to be valid.
--
-- How duplicates are avoided:
-- For actors I check WHERE NOT EXISTS on first_name + last_name.
-- For film_actor I check the actor_id + film_id pair.
-- Both make the script safe to re-run without creating duplicates.
--
-- Why INSERT INTO ... SELECT instead of INSERT INTO ... VALUES:
-- actor_id is generated with MAX(actor_id) + 1 so it always picks
-- the right next ID based on what's currently in the table.
-- Hardcoding an ID could cause a conflict if that ID is already taken.
-- ============================================================

BEGIN;

-- verify actors before inserting
SELECT first_name, last_name FROM public.actor
WHERE (first_name = 'Leonardo' AND last_name = 'DiCaprio')
   OR (first_name = 'Joseph'   AND last_name = 'Gordon-Levitt')
   OR (first_name = 'Elliot'   AND last_name = 'Page')
   OR (first_name = 'Tom'      AND last_name = 'Hardy')
   OR (first_name = 'Yulduz'   AND last_name = 'Rajabova')
   OR (first_name = 'Bahrom'   AND last_name = 'Matchanov')
   OR (first_name = 'Sam'      AND last_name = 'Worthington')
   OR (first_name = 'Zoe'      AND last_name = 'Saldana');

-- inserting actors only if they don't already exist in the table
INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Leonardo', 'DiCaprio', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Leonardo' AND last_name = 'DiCaprio')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Joseph', 'Gordon-Levitt', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Joseph' AND last_name = 'Gordon-Levitt')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Elliot', 'Page', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Elliot' AND last_name = 'Page')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Tom', 'Hardy', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Tom' AND last_name = 'Hardy')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Yulduz', 'Rajabova', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Yulduz' AND last_name = 'Rajabova')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Bahrom', 'Matchanov', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Bahrom' AND last_name = 'Matchanov')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Sam', 'Worthington', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Sam' AND last_name = 'Worthington')
RETURNING actor_id, first_name, last_name;

INSERT INTO public.actor (actor_id, first_name, last_name, last_update)
SELECT (SELECT MAX(actor_id) + 1 FROM public.actor), 'Zoe', 'Saldana', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM public.actor WHERE first_name = 'Zoe' AND last_name = 'Saldana')
RETURNING actor_id, first_name, last_name;

COMMIT;


-- ============================================================
-- Linking actors to their films in film_actor.
-- This is in its own transaction separate from the actor inserts above.
--
-- Why a separate transaction:
-- Actors have to exist before I can link them to films.
-- Keeping this separate means if the linking fails, the actors
-- I just inserted are still saved — I only need to re-run this block.
--
-- What happens if the transaction fails:
-- All film_actor links roll back. Actors stay in the actor table.
-- No orphan records get created anywhere.
--
-- Rollback:
-- Yes, fully possible. No partial linking is left behind.
--
-- How referential integrity is preserved:
-- I look up actor_id and film_id by name — both reference rows that
-- were committed in earlier subtasks so they're guaranteed to exist.
--
-- How duplicates are avoided:
-- WHERE NOT EXISTS checks the actor_id + film_id combination before
-- each insert, so running the script again won't add duplicate pairs.
-- ============================================================

BEGIN;

-- Inception actors
INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Leonardo' AND last_name = 'DiCaprio'),
    (SELECT film_id FROM public.film WHERE title = 'Inception'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Leonardo' AND last_name = 'DiCaprio')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
)
RETURNING actor_id, film_id;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Joseph' AND last_name = 'Gordon-Levitt'),
    (SELECT film_id FROM public.film WHERE title = 'Inception'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Joseph' AND last_name = 'Gordon-Levitt')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
)
RETURNING actor_id, film_id;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Elliot' AND last_name = 'Page'),
    (SELECT film_id FROM public.film WHERE title = 'Inception'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Elliot' AND last_name = 'Page')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
)
RETURNING actor_id, film_id;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Tom' AND last_name = 'Hardy'),
    (SELECT film_id FROM public.film WHERE title = 'Inception'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Tom' AND last_name = 'Hardy')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
)
RETURNING actor_id, film_id;

-- Super Nevestka actors
INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Yulduz' AND last_name = 'Rajabova'),
    (SELECT film_id FROM public.film WHERE title = 'Super Nevestka'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Yulduz' AND last_name = 'Rajabova')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
)
RETURNING actor_id, film_id;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Bahrom' AND last_name = 'Matchanov'),
    (SELECT film_id FROM public.film WHERE title = 'Super Nevestka'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Bahrom' AND last_name = 'Matchanov')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
)
RETURNING actor_id, film_id;

-- Avatar actors
INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Sam' AND last_name = 'Worthington'),
    (SELECT film_id FROM public.film WHERE title = 'Avatar'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Sam' AND last_name = 'Worthington')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
)
RETURNING actor_id, film_id;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    (SELECT actor_id FROM public.actor WHERE first_name = 'Zoe' AND last_name = 'Saldana'),
    (SELECT film_id FROM public.film WHERE title = 'Avatar'),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.film_actor
    WHERE actor_id = (SELECT actor_id FROM public.actor WHERE first_name = 'Zoe' AND last_name = 'Saldana')
      AND film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
)
RETURNING actor_id, film_id;

COMMIT;


-- ============================================================
-- SUBTASK 4
-- Adding all 3 films to store 1's inventory.
-- I look up store_id dynamically as the first store in the table
-- so no IDs are hardcoded anywhere.
--
-- Why a separate transaction:
-- Inventory inserts need the films to exist first (subtask 1).
-- Keeping this in its own block means if it fails, films and actors
-- from earlier subtasks are already safely committed.
--
-- What happens if the transaction fails:
-- All 3 inventory inserts roll back together. No film gets partially
-- added to inventory. Everything from previous subtasks stays intact.
--
-- Rollback:
-- Yes, fully possible. Clean rollback with no side effects.
--
-- How referential integrity is preserved:
-- film_id is looked up from public.film by title (inserted in subtask 1).
-- store_id is looked up from public.store dynamically — it always exists.
-- So both FK references are valid before any row is inserted.
--
-- How duplicates are avoided:
-- WHERE NOT EXISTS checks if this film + store combination already exists
-- before inserting. I can re-run this block safely with no duplicate rows.
--
-- Why INSERT INTO ... SELECT instead of INSERT INTO ... VALUES:
-- inventory_id, film_id and store_id are all resolved dynamically.
-- No numeric IDs are hardcoded so the script works on any database state.
-- ============================================================

BEGIN;

-- verify before inserting
SELECT f.title, i.store_id
FROM public.inventory i
JOIN public.film f ON i.film_id = f.film_id
WHERE f.title IN ('Inception', 'Super Nevestka', 'Avatar');

INSERT INTO public.inventory (inventory_id, film_id, store_id, last_update)
SELECT
    (SELECT MAX(inventory_id) + 1 FROM public.inventory),
    (SELECT film_id FROM public.film WHERE title = 'Inception'),
    (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.inventory
    WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
      AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
)
RETURNING inventory_id, film_id, store_id;

INSERT INTO public.inventory (inventory_id, film_id, store_id, last_update)
SELECT
    (SELECT MAX(inventory_id) + 1 FROM public.inventory),
    (SELECT film_id FROM public.film WHERE title = 'Super Nevestka'),
    (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.inventory
    WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
      AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
)
RETURNING inventory_id, film_id, store_id;

INSERT INTO public.inventory (inventory_id, film_id, store_id, last_update)
SELECT
    (SELECT MAX(inventory_id) + 1 FROM public.inventory),
    (SELECT film_id FROM public.film WHERE title = 'Avatar'),
    (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.inventory
    WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
      AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
)
RETURNING inventory_id, film_id, store_id;

COMMIT;


-- ============================================================
-- SUBTASK 5
-- Updating an existing customer record with my personal info.
--
-- Why a separate transaction:
-- I isolated this UPDATE so if it fails, nothing from the other
-- subtasks is touched. Only this one change rolls back.
--
-- What happens if the transaction fails:
-- The customer record stays as it was. No other table is affected.
-- The UPDATE is atomic — either it fully applies or not at all.
--
-- Rollback:
-- Yes. If the WHERE subquery finds no matching customer or a constraint
-- fails, Postgres rolls back just this transaction. All data stays intact.
--
-- How referential integrity is preserved:
-- I update address_id to point to an existing row in public.address,
-- looked up dynamically — I don't touch the address table itself.
-- The task says not to modify it since the same address_id can be
-- linked to multiple customers and changing it would affect all of them.
--
-- How duplicates are avoided:
-- This is an UPDATE not an INSERT so no duplicate records are created.
-- The SELECT before the UPDATE shows exactly which row will be changed
-- before I commit, so I can verify it's the right one.
--
-- Why UPDATE ... WHERE customer_id = (SELECT ...):
-- I find the customer dynamically by counting their rentals and payments
-- instead of hardcoding a customer_id. This way the script works
-- correctly on any version of the database.
-- Mentor noted that my original approach using two correlated COUNT subqueries
-- runs a separate subquery for each customer row which is inefficient.
-- I switched to a JOIN with HAVING which is faster and more readable.
-- ============================================================

BEGIN;

-- verify which customer I am about to update before committing
SELECT c.customer_id, c.first_name, c.last_name, c.email, c.address_id, a.address
FROM public.customer c
JOIN public.address a ON c.address_id = a.address_id
WHERE c.customer_id = (
    SELECT c.customer_id
    FROM public.customer c
    INNER JOIN public.rental r ON r.customer_id = c.customer_id
    INNER JOIN public.payment p ON p.customer_id = c.customer_id
    GROUP BY c.customer_id
    HAVING COUNT(DISTINCT r.rental_id) >= 43
       AND COUNT(DISTINCT p.payment_id) >= 43
    ORDER BY c.customer_id
    LIMIT 1
);

UPDATE public.customer
SET first_name  = 'Sakhibjamal',
    last_name   = 'Omirbaeva',
    email       = 'Sakhibjamal.Omirbaeva@sakilacustomer.org',
    -- I update address_id to point to an existing address in the address table.
    -- I picked address_id = 1 ('47 MySakila Drive') which is a valid existing address.
    -- I am NOT modifying the address table itself — just changing which address
    -- this customer record points to.
    address_id  = (SELECT address_id FROM public.address ORDER BY address_id LIMIT 1),
    last_update = CURRENT_DATE
WHERE customer_id = (
    -- find the first customer who has at least 43 rentals and 43 payments
    -- using JOIN + HAVING instead of correlated subqueries — mentor noted this is more efficient
    SELECT c.customer_id
    FROM public.customer c
    INNER JOIN public.rental r ON r.customer_id = c.customer_id
    INNER JOIN public.payment p ON p.customer_id = c.customer_id
    GROUP BY c.customer_id
    HAVING COUNT(DISTINCT r.rental_id) >= 43
       AND COUNT(DISTINCT p.payment_id) >= 43
    ORDER BY c.customer_id
    LIMIT 1
)
RETURNING customer_id, first_name, last_name, email, address_id;

COMMIT;


-- ============================================================
-- SUBTASK 6
-- Deleting all my records from payment and rental tables.
-- customer and inventory are kept as the task requires.
--
-- Why a separate transaction:
-- I need both deletes to succeed together. If the rental delete fails
-- after payments are already deleted, the data would be in a broken state.
-- One transaction makes sure both happen or neither does.
--
-- What happens if the transaction fails:
-- Both deletes roll back. payment and rental stay exactly as they were.
-- No data is lost accidentally.
--
-- Rollback:
-- Yes, fully possible. If DELETE FROM rental fails, the DELETE FROM payment
-- also rolls back automatically. The database stays consistent.
--
-- Why deleting is safe:
-- I only delete rows where customer_id matches my name — Sakhibjamal Omirbaeva.
-- No other customer's records are touched. Inventory is not affected at all,
-- the films stay in the store.
--
-- How I ensured no unintended data loss:
-- I run two SELECT COUNT(*) queries inside the transaction before the deletes
-- so I can see exactly how many rows will be removed before committing.
-- customer_id is looked up by name, not hardcoded, so the filter is precise.
--
-- Delete order (FK constraints):
-- 1. payment first — it references rental_id so it must go before rental
-- 2. rental second — it references customer_id
-- Doing it the other way around would cause an FK violation error.
-- ============================================================

BEGIN;

-- verify what we are about to delete before committing
SELECT COUNT(*) AS payment_count
FROM public.payment
WHERE customer_id = (
    SELECT customer_id FROM public.customer
    WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'
);

SELECT COUNT(*) AS rental_count
FROM public.rental
WHERE customer_id = (
    SELECT customer_id FROM public.customer
    WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'
);

-- delete payments first because they reference rentals
DELETE FROM public.payment
WHERE customer_id = (
    SELECT customer_id FROM public.customer
    WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'
);

-- then delete rentals
DELETE FROM public.rental
WHERE customer_id = (
    SELECT customer_id FROM public.customer
    WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'
);

COMMIT;


-- ============================================================
-- SUBTASK 7
-- Renting my 3 favorite movies from the store and paying for them.
-- This adds records to rental and payment tables.
--
-- Why separate transactions for rentals and payments:
-- Payments have a FK reference to rental_id, so rentals have to be
-- committed before payments can reference them. Two separate transactions
-- make sure rentals are saved first, then payments. If payments fail,
-- the rental records are still there safely.
--
-- What happens if a transaction fails:
-- Rental transaction: all 3 rental inserts roll back. No orphan records.
-- Payment transaction: all 3 payment inserts roll back. Rentals stay intact.
--
-- Rollback:
-- Yes, both transactions can be rolled back independently.
-- Only the rows in that specific block are affected.
--
-- How referential integrity is preserved:
-- rental references inventory_id (subtask 4), customer_id (subtask 5),
-- and staff_id from public.staff — all looked up dynamically by name.
-- payment references rental_id which is inserted just above in this script.
--
-- How duplicates are avoided:
-- WHERE NOT EXISTS on inventory_id + customer_id + rental_date prevents
-- duplicate rentals. For payments I check customer_id + rental_id.
-- Running the script twice skips records that already exist.
--
-- Why INSERT INTO ... SELECT instead of INSERT INTO ... VALUES:
-- All IDs (rental_id, payment_id, inventory_id, customer_id, staff_id)
-- are resolved dynamically via subqueries — nothing is hardcoded.
-- This means the script works correctly no matter what the current ID
-- state of the database is.
--
-- rental_date is January 2017 so payments fall into the
-- payment_p2017_01 partition as the task note suggests.
-- ============================================================

BEGIN;

-- verify inventory is in place before renting
SELECT f.title, i.store_id, i.inventory_id
FROM public.inventory i
JOIN public.film f ON i.film_id = f.film_id
WHERE f.title IN ('Inception', 'Super Nevestka', 'Avatar')
  AND i.store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1);

-- rent Inception (7 day rental)
INSERT INTO public.rental (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT
    (SELECT MAX(rental_id) + 1 FROM public.rental),
    '2017-01-15 10:00:00+00',
    (SELECT inventory_id FROM public.inventory
     WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
       AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    (SELECT customer_id FROM public.customer WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'),
    '2017-01-22 10:00:00+00',
    (SELECT staff_id FROM public.staff
     WHERE store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.rental
    WHERE inventory_id = (SELECT inventory_id FROM public.inventory
                          WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
                            AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
                          LIMIT 1)
      AND customer_id = (SELECT customer_id FROM public.customer
                         WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
      AND rental_date = '2017-01-15 10:00:00+00'
)
RETURNING rental_id, inventory_id, customer_id, rental_date;

-- rent Super Nevestka (14 day rental)
INSERT INTO public.rental (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT
    (SELECT MAX(rental_id) + 1 FROM public.rental),
    '2017-01-15 10:05:00+00',
    (SELECT inventory_id FROM public.inventory
     WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
       AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    (SELECT customer_id FROM public.customer WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'),
    '2017-01-29 10:05:00+00',
    (SELECT staff_id FROM public.staff
     WHERE store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.rental
    WHERE inventory_id = (SELECT inventory_id FROM public.inventory
                          WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
                            AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
                          LIMIT 1)
      AND customer_id = (SELECT customer_id FROM public.customer
                         WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
      AND rental_date = '2017-01-15 10:05:00+00'
)
RETURNING rental_id, inventory_id, customer_id, rental_date;

-- rent Avatar (21 day rental)
INSERT INTO public.rental (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT
    (SELECT MAX(rental_id) + 1 FROM public.rental),
    '2017-01-15 10:10:00+00',
    (SELECT inventory_id FROM public.inventory
     WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
       AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    (SELECT customer_id FROM public.customer WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'),
    '2017-02-05 10:10:00+00',
    (SELECT staff_id FROM public.staff
     WHERE store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    CURRENT_DATE
WHERE NOT EXISTS (
    SELECT 1 FROM public.rental
    WHERE inventory_id = (SELECT inventory_id FROM public.inventory
                          WHERE film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
                            AND store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
                          LIMIT 1)
      AND customer_id = (SELECT customer_id FROM public.customer
                         WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
      AND rental_date = '2017-01-15 10:10:00+00'
)
RETURNING rental_id, inventory_id, customer_id, rental_date;

COMMIT;


-- ============================================================
-- Payments for the 3 rentals above.
-- Amount matches the rental_rate of each film:
-- Inception 4.99, Super Nevestka 9.99, Avatar 19.99.
-- Mentor noted that hardcoding the amounts is technically acceptable
-- for historical payment records like these, but suggested looking up
-- rental_rate dynamically from the film table so if the rate ever changes
-- the script automatically picks up the new value. I applied that here.
--
-- Why a separate transaction:
-- Payments reference rental_id (FK) so the rentals above had to be
-- committed first. If payments fail here, the rental records stay safe.
--
-- What happens if the transaction fails:
-- All 3 payment inserts roll back. Rental records are not affected.
-- Rollback is fully possible with no data loss.
--
-- How referential integrity is preserved:
-- rental_id is looked up from public.rental by customer + film name.
-- customer_id and staff_id are also resolved dynamically — no hardcoding.
--
-- How duplicates are avoided:
-- WHERE NOT EXISTS checks customer_id + rental_id before each insert.
-- If I run the script again, payments that already exist are just skipped.
-- ============================================================

BEGIN;

-- verify rentals exist before paying
SELECT r.rental_id, f.title, r.rental_date
FROM public.rental r
JOIN public.inventory i ON r.inventory_id = i.inventory_id
JOIN public.film f ON i.film_id = f.film_id
WHERE r.customer_id = (
    SELECT customer_id FROM public.customer
    WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'
);

-- pay for Inception
INSERT INTO public.payment (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
SELECT
    (SELECT MAX(payment_id) + 1 FROM public.payment),
    (SELECT customer_id FROM public.customer WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'),
    (SELECT staff_id FROM public.staff
     WHERE store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    (SELECT r.rental_id FROM public.rental r
     JOIN public.inventory i ON r.inventory_id = i.inventory_id
     WHERE i.film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
       AND r.customer_id = (SELECT customer_id FROM public.customer
                            WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
     LIMIT 1),
    (SELECT rental_rate FROM public.film WHERE title = 'Inception'),
    '2017-01-15 10:00:00+00'
WHERE NOT EXISTS (
    SELECT 1 FROM public.payment
    WHERE customer_id = (SELECT customer_id FROM public.customer
                         WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
      AND rental_id = (SELECT r.rental_id FROM public.rental r
                       JOIN public.inventory i ON r.inventory_id = i.inventory_id
                       WHERE i.film_id = (SELECT film_id FROM public.film WHERE title = 'Inception')
                         AND r.customer_id = (SELECT customer_id FROM public.customer
                                              WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
                       LIMIT 1)
)
RETURNING payment_id, customer_id, rental_id, amount, payment_date;

-- pay for Super Nevestka
INSERT INTO public.payment (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
SELECT
    (SELECT MAX(payment_id) + 1 FROM public.payment),
    (SELECT customer_id FROM public.customer WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'),
    (SELECT staff_id FROM public.staff
     WHERE store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    (SELECT r.rental_id FROM public.rental r
     JOIN public.inventory i ON r.inventory_id = i.inventory_id
     WHERE i.film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
       AND r.customer_id = (SELECT customer_id FROM public.customer
                            WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
     LIMIT 1),
    (SELECT rental_rate FROM public.film WHERE title = 'Super Nevestka'),
    '2017-01-15 10:05:00+00'
WHERE NOT EXISTS (
    SELECT 1 FROM public.payment
    WHERE customer_id = (SELECT customer_id FROM public.customer
                         WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
      AND rental_id = (SELECT r.rental_id FROM public.rental r
                       JOIN public.inventory i ON r.inventory_id = i.inventory_id
                       WHERE i.film_id = (SELECT film_id FROM public.film WHERE title = 'Super Nevestka')
                         AND r.customer_id = (SELECT customer_id FROM public.customer
                                              WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
                       LIMIT 1)
)
RETURNING payment_id, customer_id, rental_id, amount, payment_date;

-- pay for Avatar
INSERT INTO public.payment (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
SELECT
    (SELECT MAX(payment_id) + 1 FROM public.payment),
    (SELECT customer_id FROM public.customer WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva'),
    (SELECT staff_id FROM public.staff
     WHERE store_id = (SELECT store_id FROM public.store ORDER BY store_id LIMIT 1)
     LIMIT 1),
    (SELECT r.rental_id FROM public.rental r
     JOIN public.inventory i ON r.inventory_id = i.inventory_id
     WHERE i.film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
       AND r.customer_id = (SELECT customer_id FROM public.customer
                            WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
     LIMIT 1),
    (SELECT rental_rate FROM public.film WHERE title = 'Avatar'),
    '2017-01-15 10:10:00+00'
WHERE NOT EXISTS (
    SELECT 1 FROM public.payment
    WHERE customer_id = (SELECT customer_id FROM public.customer
                         WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
      AND rental_id = (SELECT r.rental_id FROM public.rental r
                       JOIN public.inventory i ON r.inventory_id = i.inventory_id
                       WHERE i.film_id = (SELECT film_id FROM public.film WHERE title = 'Avatar')
                         AND r.customer_id = (SELECT customer_id FROM public.customer
                                              WHERE first_name = 'Sakhibjamal' AND last_name = 'Omirbaeva')
                       LIMIT 1)
)
RETURNING payment_id, customer_id, rental_id, amount, payment_date;

COMMIT;
