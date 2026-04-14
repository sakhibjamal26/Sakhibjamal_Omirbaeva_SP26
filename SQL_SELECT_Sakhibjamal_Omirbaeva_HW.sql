-- SQL SELECT Homework
-- Database: dvdrental


-- ============================================================
-- PART 1, TASK 1
-- Get a list of Animation movies released between 2017 and 2019
-- with rental rate more than 1, sorted alphabetically
-- ============================================================

-- I assumed "Animation" means the category name in the category table.
-- "Rate more than 1" = rental_rate > 1 (strictly greater, not >= 1).
-- I used BETWEEN for the year range so both 2017 and 2019 are included.
-- Worth noting: most films in dvdrental have release_year = 2006,
-- so this query may return 0 rows on the actual data, but the logic is correct.

-- Solution 1: JOIN
-- I joined film -> film_category -> category to filter by category name.
-- Using INNER JOIN here because we only want films that actually have a category.
SELECT f.title,
       f.release_year,
       f.rental_rate,
       c.name AS category
FROM public.film f
INNER JOIN public.film_category fc ON f.film_id = fc.film_id
INNER JOIN public.category c ON fc.category_id = c.category_id
WHERE c.name = 'Animation'
  AND f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
ORDER BY f.title ASC;

-- JOIN is probably the most natural way to write this.
-- It's easy to read and runs fast when there are indexes on the join columns.
-- The only downside is you need to know the table structure well to write the joins correctly.

-- Solution 2: Subquery
-- Here I first find all film_ids that belong to Animation category,
-- then filter the film table using IN.
SELECT f.title,
       f.release_year,
       f.rental_rate
FROM public.film f
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
  AND f.film_id IN (
      SELECT fc.film_id
      FROM public.film_category fc
      INNER JOIN public.category c ON fc.category_id = c.category_id
      WHERE c.name = 'Animation'
  )
ORDER BY f.title ASC;

-- I like this approach because the main query stays clean and readable.
-- The downside is that IN with a subquery can be slower than JOIN on big tables,
-- because the database runs the subquery first and then checks each row.

-- Solution 3: CTE
-- I moved the category filter into a CTE so the main query is cleaner.
WITH animation_films AS (
    -- get all film_ids that are categorized as Animation
    SELECT fc.film_id
    FROM public.film_category fc
    INNER JOIN public.category c ON fc.category_id = c.category_id
    WHERE c.name = 'Animation'
)
SELECT f.title,
       f.release_year,
       f.rental_rate
FROM public.film f
INNER JOIN animation_films af ON f.film_id = af.film_id
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
ORDER BY f.title ASC;

-- CTE makes it easy to test each step separately which is helpful when debugging.
-- If I needed to reuse animation_films somewhere else in the query I could do that too.
-- Small downside: more lines of code for something that could be a simple JOIN.
-- I'd go with CTE in production because it's the easiest to understand when reading later.


-- ============================================================
-- PART 1, TASK 2
-- Calculate how much revenue each store made after March 2017
-- (so from April 2017 onwards).
-- Output: full address (address + address2 combined), revenue
-- ============================================================

-- I interpreted "after March 2017" as payment_date >= '2017-04-01'.
-- address2 can be NULL in the data, so I used COALESCE to handle that.
-- To get store revenue I had to go through payment -> rental -> inventory -> store.
-- That's the only way to know which store a payment belongs to.

-- Solution 1: JOIN
SELECT CONCAT(a.address, ', ', COALESCE(a.address2, '')) AS full_address,
       SUM(p.amount) AS revenue
FROM public.payment p
INNER JOIN public.rental r ON p.rental_id = r.rental_id
INNER JOIN public.inventory i ON r.inventory_id = i.inventory_id
-- I need inventory to find out which store the rental happened in
INNER JOIN public.store s ON i.store_id = s.store_id
INNER JOIN public.address a ON s.address_id = a.address_id
WHERE p.payment_date >= '2017-04-01'
GROUP BY s.store_id, a.address, a.address2
ORDER BY revenue DESC;

