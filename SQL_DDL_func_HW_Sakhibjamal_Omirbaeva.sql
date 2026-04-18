-- ============================================================
-- Tasks: Applying Views and Functions
-- Database: dvdrental
-- Author: Sakhibjamal Omirbaeva
-- ============================================================

-- I create the core schema here because tasks 3 and 4 use core.function_name format
CREATE SCHEMA IF NOT EXISTS core;


-- ============================================================
-- TASK 1: View — sales_revenue_by_category_qtr
-- ============================================================

/*
  I create this view to show total rental revenue per film category
  for the CURRENT quarter and year only.

  How I determine current quarter:
    I use EXTRACT(QUARTER FROM CURRENT_DATE) — this returns 1, 2, 3, or 4
    depending on the current month. No hardcoding needed.

  How I determine current year:
    I use EXTRACT(YEAR FROM CURRENT_DATE) — evaluated at query time automatically.

  Why only categories with sales appear:
    I join through payment → rental → inventory → film_category → category.
    If a category has no payment records in this quarter, it produces no rows
    due to the INNER JOIN chain. HAVING SUM > 0 is an extra safety net.

  How zero-sales categories are excluded:
    The INNER JOIN on payment naturally filters them out.
    I also add HAVING SUM(p.amount) > 0 to be explicit and safe.

  Note on current dvdrental data:
    The sample database only contains payments from 2007.
    So running SELECT * FROM sales_revenue_by_category_qtr today (2026)
    returns 0 rows — this is expected, not a bug in my view.
    I verified the logic by running a manual query using WHERE year = 2007
    (see test query 2 below) and it returned correct results.

  Example of data that should NOT appear:
    If category 'Travel' had no rentals/payments in Q2 2007,
    it should not appear when checking that quarter — and it doesn't.
*/

CREATE OR REPLACE VIEW sales_revenue_by_category_qtr AS
SELECT
    c.name          AS category,
    SUM(p.amount)   AS total_revenue
FROM payment p
JOIN rental r         ON p.rental_id    = r.rental_id
JOIN inventory i      ON r.inventory_id = i.inventory_id
JOIN film_category fc ON i.film_id      = fc.film_id
JOIN category c       ON fc.category_id = c.category_id
WHERE EXTRACT(QUARTER FROM p.payment_date) = EXTRACT(QUARTER FROM CURRENT_DATE)
  AND EXTRACT(YEAR   FROM p.payment_date) = EXTRACT(YEAR   FROM CURRENT_DATE)
GROUP BY c.name
HAVING SUM(p.amount) > 0
ORDER BY total_revenue DESC;


-- Test 1 — valid input (runs fine, returns 0 rows because no 2026 data):
SELECT * FROM sales_revenue_by_category_qtr;
-- Expected: 0 rows — correct, dvdrental has no 2026 payments

-- Test 2 — I verify the logic manually using 2007 data (Q2):
SELECT c.name AS category, SUM(p.amount) AS total_revenue
FROM payment p
JOIN rental r         ON p.rental_id    = r.rental_id
JOIN inventory i      ON r.inventory_id = i.inventory_id
JOIN film_category fc ON i.film_id      = fc.film_id
JOIN category c       ON fc.category_id = c.category_id
WHERE EXTRACT(QUARTER FROM p.payment_date) = 2
  AND EXTRACT(YEAR   FROM p.payment_date) = 2007
GROUP BY c.name
HAVING SUM(p.amount) > 0
ORDER BY total_revenue DESC;
-- Expected: categories like Sports, Animation, etc. with positive revenues


-- ============================================================
-- TASK 2: Query language function — get_sales_revenue_by_category_qtr
-- ============================================================

/*
  I create this function as the parameterized version of the view above.

  Why the parameter is needed:
    The view is locked to CURRENT_DATE and always shows the live quarter.
    This function lets me pass any date to query a specific quarter —
    useful for historical reporting, testing, or checking past quarters.

  Parameter: input_date DATE
    I use a single DATE because it carries both year and quarter in one value.
    Inside the function I extract QUARTER and YEAR from it — clean and simple.

  What happens if invalid quarter is passed:
    PostgreSQL validates DATE type before the function even runs.
    Something like '2007-13-01' raises a cast error immediately.
    NULL input returns 0 rows — WHERE with NULL comparisons matches nothing,
    which is safe behavior (no exception needed for NULL).

  What happens if no data exists for that quarter:
    The function returns 0 rows — totally valid, not an error.
    Example: passing CURRENT_DATE returns 0 rows because dvdrental has no 2026 data.
*/

