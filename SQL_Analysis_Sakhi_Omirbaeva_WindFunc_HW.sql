/* =====================================================================
   SQL Analysis — Window Functions Homework
   Database: Sales History (sh schema), PostgreSQL
  
   ===================================================================== */


/* 
   TASK 1
   Top 5 customers per channel by total sales, plus a sales_percentage
   KPI that shows each customer's share of total channel sales.

   My approach:
   - First I aggregate sales per (channel, customer) in a CTE so the
     window functions later operate on already-summarized rows
     (this keeps the logic clean and avoids re-summing).
   - Then I compute two things in a single window-function pass:
        channel_total via SUM() OVER (PARTITION BY channel_id) —
         I deliberately omit ORDER BY here so no implicit frame is
         applied: the window is the whole partition, which is exactly
         what I need for "total of the channel".
        a per-channel ranking via RANK() OVER (PARTITION BY channel_id
         ORDER BY amount_sold DESC). I picked RANK over ROW_NUMBER
         because the data has ties at the boundary (e.g. two customers
         with 1184.94 in Tele Sales) and I want all tied customers to
         count as "top 5".
   - Finally I join back to channels and customers for the descriptive
     names, format the numbers per the spec and order by channel and
     amount (descending) so each channel's block reads top-to-bottom.
   */

WITH customer_channel_sales AS (
    -- I pre-aggregate to one row per (channel, customer); the window
    -- functions in the next step then work on this clean grain.
    SELECT
        s.channel_id,
        s.cust_id,
        SUM(s.amount_sold) AS amount_sold
    FROM sh.sales s
    GROUP BY s.channel_id, s.cust_id
),
ranked AS (
    SELECT
        channel_id,
        cust_id,
        amount_sold,
        -- channel total: no ORDER BY in OVER() = no frame, whole partition
        SUM(amount_sold) OVER (PARTITION BY channel_id) AS channel_total,
        -- RANK keeps tied customers together (important here — there are
        -- exact-amount ties at the bottom of Tele Sales).
        RANK() OVER (
            PARTITION BY channel_id
            ORDER BY amount_sold DESC
        ) AS rnk
    FROM customer_channel_sales
)
SELECT
    ch.channel_desc,
    c.cust_last_name,
    c.cust_first_name,
    -- two decimal places for the amount
    TO_CHAR(r.amount_sold, 'FM9999990.00')                               AS amount_sold,
    -- four decimals + " %" suffix; FM strips padding spaces
    TO_CHAR(r.amount_sold / r.channel_total * 100, 'FM990.0000') || ' %' AS sales_percentage
FROM ranked r
JOIN sh.channels  ch ON ch.channel_id = r.channel_id
JOIN sh.customers c  ON c.cust_id     = r.cust_id
WHERE r.rnk <= 5
ORDER BY ch.channel_desc, r.amount_sold DESC;



/* 
   TASK 2
   Total sales per Photo product in the Asian region for year 2000,
   pivoted by quarter, plus a yearly total (YEAR_SUM).

   My approach:
   - The task hints at the crosstab function, so I enabled the tablefunc
     extension and used crosstab() to pivot quarter numbers (1..4) into
     four columns. crosstab is cleaner than a pile of CASE expressions
     when the number of pivot values is small and known.
   - The source query inside crosstab returns (product_name, quarter,
     quarterly_sum) - exactly the (row_name, category, value) shape
     crosstab expects.
   - I add YEAR_SUM as q1+q2+q3+q4 wrapped in COALESCE, because some
     products did not sell in every quarter (e.g. 64MB Memory Card has
     no Q3/Q4 sales) and adding NULL would null out the whole sum.
   - I order DESC by year_sum so best-selling products come first.
*/

CREATE EXTENSION IF NOT EXISTS tablefunc;

SELECT
    product_name,
    TO_CHAR(q1, 'FM999999990.00') AS q1,
    TO_CHAR(q2, 'FM999999990.00') AS q2,
    TO_CHAR(q3, 'FM999999990.00') AS q3,
    TO_CHAR(q4, 'FM999999990.00') AS q4,
    -- COALESCE so missing quarters don't NULL out the whole yearly total
    TO_CHAR(
        COALESCE(q1,0) + COALESCE(q2,0) + COALESCE(q3,0) + COALESCE(q4,0),
        'FM999999990.00'
    ) AS year_sum
FROM crosstab(
    -- source query: (row_name, category, value)
    $$
    SELECT
        p.prod_name,
        t.calendar_quarter_number::text AS q,
        SUM(s.amount_sold)
    FROM sh.sales      s
    JOIN sh.products   p  ON p.prod_id    = s.prod_id
    JOIN sh.times      t  ON t.time_id    = s.time_id
    JOIN sh.customers  cu ON cu.cust_id   = s.cust_id
    JOIN sh.countries  co ON co.country_id = cu.country_id
    WHERE p.prod_category = 'Photo'
      AND co.country_region = 'Asia'
      AND t.calendar_year   = 2000
    GROUP BY p.prod_name, t.calendar_quarter_number
    ORDER BY p.prod_name, t.calendar_quarter_number
    $$,
    -- categories the row will be pivoted into (ensures all 4 quarters
    -- are present as columns even if some are empty)
    $$ VALUES ('1'::text), ('2'::text), ('3'::text), ('4'::text) $$
) AS ct (
    product_name varchar(50),
    q1 numeric,
    q2 numeric,
    q3 numeric,
    q4 numeric
)
ORDER BY (COALESCE(q1,0) + COALESCE(q2,0) + COALESCE(q3,0) + COALESCE(q4,0)) DESC;