-- The chain of joins is a bit long but it's the correct path through the schema.
-- INNER JOIN everywhere because we only care about payments linked to real rentals and stores.
-- Works well, just takes some time to trace through all the joins.

-- Solution 2: Subquery
-- I calculated the revenue per store first in a subquery,
-- then joined with store and address to get the full address.
SELECT CONCAT(a.address, ', ', COALESCE(a.address2, '')) AS full_address,
       store_revenue.revenue
FROM (
    SELECT i.store_id,
           SUM(p.amount) AS revenue
    FROM public.payment p
    INNER JOIN public.rental r ON p.rental_id = r.rental_id
    INNER JOIN public.inventory i ON r.inventory_id = i.inventory_id
    WHERE p.payment_date >= '2017-04-01'
    GROUP BY i.store_id
) AS store_revenue
INNER JOIN public.store s ON store_revenue.store_id = s.store_id
INNER JOIN public.address a ON s.address_id = a.address_id
ORDER BY store_revenue.revenue DESC;

-- I like that the revenue calculation is separate from the address lookup here.
-- Makes it easier to change just one part without touching the other.
-- But nested subqueries can get confusing when there are multiple levels.

-- Solution 3: CTE
WITH store_revenue AS (
    -- first calculate total revenue per store after March 2017
    SELECT i.store_id,
           SUM(p.amount) AS revenue
    FROM public.payment p
    INNER JOIN public.rental r ON p.rental_id = r.rental_id
    INNER JOIN public.inventory i ON r.inventory_id = i.inventory_id
    WHERE p.payment_date >= '2017-04-01'
    GROUP BY i.store_id
)
SELECT CONCAT(a.address, ', ', COALESCE(a.address2, '')) AS full_address,
       sr.revenue
FROM store_revenue sr
INNER JOIN public.store s ON sr.store_id = s.store_id
INNER JOIN public.address a ON s.address_id = a.address_id
ORDER BY sr.revenue DESC;

-- This feels the cleanest to me. The CTE handles the revenue part,
-- and the main query just formats the output.
-- Easy to read and easy to modify if requirements change.
-- I would use this one in production.


-- ============================================================
-- PART 1, TASK 3
-- Find top 5 actors by number of movies they appeared in since 2015.
-- Columns: first_name, last_name, number_of_movies
-- Sorted by number_of_movies descending
-- ============================================================

-- "Since 2015" means release_year >= 2015 (including 2015).
-- I count all films per actor, not distinct titles, but since
-- each actor appears once per film in film_actor, it's the same thing.

-- Solution 1: JOIN
SELECT a.first_name,
       a.last_name,
       COUNT(fa.film_id) AS number_of_movies
FROM public.actor a
INNER JOIN public.film_actor fa ON a.actor_id = fa.actor_id
INNER JOIN public.film f ON fa.film_id = f.film_id
WHERE f.release_year >= 2015
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY number_of_movies DESC
LIMIT 5;

-- Simple and straightforward. INNER JOIN makes sense here because
-- we only want actors who actually have films.
-- This is probably the fastest version too.

-- Solution 2: Subquery (correlated)
-- For each actor, I run a subquery to count their films since 2015.
SELECT a.first_name,
       a.last_name,
       (
           SELECT COUNT(fa.film_id)
           FROM public.film_actor fa
           INNER JOIN public.film f ON fa.film_id = f.film_id
           WHERE fa.actor_id = a.actor_id
             AND f.release_year >= 2015
       ) AS number_of_movies
FROM public.actor a
WHERE (
    SELECT COUNT(fa.film_id)
    FROM public.film_actor fa
    INNER JOIN public.film f ON fa.film_id = f.film_id
    WHERE fa.actor_id = a.actor_id
      AND f.release_year >= 2015
) > 0
ORDER BY number_of_movies DESC
LIMIT 5;