CREATE OR REPLACE FUNCTION get_sales_revenue_by_category_qtr(input_date DATE)
RETURNS TABLE(category TEXT, total_revenue NUMERIC)
LANGUAGE sql
AS $$
    SELECT
        c.name::TEXT      AS category,
        SUM(p.amount)     AS total_revenue
    FROM payment p
    JOIN rental r         ON p.rental_id    = r.rental_id
    JOIN inventory i      ON r.inventory_id = i.inventory_id
    JOIN film_category fc ON i.film_id      = fc.film_id
    JOIN category c       ON fc.category_id = c.category_id
    WHERE EXTRACT(QUARTER FROM p.payment_date) = EXTRACT(QUARTER FROM input_date)
      AND EXTRACT(YEAR   FROM p.payment_date) = EXTRACT(YEAR   FROM input_date)
    GROUP BY c.name
    HAVING SUM(p.amount) > 0
    ORDER BY total_revenue DESC;
$$;


-- Test 1 — valid input with data (Q2 2007):
SELECT * FROM get_sales_revenue_by_category_qtr('2007-04-01');
-- Expected: categories with their revenues for Q2 2007

-- Test 2 — edge case: current date (no 2026 data):
SELECT * FROM get_sales_revenue_by_category_qtr(CURRENT_DATE);
-- Expected: 0 rows — correct behavior, no exception

-- Test 3 — NULL input:
SELECT * FROM get_sales_revenue_by_category_qtr(NULL);
-- Expected: 0 rows — NULL in WHERE conditions matches nothing, safe result


-- ============================================================
-- TASK 3: Procedure language function — core.most_popular_films_by_countries
-- ============================================================

/*
  I create this function to return the single most popular film for each
  country in the input array.

  How I define 'most popular':
    I count the total number of rentals per film per country.
    The film with the highest rental count wins.
    I chose rentals over revenue because popularity means how many people
    actually watched the film, not how much money it made.

  How I handle ties:
    If two films have the same rental count, I pick the one with higher revenue.
    If still tied after that, I sort alphabetically by title for a deterministic result.
    I implement this using ROW_NUMBER() OVER (PARTITION BY country ORDER BY ...).

  What happens if a country has no data:
    That country simply won't appear in the results — no error is raised.
    I use INNER JOINs, so countries with no rental activity produce no rows.
    The caller gets fewer rows than countries they passed in — that's expected.
*/

CREATE OR REPLACE FUNCTION core.most_popular_films_by_countries(countries TEXT[])
RETURNS TABLE(
    country      TEXT,
    film         TEXT,
    rating       TEXT,
    language     TEXT,
    length       SMALLINT,
    release_year INTEGER
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- I check the input is not null or empty before running anything
    IF countries IS NULL OR array_length(countries, 1) IS NULL THEN
        RAISE EXCEPTION 'Input array cannot be NULL or empty.';
    END IF;

    RETURN QUERY
    WITH film_rentals_by_country AS (
        -- I count rentals and total revenue per film per country
        SELECT
            co.country                          AS country,
            f.film_id,
            f.title                             AS film,
            f.rating::TEXT                      AS rating,
            l.name                              AS language,
            f.length,
            f.release_year::INTEGER             AS release_year,
            COUNT(r.rental_id)                  AS rental_count,
            COALESCE(SUM(p.amount), 0)          AS revenue
        FROM rental r
        JOIN inventory i  ON r.inventory_id = i.inventory_id
        JOIN film f        ON i.film_id      = f.film_id
        JOIN language l    ON f.language_id  = l.language_id
        LEFT JOIN payment p ON r.rental_id   = p.rental_id
        JOIN customer cu   ON r.customer_id  = cu.customer_id
        JOIN address a     ON cu.address_id  = a.address_id
        JOIN city ci       ON a.city_id      = ci.city_id
        JOIN country co    ON ci.country_id  = co.country_id
        WHERE co.country = ANY(countries)
        GROUP BY co.country, f.film_id, f.title, f.rating, l.name, f.length, f.release_year
    ),
    ranked AS (
        -- I rank films within each country: most rentals first, then most revenue, then alphabetical
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY country
                ORDER BY rental_count DESC, revenue DESC, film
            ) AS rn
        FROM film_rentals_by_country
    )
    SELECT
        country::TEXT,
        film::TEXT,
        rating::TEXT,
        language::TEXT,
        length,
        release_year
    FROM ranked
    WHERE rn = 1
    ORDER BY country;

END;
$$;


-- Test 1 — valid countries with data:
SELECT * FROM core.most_popular_films_by_countries(ARRAY['Afghanistan', 'Brazil', 'United States']);
-- Expected: one row per country showing the most rented film

