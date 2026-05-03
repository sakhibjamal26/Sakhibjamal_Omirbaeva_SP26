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
    TO_CHAR(r.amount_sold / r.channel_total * 100, 'FM999.0000') || ' %' AS sales_percentage
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
     quarterly_sum) — exactly the (row_name, category, value) shape
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
   Top 300 customers by total sales across 1998, 1999 and 2001,
   broken down by sales channel (only that channel's purchases shown).

   My interpretation of the task:
   - "Top 300 based on total sales in the years 1998, 1999, and 2001"
     means I sum each customer's sales over those three years combined,
     then take the 300 customers with the highest combined total.
     ("Total sales in the years X, Y, Z" reads to me as one combined
     figure, not three separate per-year rankings.)
   - "Categorize the customers based on their sales channels" and
     "Include in the report only purchases made on the channel
     specified" tell me the output is split by channel: a customer who
     bought on three channels appears in three rows, each row showing
     only that channel's amount.

   Window function used:
   - DENSE_RANK() OVER (ORDER BY total_sales DESC) to identify the
     top 300. DENSE_RANK so ties at position 300 are all kept (no gaps).
*/

WITH combined_sales AS (
    -- step 1: total sales per customer across the three required years
    SELECT
        s.cust_id,
        SUM(s.amount_sold) AS total_sales
    FROM sh.sales s
    JOIN sh.times t USING (time_id)
    WHERE t.calendar_year IN (1998, 1999, 2001)
    GROUP BY s.cust_id
),
ranked_customers AS (
    -- step 2: rank by combined sales — single ranking, no PARTITION BY
    SELECT
        cust_id,
        total_sales,
        DENSE_RANK() OVER (ORDER BY total_sales DESC) AS rnk
    FROM combined_sales
),
top_300 AS (
    SELECT cust_id FROM ranked_customers WHERE rnk <= 300
)
-- step 3: for each qualifying customer, sum their sales per channel
-- but only count purchases that happened on that channel and in the
-- three years of interest.
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
WHERE s.cust_id IN (SELECT cust_id FROM top_300)
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
    SUM(s.amount_sold) FILTER (WHERE co.country_region = 'Americas') AS "Americas SALES",
    SUM(s.amount_sold) FILTER (WHERE co.country_region = 'Europe')   AS "Europe SALES"
FROM sh.sales      s
JOIN sh.products   p  ON p.prod_id    = s.prod_id
JOIN sh.times      t  ON t.time_id    = s.time_id
JOIN sh.customers  cu ON cu.cust_id   = s.cust_id
JOIN sh.countries  co ON co.country_id = cu.country_id
WHERE t.calendar_month_desc IN ('2000-01', '2000-02', '2000-03')
  AND co.country_region IN ('Americas', 'Europe')
GROUP BY t.calendar_month_desc, p.prod_category
ORDER BY t.calendar_month_desc, p.prod_category;