-- This works but I had to write the same subquery twice which is not ideal.
-- Also correlated subqueries like this run once per row so they're slow on big tables.
-- Wouldn't use this in production but good to know the pattern.

-- Solution 3: CTE
WITH actor_movie_counts AS (
    -- count how many films each actor appeared in since 2015
    SELECT a.actor_id,
           a.first_name,
           a.last_name,
           COUNT(fa.film_id) AS number_of_movies
    FROM public.actor a
    INNER JOIN public.film_actor fa ON a.actor_id = fa.actor_id
    INNER JOIN public.film f ON fa.film_id = f.film_id
    WHERE f.release_year >= 2015
    GROUP BY a.actor_id, a.first_name, a.last_name
)
SELECT first_name,
       last_name,
       number_of_movies
FROM actor_movie_counts
ORDER BY number_of_movies DESC
LIMIT 5;

-- CTE version is very clean. I can easily check what's inside the CTE before
-- looking at the final SELECT. Nice for debugging.
-- Performance is similar to JOIN. I'd pick this one for readability.


-- ============================================================
-- PART 1, TASK 4
-- Count Drama, Travel, Documentary films per release year.
-- Columns: release_year, number_of_drama_movies,
--          number_of_travel_movies, number_of_documentary_movies
-- Sorted by release_year descending. Handle NULLs.
-- ============================================================

-- A film can belong to multiple categories, so it could be counted
-- in more than one column — I think that's the correct behavior here.
-- I used COALESCE to make sure we get 0 instead of NULL when no films exist for a genre.
-- LEFT JOIN is important here so we don't lose years that have no matching genre films.

-- Solution 1: JOIN with conditional aggregation
SELECT f.release_year,
       COUNT(CASE WHEN c.name = 'Drama' THEN f.film_id END) AS number_of_drama_movies,
       COUNT(CASE WHEN c.name = 'Travel' THEN f.film_id END) AS number_of_travel_movies,
       COUNT(CASE WHEN c.name = 'Documentary' THEN f.film_id END) AS number_of_documentary_movies
FROM public.film f
LEFT JOIN public.film_category fc ON f.film_id = fc.film_id
-- LEFT JOIN so we keep all films even if they have no category
LEFT JOIN public.category c ON fc.category_id = c.category_id
  AND c.name IN ('Drama', 'Travel', 'Documentary')
GROUP BY f.release_year
ORDER BY f.release_year DESC;

-- CASE WHEN inside COUNT is a common trick to pivot rows into columns.
-- LEFT JOIN makes sure we don't accidentally drop films with no category.
-- All in one query which is efficient — only one pass through the data.

-- Solution 2: Subquery
-- Using correlated subqueries to count each genre separately per film.
SELECT f.release_year,
       (SELECT COUNT(*) FROM public.film_category fc
        INNER JOIN public.category c ON fc.category_id = c.category_id
        WHERE fc.film_id = f.film_id AND c.name = 'Drama') AS number_of_drama_movies,
       (SELECT COUNT(*) FROM public.film_category fc
        INNER JOIN public.category c ON fc.category_id = c.category_id
        WHERE fc.film_id = f.film_id AND c.name = 'Travel') AS number_of_travel_movies,
       (SELECT COUNT(*) FROM public.film_category fc
        INNER JOIN public.category c ON fc.category_id = c.category_id
        WHERE fc.film_id = f.film_id AND c.name = 'Documentary') AS number_of_documentary_movies
FROM public.film f
GROUP BY f.release_year, f.film_id
ORDER BY f.release_year DESC;

-- This is very explicit — easy to see exactly what each column counts.
-- But it runs 3 subqueries per row which is really slow. Probably the worst
-- performance of the three solutions. I'd avoid this one in practice.