-- Test 2 — edge case: country not in the database:
SELECT * FROM core.most_popular_films_by_countries(ARRAY['Narnia', 'Wakanda']);
-- Expected: 0 rows — no data, no error

-- Test 3 — NULL input:
SELECT * FROM core.most_popular_films_by_countries(NULL);
-- Expected: EXCEPTION 'Input array cannot be NULL or empty.'


-- ============================================================
-- TASK 4: Procedure language function — core.films_in_stock_by_title
-- ============================================================

/*
  I create this function to find films matching a partial title pattern
  and show their last rental info per film.

  How pattern matching works (LIKE, %):
    I accept the pattern exactly as the caller provides it (e.g., '%love%')
    and apply it using ILIKE. The caller controls the wildcards.
    ILIKE makes it case-insensitive, so 'Love', 'LOVE', 'love' all match.

  Performance note:
    ILIKE with a leading % (e.g., '%love%') cannot use a standard B-tree index —
    it causes a full scan of the film table.
    For dvdrental (~1000 rows) this is fine and fast.
    On large datasets I would create a GIN index using pg_trgm extension
    to make trigram-based LIKE searches efficient.

  Case sensitivity:
    I use ILIKE instead of LIKE — this way the search works regardless
    of how the user capitalizes the title pattern.

  What happens if multiple matches:
    All matching films in inventory are returned, each with a unique row_num
    starting from 1.

  What happens if no matches:
    I return a single informational row instead of raising an exception.
    The film_title column carries the message 'No films found matching: <pattern>'.
    This lets the caller see feedback without catching an exception.
*/