/* 
   TASK 3
   Top 300 customers in each of 1998, 1999, and 2001, broken down
   by sales channel (only that channel's purchases shown).

   My interpretation of the task (revised after mentor feedback on git):
   - "Top 300 in 1998, 1999 AND 2001" means a customer must rank in
     the top 300 separately for EACH of those three years, not in the
     top 300 of a single combined-three-year total. The "AND" is the
     key word — it's an intersection, not a sum.
   - "Categorize the customers based on their sales channels" and
     "Include in the report only purchases made on the channel
     specified" tell me the output is split by channel: a customer
     who bought on three channels appears in three rows, each row
     showing only that channel's amount.

   My approach:
   - First CTE: aggregate sales per (customer, year) for the three
     years of interest.
   - Second CTE: rank customers within each year using
     DENSE_RANK() OVER (PARTITION BY calendar_year ORDER BY total DESC).
     DENSE_RANK keeps ties at the boundary without leaving gaps.
   - Third CTE: keep only customers who appear at rank <= 300 in all
     three years. The HAVING COUNT(DISTINCT calendar_year) = 3 enforces
     the "in every year" requirement — this is the intersection step.
   - Final SELECT: for those qualifying customers, sum sales per
     channel (limited to the three years) so the output is broken
     down by channel as the spec requires.
   - I've provided a Option2 below that uses
     ROW_NUMBER() instead of DENSE_RANK() for a strict "exactly 300"
     cutoff, in case the assignment prefers that interpretation.

*/
WITH yearly_sales AS (
    -- one row per (customer, year)
    SELECT
        s.cust_id,
        t.calendar_year,
        SUM(s.amount_sold) AS yearly_total
    FROM sh.sales s
    JOIN sh.times t USING (time_id)
    WHERE t.calendar_year IN (1998, 1999, 2001)
    GROUP BY s.cust_id, t.calendar_year
),
ranked_per_year AS (
    SELECT
        cust_id,
        calendar_year,
        yearly_total,
        DENSE_RANK() OVER (
            PARTITION BY calendar_year
            ORDER BY yearly_total DESC
        ) AS rnk
    FROM yearly_sales
),
top_300_all_years AS (
    -- must be top 300 in every one of the three years
    SELECT cust_id
    FROM ranked_per_year
    WHERE rnk <= 300
    GROUP BY cust_id
    HAVING COUNT(DISTINCT calendar_year) = 3
)
SELECT
    ch.channel_desc,
    c.cust_id,
    c.cust_last_name,
    c.cust_first_name,
    TO_CHAR(SUM(s.amount_sold), 'FM999999990.00') AS amount_sold
FROM sh.sales      s
JOIN sh.times      t  USING (time_id)
JOIN sh.channels   ch USING (channel_id)
JOIN sh.customers  c  USING (cust_id)
WHERE s.cust_id IN (SELECT cust_id FROM top_300_all_years)
  AND t.calendar_year IN (1998, 1999, 2001)
GROUP BY ch.channel_desc, c.cust_id, c.cust_last_name, c.cust_first_name
ORDER BY ch.channel_desc, SUM(s.amount_sold) DESC;
/* 
   TASK 3 Option2: strict "exactly 300" version

   I kept the DENSE_RANK version above as the primary solution because
   "top 300" in business reports typically includes ties (cutting a
   customer off arbitrarily when they tie with the 300th by sales
   feels wrong). This second variant exists in case the assignment
   expects exactly 300 customers per year, no more.

   What changes vs Option1:
   - I swap DENSE_RANK() for ROW_NUMBER(). ROW_NUMBER assigns a unique
     position to every row, so ties are broken arbitrarily and the
     top-300 cutoff produces exactly 300 customers per year.
   - To make the tie-breaking deterministic (same input to same output
     across runs), I add cust_id as a secondary ORDER BY. Without it,
     two customers with identical yearly_total could swap positions
     between executions.
   - Everything else - the per-year ranking logic, the
     COUNT(DISTINCT calendar_year) = 3 intersection, the final
     channel-level aggregation — stays identical to Option1.
*/