-- Solution 3: CTE
WITH genre_counts AS (
    -- get film_id, release_year, and genre for the 3 genres we care about
    SELECT f.film_id,
           f.release_year,
           c.name AS genre
    FROM public.film f
    LEFT JOIN public.film_category fc ON f.film_id = fc.film_id
    LEFT JOIN public.category c ON fc.category_id = c.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary') OR c.name IS NULL
)
SELECT release_year,
       COALESCE(COUNT(CASE WHEN genre = 'Drama' THEN film_id END), 0) AS number_of_drama_movies,
       COALESCE(COUNT(CASE WHEN genre = 'Travel' THEN film_id END), 0) AS number_of_travel_movies,
       COALESCE(COUNT(CASE WHEN genre = 'Documentary' THEN film_id END), 0) AS number_of_documentary_movies
FROM genre_counts
GROUP BY release_year
ORDER BY release_year DESC;

-- I like that the CTE pre-filters only the genres we need,
-- then the main query just does the grouping and pivoting.
-- COALESCE makes sure we return 0 instead of NULL for years with no films in a genre.
-- This is the version I'd use in production.


-- ============================================================
-- PART 2, TASK 1
-- Find the 3 employees who brought in the most revenue in 2017.
-- Also show which store they worked in (their last store).
--
-- Assumptions I made:
-- - a staff member might work at different stores, so I take
--   the store from their most recent payment in 2017
-- - if a staff member processed a payment, they were working
--   at the store that rental belongs to
-- - I only look at payment_date to determine the year (2017)
-- ============================================================

-- Solution 1: JOIN
SELECT s.first_name,
       s.last_name,
       SUM(p.amount) AS total_revenue,
       last_store.store_id AS last_store_id
FROM public.staff s
INNER JOIN public.payment p ON s.staff_id = p.staff_id
INNER JOIN (
    -- find the store each staff member was working at during their last payment in 2017
    SELECT p2.staff_id,
           i2.store_id
    FROM public.payment p2
    INNER JOIN public.rental r2 ON p2.rental_id = r2.rental_id
    INNER JOIN public.inventory i2 ON r2.inventory_id = i2.inventory_id
    WHERE p2.payment_date = (
        SELECT MAX(p3.payment_date)
        FROM public.payment p3
        WHERE p3.staff_id = p2.staff_id
          AND EXTRACT(YEAR FROM p3.payment_date) = 2017
    )
      AND EXTRACT(YEAR FROM p2.payment_date) = 2017
) AS last_store ON s.staff_id = last_store.staff_id
WHERE EXTRACT(YEAR FROM p.payment_date) = 2017
GROUP BY s.staff_id, s.first_name, s.last_name, last_store.store_id
ORDER BY total_revenue DESC
LIMIT 3;

-- This works but it's pretty complex because of the nested subquery inside the JOIN.
-- The inner subquery finds the store of the last payment per staff member.
-- Hard to read at a glance, but all the logic is in one query.

-- Solution 2: Subquery
SELECT first_name,
       last_name,
       total_revenue,
       last_store_id
FROM (
    SELECT s.staff_id,
           s.first_name,
           s.last_name,
           SUM(p.amount) AS total_revenue,
           (
               -- get the store of the most recent payment this staff processed in 2017
               SELECT i.store_id
               FROM public.payment p2
               INNER JOIN public.rental r ON p2.rental_id = r.rental_id
               INNER JOIN public.inventory i ON r.inventory_id = i.inventory_id
               WHERE p2.staff_id = s.staff_id
                 AND EXTRACT(YEAR FROM p2.payment_date) = 2017
               ORDER BY p2.payment_date DESC
               LIMIT 1
           ) AS last_store_id
    FROM public.staff s
    INNER JOIN public.payment p ON s.staff_id = p.staff_id
    WHERE EXTRACT(YEAR FROM p.payment_date) = 2017
    GROUP BY s.staff_id, s.first_name, s.last_name
) AS staff_revenue
ORDER BY total_revenue DESC
LIMIT 3;