CREATE OR REPLACE FUNCTION core.films_in_stock_by_title(title_pattern TEXT)
RETURNS TABLE(
    row_num       BIGINT,
    film_title    TEXT,
    language      TEXT,
    customer_name TEXT,
    rental_date   TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- I validate the input — empty or null pattern is not useful
    IF title_pattern IS NULL OR title_pattern = '' THEN
        RAISE EXCEPTION 'Title pattern cannot be NULL or empty.';
    END IF;

    -- I check if any matching films exist in inventory before building the full result
    SELECT COUNT(DISTINCT f.film_id) INTO v_count
    FROM film f
    JOIN inventory i ON f.film_id = i.film_id
    WHERE f.title ILIKE title_pattern;

    -- If nothing found, I return a single informational row instead of an error
    IF v_count = 0 THEN
        RETURN QUERY
        SELECT
            NULL::BIGINT,
            ('No films found matching: ' || title_pattern)::TEXT,
            NULL::TEXT,
            NULL::TEXT,
            NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    RETURN QUERY
    WITH last_rental_per_film AS (
        -- I find the most recent rental info for each film (one row per film_id)
        SELECT DISTINCT ON (i.film_id)
            i.film_id,
            cu.first_name || ' ' || cu.last_name AS customer_name,
            r.rental_date
        FROM rental r
        JOIN inventory i ON r.inventory_id = i.inventory_id
        JOIN customer cu ON r.customer_id  = cu.customer_id
        ORDER BY i.film_id, r.rental_date DESC
    ),
    matching_films AS (
        -- I deduplicate at the film level using DISTINCT — one row per film in inventory
        SELECT DISTINCT
            f.film_id,
            f.title,
            l.name AS lang
        FROM film f
        JOIN inventory i ON f.film_id     = i.film_id
        JOIN language l  ON f.language_id = l.language_id
        WHERE f.title ILIKE title_pattern
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY mf.title)::BIGINT           AS row_num,
        mf.title::TEXT                                           AS film_title,
        mf.lang::TEXT                                            AS language,
        COALESCE(lr.customer_name, 'Never rented')::TEXT         AS customer_name,
        lr.rental_date::TIMESTAMPTZ                              AS rental_date
    FROM matching_films mf
    LEFT JOIN last_rental_per_film lr ON mf.film_id = lr.film_id
    ORDER BY mf.title;

END;
$$;


-- Test 1 — valid input with matches:
SELECT * FROM core.films_in_stock_by_title('%love%');
-- Expected: films with 'love' in title, row_num starting from 1, last customer + date

-- Test 2 — edge case: pattern that matches nothing in inventory:
SELECT * FROM core.films_in_stock_by_title('%xyzxyzxyz%');
-- Expected: one row with message 'No films found matching: %xyzxyzxyz%'

-- Test 3 — NULL input:
SELECT * FROM core.films_in_stock_by_title(NULL);
-- Expected: EXCEPTION 'Title pattern cannot be NULL or empty.'

-- Test 4 — case insensitivity check:
SELECT * FROM core.films_in_stock_by_title('%LOVE%');
-- Expected: same result as '%love%' because I use ILIKE


-- ============================================================
-- TASK 5: Procedure language function — new_movie
-- ============================================================

/*
  I create this function to insert a brand new film into the film table
  with sensible defaults and proper validation.

  How I generate unique film_id:
    I use SELECT MAX(film_id) + 1 FROM film to find the next available ID.
    COALESCE handles the edge case where the table is empty (starts from 1 then).
    I avoid relying on a sequence here since the task doesn't ask me to alter
    the schema — this approach works with the existing table structure.

  How I ensure no duplicates:
    Before anything else, I check IF EXISTS (SELECT 1 FROM film WHERE title = p_title).
    If the title already exists, I raise an exception immediately.
    The INSERT never runs — data stays consistent.

  What happens if movie already exists:
    RAISE EXCEPTION fires with a clear message including the duplicate title.
    The whole function rolls back, nothing is inserted.

  How I validate language existence:
    I query the language table by name and try to get the language_id.
    If it comes back NULL, the language doesn't exist and I raise an exception.
    This prevents inserting a film with an invalid language reference.

  What happens if insertion fails for any other reason:
    PostgreSQL automatically rolls back on unhandled exceptions.
    Consistency is always preserved — no partial inserts possible.

  Default values:
    release_year = current year (EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER)
    language = 'Klingon' — but this must exist in the language table first.

  Important note on Klingon:
    'Klingon' is not in the default dvdrental language table.
    I insert it below as a one-time setup step so the default language works.
    If the script is run again, INSERT ... WHERE NOT EXISTS prevents duplicates.
*/

-- Setup: I insert Klingon into language table if it doesn't already exist
INSERT INTO language (name, last_update)
SELECT 'Klingon', NOW()
WHERE NOT EXISTS (
    SELECT 1 FROM language WHERE name = 'Klingon'
);

CREATE OR REPLACE FUNCTION new_movie(
    p_title        TEXT,
    p_release_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
    p_language     TEXT    DEFAULT 'Klingon'
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_language_id INTEGER;
    v_new_film_id INTEGER;
BEGIN
    -- I check for duplicate title first — cleaner to fail fast before any other work
    IF EXISTS (SELECT 1 FROM film WHERE title = p_title) THEN
        RAISE EXCEPTION 'Film with title "%" already exists in the film table.', p_title;
    END IF;

    -- I look up the language_id for the given language name
    SELECT language_id INTO v_language_id
    FROM language
    WHERE name = p_language;

    -- If language_id is still NULL, the language doesn't exist — I stop here
    IF v_language_id IS NULL THEN
        RAISE EXCEPTION
            'Language "%" does not exist in the language table. Please add it first.',
            p_language;
    END IF;

    -- I generate the next unique film_id safely
    SELECT COALESCE(MAX(film_id), 0) + 1 INTO v_new_film_id FROM film;

    -- I insert the new film with all required fields and specified defaults
    INSERT INTO film (
        film_id,
        title,
        rental_rate,
        rental_duration,
        release_year,
        language_id,
        replacement_cost,
        last_update
    )
    VALUES (
        v_new_film_id,
        p_title,
        4.99,           -- rental_rate as specified in the task
        3,              -- rental_duration = 3 days as specified
        p_release_year,
        v_language_id,
        19.99,          -- replacement_cost as specified
        NOW()
    );

    RAISE NOTICE 'Film "%" successfully inserted with film_id = %.', p_title, v_new_film_id;
END;
$$;


-- Test 1 — valid input (new film with all defaults):
SELECT new_movie('The Klingon Chronicles');
-- Expected: NOTICE: Film "The Klingon Chronicles" successfully inserted with film_id = ...
SELECT film_id, title, rental_rate, rental_duration, release_year, language_id
FROM film WHERE title = 'The Klingon Chronicles';

-- Test 2 — edge/invalid: duplicate title:
SELECT new_movie('The Klingon Chronicles');
-- Expected: EXCEPTION: Film with title "The Klingon Chronicles" already exists

-- Test 3 — edge/invalid: language that doesn't exist:
SELECT new_movie('Test Film Elvish', 2026, 'Elvish');
-- Expected: EXCEPTION: Language "Elvish" does not exist in the language table

-- Test 4 — valid: custom year and explicit language:
SELECT new_movie('Adventures in Space', 2025, 'English');
-- Expected: NOTICE: Film "Adventures in Space" successfully inserted