WITH yearly_sales AS (
    SELECT
        s.cust_id,
        t.calendar_year,
        SUM(s.amount_sold) AS yearly_total
    FROM sh.sales s
    JOIN sh.times t USING (time_id)
    WHERE t.calendar_year IN (1998, 1999, 2001)
    GROUP BY s.cust_id, t.calendar_year
),
ranked_per_year AS (
    SELECT
        cust_id,
        calendar_year,
        yearly_total,
        -- ROW_NUMBER for a strict 300-per-year cutoff; cust_id as a
        -- tie-breaker so the result is deterministic across runs.
        ROW_NUMBER() OVER (
            PARTITION BY calendar_year
            ORDER BY yearly_total DESC, cust_id
        ) AS rnk
    FROM yearly_sales
),
top_300_all_years AS (
    SELECT cust_id
    FROM ranked_per_year
    WHERE rnk <= 300
    GROUP BY cust_id
    HAVING COUNT(DISTINCT calendar_year) = 3
)
SELECT
    ch.channel_desc,
    c.cust_id,
    c.cust_last_name,
    c.cust_first_name,
    TO_CHAR(SUM(s.amount_sold), 'FM999999990.00') AS amount_sold
FROM sh.sales      s
JOIN sh.times      t  USING (time_id)
JOIN sh.channels   ch USING (channel_id)
JOIN sh.customers  c  USING (cust_id)
WHERE s.cust_id IN (SELECT cust_id FROM top_300_all_years)
  AND t.calendar_year IN (1998, 1999, 2001)
GROUP BY ch.channel_desc, c.cust_id, c.cust_last_name, c.cust_first_name
ORDER BY ch.channel_desc, SUM(s.amount_sold) DESC;


/* 
   TASK 4
   Sales for Jan/Feb/Mar 2000, pivoted by region (Americas vs Europe),
   broken down by month and product category.

   My approach:
   - This task is a straightforward pivot with only two target columns
     (Americas, Europe), so I used conditional aggregation with the
     FILTER clause instead of crosstab. FILTER is cleaner here, doesn't
     need an extension, and reads naturally as "sum amount_sold WHERE
     region = X".
   - Filtering at the JOIN level on calendar_month_desc and
     country_region keeps the result set small from the start.
   - Ordering: months ascending (chronological is also alphabetical
     for YYYY-MM), then prod_category alphabetically as required.
*/

SELECT
    t.calendar_month_desc,
    p.prod_category,
    -- FILTER clause: like a CASE WHEN inside the aggregate, but cleaner
    TO_CHAR(SUM(s.amount_sold) FILTER (WHERE co.country_region = 'Americas'), 'FM999,999,990') AS "Americas SALES",
    TO_CHAR(SUM(s.amount_sold) FILTER (WHERE co.country_region = 'Europe'),   'FM999,999,990') AS "Europe SALES"
FROM sh.sales      s
JOIN sh.products   p  ON p.prod_id    = s.prod_id
JOIN sh.times      t  ON t.time_id    = s.time_id
JOIN sh.customers  cu ON cu.cust_id   = s.cust_id
JOIN sh.countries  co ON co.country_id = cu.country_id
WHERE t.calendar_month_desc IN ('2000-01', '2000-02', '2000-03')
  AND co.country_region IN ('Americas', 'Europe')
GROUP BY t.calendar_month_desc, p.prod_category
ORDER BY t.calendar_month_desc, p.prod_category;

/* 
   TASK 4 Option2: window-function version

   I kept the FILTER-clause version above as the primary solution
   because it reads cleaner for a simple two-column pivot. This second
   variant exists to satisfy the "use a window function" requirement
   of the assignment.

   My approach:
   - I move the regional split inside a CASE expression (one CASE per
     target column) and wrap each in SUM() OVER (PARTITION BY month,
     category). Rows from "wrong" regions contribute 0, so the partition
     sum equals the regional total — same numbers as the FILTER version.
   - Because window functions don't collapse rows, the same
     (month, category) pair appears once per underlying sale. I use
     SELECT DISTINCT to deduplicate down to one row per pair.
     (An alternative would be GROUP BY, but then I couldn't use the
     window function directly — it would have to wrap an aggregate.
     DISTINCT is the lighter fix here.)
   - ELSE 0 instead of leaving NULL, so the SUM behaves predictably
     even if a (month, category) pair has zero sales in one region.
   - Same TO_CHAR formatting as Option1 for consistent output.
*/
SELECT DISTINCT
    t.calendar_month_desc,
    p.prod_category,
    TO_CHAR(
        SUM(CASE WHEN co.country_region = 'Americas' THEN s.amount_sold ELSE 0 END)
            OVER (PARTITION BY t.calendar_month_desc, p.prod_category),
        'FM999,999,990'
    ) AS "Americas SALES",
    TO_CHAR(
        SUM(CASE WHEN co.country_region = 'Europe' THEN s.amount_sold ELSE 0 END)
            OVER (PARTITION BY t.calendar_month_desc, p.prod_category),
        'FM999,999,990'
    ) AS "Europe SALES"
FROM sh.sales      s
JOIN sh.products   p  ON p.prod_id    = s.prod_id
JOIN sh.times      t  ON t.time_id    = s.time_id
JOIN sh.customers  cu ON cu.cust_id   = s.cust_id
JOIN sh.countries  co ON co.country_id = cu.country_id
WHERE t.calendar_month_desc IN ('2000-01', '2000-02', '2000-03')
  AND co.country_region IN ('Americas', 'Europe')
ORDER BY t.calendar_month_desc, p.prod_category;