-- I used ORDER BY + LIMIT 1 in the correlated subquery to get the last store.
-- A bit cleaner than the JOIN version for the "last store" part.
-- Still has performance concerns with correlated subqueries running per staff member.

-- Solution 3: CTE
WITH staff_revenue_2017 AS (
    -- total revenue each staff member generated in 2017
    SELECT p.staff_id,
           SUM(p.amount) AS total_revenue
    FROM public.payment p
    WHERE EXTRACT(YEAR FROM p.payment_date) = 2017
    GROUP BY p.staff_id
),
last_payment_per_staff AS (
    -- find the timestamp of the last payment each staff processed in 2017
    SELECT p.staff_id,
           MAX(p.payment_date) AS last_payment_date
    FROM public.payment p
    WHERE EXTRACT(YEAR FROM p.payment_date) = 2017
    GROUP BY p.staff_id
),
last_store_per_staff AS (
    -- use the last payment to figure out which store the staff was working at
    SELECT p.staff_id,
           i.store_id
    FROM public.payment p
    INNER JOIN last_payment_per_staff lp
        ON p.staff_id = lp.staff_id
        AND p.payment_date = lp.last_payment_date
    INNER JOIN public.rental r ON p.rental_id = r.rental_id
    INNER JOIN public.inventory i ON r.inventory_id = i.inventory_id
)
SELECT s.first_name,
       s.last_name,
       sr.total_revenue,
       ls.store_id AS last_store_id
FROM public.staff s
INNER JOIN staff_revenue_2017 sr ON s.staff_id = sr.staff_id
INNER JOIN last_store_per_staff ls ON s.staff_id = ls.staff_id
ORDER BY sr.total_revenue DESC
LIMIT 3;

-- I really like the CTE version here because the logic has 3 clear steps:
-- 1. calculate revenue, 2. find last payment, 3. find last store.
-- Each step is easy to test on its own which helped me debug this.
-- This is definitely the one I'd use in production.


-- ============================================================
-- PART 2, TASK 2
-- Find the 5 most rented movies and show the expected audience age
-- based on the MPA rating system:
--   G       -> suitable for all ages
--   PG      -> 8+
--   PG-13   -> 13+
--   R       -> 17+
--   NC-17   -> 18+
-- ============================================================

-- "Most rented" = highest count of rental records linked to that film.
-- I joined through inventory to get from film to rental.

-- Solution 1: JOIN
SELECT f.title,
       COUNT(r.rental_id) AS number_of_rentals,
       f.rating,
       CASE f.rating
           WHEN 'G'     THEN 'All ages'
           WHEN 'PG'    THEN '8+'
           WHEN 'PG-13' THEN '13+'
           WHEN 'R'     THEN '17+'
           WHEN 'NC-17' THEN '18+'
           ELSE 'Unknown'
       END AS expected_age
FROM public.film f
INNER JOIN public.inventory i ON f.film_id = i.film_id
-- a film can have multiple inventory copies, each can be rented separately
INNER JOIN public.rental r ON i.inventory_id = r.inventory_id
GROUP BY f.film_id, f.title, f.rating
ORDER BY number_of_rentals DESC
LIMIT 5;

-- Clean and simple. The CASE statement maps ratings to age groups.
-- INNER JOIN is correct here since we only want films that have been rented.

-- Solution 2: Subquery
-- I calculated rental counts in a subquery to keep the age logic separate.
SELECT f.title,
       f.rating,
       rental_counts.number_of_rentals,
       CASE f.rating
           WHEN 'G'     THEN 'All ages'
           WHEN 'PG'    THEN '8+'
           WHEN 'PG-13' THEN '13+'
           WHEN 'R'     THEN '17+'
           WHEN 'NC-17' THEN '18+'
           ELSE 'Unknown'
       END AS expected_age
FROM public.film f
INNER JOIN (
    SELECT i.film_id,
           COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory i
    INNER JOIN public.rental r ON i.inventory_id = r.inventory_id
    GROUP BY i.film_id
) AS rental_counts ON f.film_id = rental_counts.film_id
ORDER BY rental_counts.number_of_rentals DESC
LIMIT 5;

-- Decent approach, separates the counting from the display logic.
-- The subquery is simple enough that it doesn't hurt readability too much here.

-- Solution 3: CTE
WITH rental_counts AS (
    -- count how many times each film was rented
    SELECT i.film_id,
           COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory i
    INNER JOIN public.rental r ON i.inventory_id = r.inventory_id
    GROUP BY i.film_id
),
film_with_age AS (
    -- map each film's rating to the expected audience age
    SELECT f.film_id,
           f.title,
           f.rating,
           CASE f.rating
               WHEN 'G'     THEN 'All ages'
               WHEN 'PG'    THEN '8+'
               WHEN 'PG-13' THEN '13+'
               WHEN 'R'     THEN '17+'
               WHEN 'NC-17' THEN '18+'
               ELSE 'Unknown'
           END AS expected_age
    FROM public.film f
)
SELECT fa.title,
       fa.rating,
       fa.expected_age,
       rc.number_of_rentals
FROM film_with_age fa
INNER JOIN rental_counts rc ON fa.film_id = rc.film_id
ORDER BY rc.number_of_rentals DESC
LIMIT 5;

-- Two CTEs keep things very organized — one for counts, one for age mapping.
-- A bit more code but each part is easy to understand and modify independently.
-- This is what I'd use in production.


-- ============================================================
-- PART 3
-- Which actors had the longest period without appearing in a film?
--
-- V1: gap between the actor's last film and current year (2017)
-- V2: longest gap between two consecutive films per actor
-- ============================================================

-- I used 2017 as the "current year" since that's the latest year in the dataset.
-- Window functions are not allowed so I used self-joins for V2.

-- ============================================================
-- V1: How long since each actor last appeared in a film?
-- ============================================================

-- Solution 1: JOIN
SELECT a.first_name,
       a.last_name,
       MAX(f.release_year) AS last_film_year,
       (2017 - MAX(f.release_year)) AS years_inactive
FROM public.actor a
INNER JOIN public.film_actor fa ON a.actor_id = fa.actor_id
INNER JOIN public.film f ON fa.film_id = f.film_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY years_inactive DESC;

-- Simple, works well. Just find the max release year per actor and subtract from 2017.

-- Solution 2: Subquery
SELECT a.first_name,
       a.last_name,
       last_film.last_year,
       (2017 - last_film.last_year) AS years_inactive
FROM public.actor a
INNER JOIN (
    SELECT fa.actor_id,
           MAX(f.release_year) AS last_year
    FROM public.film_actor fa
    INNER JOIN public.film f ON fa.film_id = f.film_id
    GROUP BY fa.actor_id
) AS last_film ON a.actor_id = last_film.actor_id
ORDER BY years_inactive DESC;

-- Separated the "last year" calculation into a subquery.
-- Same result as the JOIN, just a different way to structure it.

-- Solution 3: CTE
WITH last_film_per_actor AS (
    -- find the most recent year each actor appeared in a film
    SELECT fa.actor_id,
           MAX(f.release_year) AS last_film_year
    FROM public.film_actor fa
    INNER JOIN public.film f ON fa.film_id = f.film_id
    GROUP BY fa.actor_id
)
SELECT a.first_name,
       a.last_name,
       lf.last_film_year,
       (2017 - lf.last_film_year) AS years_inactive
FROM public.actor a
INNER JOIN last_film_per_actor lf ON a.actor_id = lf.actor_id
ORDER BY years_inactive DESC;

-- CTE version is the clearest. Easy to explain what each part does.
-- I would go with this one in production.

-- ============================================================
-- V2: Longest gap between two consecutive films per actor
-- ============================================================

-- This is trickier without window functions.
-- I used a self-join on film years and NOT EXISTS to find "consecutive" years —
-- meaning there's no other film for that actor in between.
-- LAG() would have been perfect here but window functions are not allowed.

-- Solution 1: Self-JOIN
SELECT a.first_name,
       a.last_name,
       MAX(f2.release_year - f1.release_year) AS max_gap_years
FROM public.actor a
INNER JOIN public.film_actor fa1 ON a.actor_id = fa1.actor_id
INNER JOIN public.film f1 ON fa1.film_id = f1.film_id
INNER JOIN public.film_actor fa2 ON a.actor_id = fa2.actor_id
INNER JOIN public.film f2 ON fa2.film_id = f2.film_id
WHERE f2.release_year > f1.release_year
  AND NOT EXISTS (
      -- make sure there's no film for this actor between f1 and f2
      SELECT 1
      FROM public.film_actor fa3
      INNER JOIN public.film f3 ON fa3.film_id = f3.film_id
      WHERE fa3.actor_id = a.actor_id
        AND f3.release_year > f1.release_year
        AND f3.release_year < f2.release_year
  )
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY max_gap_years DESC;

-- The NOT EXISTS part is what makes these "consecutive" — we check there's nothing in between.
-- It works correctly but can be slow because NOT EXISTS runs for every pair of rows.

-- Solution 2: Subquery
SELECT a.first_name,
       a.last_name,
       MAX(gap) AS max_gap_years
FROM (
    SELECT fa1.actor_id,
           (f2.release_year - f1.release_year) AS gap
    FROM public.film_actor fa1
    INNER JOIN public.film f1 ON fa1.film_id = f1.film_id
    INNER JOIN public.film_actor fa2 ON fa1.actor_id = fa2.actor_id
    INNER JOIN public.film f2 ON fa2.film_id = f2.film_id
    WHERE f2.release_year > f1.release_year
      AND NOT EXISTS (
          SELECT 1
          FROM public.film_actor fa3
          INNER JOIN public.film f3 ON fa3.film_id = f3.film_id
          WHERE fa3.actor_id = fa1.actor_id
            AND f3.release_year > f1.release_year
            AND f3.release_year < f2.release_year
      )
) AS actor_gaps
INNER JOIN public.actor a ON actor_gaps.actor_id = a.actor_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY max_gap_years DESC;

-- Same logic as Solution 1 but the gap calculation is moved into a subquery.
-- Then we join to actor table just to get the names.
-- A bit more structured but still not very readable with all the nesting.

-- Solution 3: CTE
WITH actor_film_years AS (
    -- get distinct years each actor appeared in a film (no duplicates)
    SELECT DISTINCT fa.actor_id,
                    f.release_year
    FROM public.film_actor fa
    INNER JOIN public.film f ON fa.film_id = f.film_id
),
consecutive_gaps AS (
    -- pair up each year with the next year for the same actor
    -- NOT EXISTS ensures we only pick truly consecutive years
    SELECT ay1.actor_id,
           (ay2.release_year - ay1.release_year) AS gap
    FROM actor_film_years ay1
    INNER JOIN actor_film_years ay2
        ON ay1.actor_id = ay2.actor_id
        AND ay2.release_year > ay1.release_year
    WHERE NOT EXISTS (
        SELECT 1
        FROM actor_film_years ay3
        WHERE ay3.actor_id = ay1.actor_id
          AND ay3.release_year > ay1.release_year
          AND ay3.release_year < ay2.release_year
    )
)
SELECT a.first_name,
       a.last_name,
       MAX(cg.gap) AS max_gap_years
FROM consecutive_gaps cg
INNER JOIN public.actor a ON cg.actor_id = a.actor_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY max_gap_years DESC;

-- CTE breaks this into clear steps: first collect years, then find gaps, then output.
-- Much easier to follow than the single-query versions.
-- If window functions were allowed I'd use LAG() instead — it would be simpler and faster.
-- But since they're not, this CTE version is my production choice.
