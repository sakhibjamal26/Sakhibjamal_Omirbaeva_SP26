-- SQL Analysis - Window Frames Homework
-- By: Sakhibjamal Omirbaeva

-- Some few general notes on my approach:
--   * I'm using CTEs throughout - I find it much easier to follow
--     the logic step by step than nesting subqueries.
--   * For Tasks 1 and 2 I'm using window FRAMES explicitly where
--     the math actually depends on the frame (rolling averages,
--     bounded windows). Where I just need a partition aggregate,
--     I leave the frame off so I don't get the implicit ROWS frame
--     by accident.
--   * Comments are in plain English :) explaining what I was thinking,
--     because half the homework is showing the reasoning.


-- TASK 1
-- Annual sales analysis for 1999-2001 by region (Americas, Asia,
-- Europe) and channel, with channel share %, the same % for the
-- previous year, and the year-over-year diff

-- A few decisions worth flagging up front:
--
-- 1) The output is for years 1999-2001, but I need 1998 data inside
--    the calculation so that the 1999 rows can show a "previous period"
--    percentage. So the data scope below is 1998-2001, and I filter
--    down to 1999-2001 only at the very end.
--
-- 2) I'm not filtering channels at all. The sample only shows three
--    channels (Direct Sales, Internet, Partners) per region/year, and
--    after checking the data that's exactly what naturally exists for
--    1999-2001 in these regions - so no artificial filter is needed.
--    Tele Sales does appear in 1998, which is correct behaviour because
--    it should still count toward the 1998 denominator when we calculate
--    the previous-period % for the 1999 rows.
--
-- 3) Format: amount with 2 decimals + " $", percentages with 2 decimals
--    + " %". I matched the sample format and kept the actual data
--    precision (.86 cents etc.) instead of rounding away the kopecks.

--    NULL safety on the previous-period columns: as noted by mentor, with
--    the 1998-2001 scope every 1999 row finds its prior year, so in
--    practice nothing is NULL. But to make the intent explicit (and so
--    the report doesn't go silently blank if someone later narrows the
--    scope to just 1999-2001), I'm wrapping the previous-period and
--   diff columns in COALESCE with an 'n/a' fallback.

WITH yearly_sales AS (
    -- Step 1: aggregate raw sales rows up to (region, year, channel) level.
    -- I need 1998 in the scope so that LAG can find a previous year for 1999.
    SELECT
        co.country_region,
        t.calendar_year,
        c.channel_desc,
        SUM(s.amount_sold) AS amount_sold
    FROM sh.sales      s
    JOIN sh.customers  cu ON cu.cust_id    = s.cust_id
    JOIN sh.countries  co ON co.country_id = cu.country_id
    JOIN sh.channels   c  ON c.channel_id  = s.channel_id
    JOIN sh.times      t  ON t.time_id     = s.time_id
    WHERE co.country_region IN ('Americas', 'Asia', 'Europe')
      AND t.calendar_year   BETWEEN 1998 AND 2001
    GROUP BY co.country_region, t.calendar_year, c.channel_desc
),

with_pct AS (
    -- Step 2: each channel's share of total sales inside its (region, year).
    -- This is a partitioned SUM as a window function - so the channel rows
    -- inside the same (region, year) all see the same denominator.
    -- I deliberately don't put a frame here: with no ORDER BY in the OVER,
    -- the default is the entire partition, which is what I want.
    SELECT
        country_region,
        calendar_year,
        channel_desc,
        amount_sold,
        amount_sold * 100.0
            / SUM(amount_sold) OVER (PARTITION BY country_region, calendar_year)
            AS pct_by_channels
    FROM yearly_sales
),

with_lag AS (
    -- next step: pull the previous year's percentage for the same channel in
    -- the same region. LAG over (region, channel) ordered by year gives me
    -- exactly that - for "Americas / Direct Sales / 1999" it returns the
    -- "Americas/Direct Sales/1998" percentage.
    SELECT
        country_region,
        calendar_year,
        channel_desc,
        amount_sold,
        pct_by_channels,
        LAG(pct_by_channels) OVER (
            PARTITION BY country_region, channel_desc
            ORDER BY calendar_year
        ) AS pct_previous_period
    FROM with_pct
)

SELECT
    country_region,
    calendar_year,
    channel_desc,
    -- Format the numeric columns to match the sample report layout.
    -- FM strips the padding, the G inserts thousand separators, and
    -- the trailing 0 in '0D00' makes sure we always show 2 decimals.
    TO_CHAR(amount_sold,                       'FM9G999G999G990D00') || ' $' AS amount_sold,
    TO_CHAR(pct_by_channels,                   'FM990D00')           || ' %' AS "% BY CHANNELS",
    COALESCE(TO_CHAR(pct_previous_period,                'FM990D00') || ' %','n/a') AS "% PREVIOUS PERIOD",
    COALESCE(TO_CHAR(pct_by_channels - pct_previous_period, 'FM990D00') || ' %', 'n/a') AS "% DIFF"
FROM with_lag
WHERE calendar_year BETWEEN 1999 AND 2001   -- now we drop 1998 from the output
ORDER BY country_region ASC,
         calendar_year  ASC,
         channel_desc   ASC;



-- TASK 2
-- Daily sales for weeks 49, 50, 51 of 1999, with:
--   * CUM_SUM            - running total that resets each week
--   * CENTERED_3_DAY_AVG - centered moving average with special
--                          rules for Monday and Friday

-- The trickiest part of this task is the centered_3_day_avg rules:
--   * Monday  -> avg of (Saturday-prev, Sunday-prev, Monday, Tuesday)  = 4 days
--   * Friday  -> avg of (Thursday, Friday, Saturday, Sunday)            = 4 days
--   * Other   -> avg of (previous day, current day, next day)           = 3 days
--
-- The other thing the task explicitly warns about: the calculation has
-- to be correct at the BEGINNING of week 49 and the END of week 51.
-- That means for Monday Dec 6 the average must reach back into week 48
-- (for Sat Dec 4 and Sun Dec 5), and for Sunday Dec 26 it must reach
-- forward into week 52 (for Mon Dec 27).
--
-- To make this work I diid these 3 things:
--   1) Pull all daily totals for the whole year 1999, not just the
--      target weeks. This way the window function naturally has access
--      to days outside weeks 49-51 when it needs them.
--   2) Use ORDER BY time_id WITHOUT a PARTITION BY week in the centered
--      avg - if I partitioned by week, the Monday window wouldn't see
--      the previous weekend at all.
--   3) Filter down to weeks 49-51 only at the very end, after the
--      window math is done.
--
-- About the given sample: I noticed the sample has values that don't
-- match the formula at the boundary rows (e.g. Mon Dec 6 shows 46458.23
-- which is just avg(Mon, Tue) - it's missing the previous weekend).
-- That's exactly why the task says "do not use it as is" - the boundary
-- rows in the sample show what you'd get with a buggy query. My values
-- match the sample for all the non-boundary rows (Mon Dec 13, Mon Dec 20,
-- Sat Dec 18, Sun Dec 19, Fri Dec 17 etc.), which is reassuring.

WITH daily AS (
    -- Step 1: collapse sales to one row per day. I'm scoping to 1999
    -- because that's enough to cover both boundaries (week 48 weekend
    -- before the report, and week 52 Monday after it).
    SELECT
        t.calendar_week_number,
        t.time_id,
        t.day_name,
        SUM(s.amount_sold) AS sales
    FROM sh.sales s
    JOIN sh.times t ON t.time_id = s.time_id
    WHERE t.calendar_year = 1999
    GROUP BY t.calendar_week_number, t.time_id, t.day_name
),

windowed AS (
    -- Step 2: layer on the two window calculations.
    --
    -- CUM_SUM resets every week, so I PARTITION BY calendar_week_number.
    -- Inside the partition I order by time_id and let the default frame
    -- (RANGE UNBOUNDED PRECEDING -> CURRENT ROW) give me the running total.
    --
    -- CENTERED_3_DAY_AVG must NOT be partitioned by week, otherwise Monday
    -- can't reach into the previous Saturday/Sunday. I order by time_id
    -- across the whole year and use a CASE to pick the right frame width
    -- for Monday, Friday, and everything else.
    SELECT
        calendar_week_number,
        time_id,
        day_name,
        sales,

        SUM(sales) OVER (
            PARTITION BY calendar_week_number
            ORDER BY time_id
        ) AS cum_sum,

        CASE
            WHEN day_name = 'Monday' THEN
                -- 2 PRECEDING reaches back to the previous Sat & Sun,
                -- CURRENT ROW is Monday itself, 1 FOLLOWING is Tuesday.
                -- Total: 4 rows in the window.
                AVG(sales) OVER (
                    ORDER BY time_id
                    ROWS BETWEEN 2 PRECEDING AND 1 FOLLOWING
                )
            WHEN day_name = 'Friday' THEN
                -- 1 PRECEDING is Thursday, 2 FOLLOWING covers Sat & Sun.
                -- Total: 4 rows in the window.
                AVG(sales) OVER (
                    ORDER BY time_id
                    ROWS BETWEEN 1 PRECEDING AND 2 FOLLOWING
                )
            ELSE
                -- Tue, Wed, Thu, Sat, Sun: standard centered 3-day window.
                AVG(sales) OVER (
                    ORDER BY time_id
                    ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
                )
        END AS centered_3_day_avg
    FROM daily
)

SELECT
    calendar_week_number,
    time_id,
    day_name,
    ROUND(sales::numeric,              2) AS sales,
    ROUND(cum_sum::numeric,            2) AS cum_sum,
    ROUND(centered_3_day_avg::numeric, 2) AS centered_3_day_avg
FROM windowed
WHERE calendar_week_number BETWEEN 49 AND 51   -- final filter to the target weeks
ORDER BY time_id;

-- TASK 3
-- Three examples of window functions that include a frame clause,
-- one each for ROWS, RANGE, and GROUPS. With a short note on why
-- I picked that frame mode for each case.

-- Quick mental model of the three frame modes (this helped me when
-- I was deciding which to use):
--
--   * ROWS   - counts physical rows. "5 PRECEDING" means literally 5
--              rows back, no matter what their values are.
--   * RANGE  - works on the VALUE of the ORDER BY column. Two rows
--              with the same ORDER BY value are peers and are treated
--              identically. Also lets you do interval-based windows.
--   * GROUPS - counts peer groups. "1 PRECEDING" means one distinct
--              ORDER BY value back, regardless of how many rows that
--              value covers.
--
-- I tried to pick examples where the choice of frame actually matters,
-- so it's clear WHY each one is the right tool for the job.



-- Example 3a: ROWS 
-- For each customer, show every purchase together with the average amount
-- of their last 5 purchases (the 4 previous + the current one), in time
-- order.
--
-- Why ROWS: I want exactly 5 transactions every time, no matter how the
-- dates are spread out. ROWS BETWEEN 4 PRECEDING AND CURRENT ROW gives
-- me a guaranteed 5-row window. RANGE wouldn't work cleanly here because
-- a single customer can have multiple purchases on the same day, and I
-- don't want all same-day purchases collapsed into one peer. GROUPS would
-- give me 5 distinct days, not 5 transactions, which isn't what I want.

SELECT
    s.cust_id,
    s.time_id,
    s.amount_sold,
    AVG(s.amount_sold) OVER (
        PARTITION BY s.cust_id
        ORDER BY s.time_id
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
    ) AS avg_last_5_purchases
FROM sh.sales s
WHERE s.cust_id IN (
    -- Just picking a few active customers so the result is small enough to read
    SELECT cust_id FROM sh.sales GROUP BY cust_id ORDER BY COUNT(*) DESC LIMIT 3
)
ORDER BY s.cust_id, s.time_id;



-- Example 3b: RANGE 
-- For each individual sale, show the running total of all sales in the
-- same channel up to and including that sale's date. I'm intentionally
-- ordering by time_id, which has many ties (lots of sales per day per
-- channel), so the choice of frame mode actually matters.
--
-- Why RANGE: I want all sales on the same day to share the same running
-- total - the cumulative number "as of end of day X" should be identical
-- for every sale that happened on day X. RANGE BETWEEN UNBOUNDED PRECEDING
-- AND CURRENT ROW does exactly that, because RANGE pulls in every peer row
-- (every row with the same time_id). If I used ROWS instead, every sale on
-- the same day would get a different running total depending on its physical
-- position in the result set - which is meaningless when there's no real
-- ordering inside a single day.

SELECT
    s.channel_id,
    s.time_id,
    s.amount_sold,
    SUM(s.amount_sold) OVER (
        PARTITION BY s.channel_id
        ORDER BY s.time_id
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_through_day
FROM sh.sales s
WHERE s.channel_id = 4                              -- single channel keeps the output focused
  AND s.time_id BETWEEN DATE '2000-01-01' AND DATE '2000-01-05'
ORDER BY s.time_id, s.amount_sold;



-- Example 3c: GROUPS 
-- For each individual sale in a given channel, show the average sale
-- amount over the last 7 distinct DAYS (not the last 7 rows, and not a
-- fixed time interval). Same-day sales count as one group.
--
-- Why GROUPS: this is the "I want N peer-groups" use case that GROUPS
-- was designed for. ROWS would give me 7 physical rows, which on a busy
-- channel might not even cover one full day. RANGE with INTERVAL '6' DAY
-- could also work, but it cares about calendar gaps - if a day has no
-- sales, RANGE silently shrinks the window. GROUPS BETWEEN 6 PRECEDING
-- AND CURRENT ROW says "include 6 previous distinct time_id values plus
-- the current one", regardless of how many rows or how many calendar
-- days fall between them. That's the cleanest fit for "last 7 active
-- selling days".

SELECT
    s.channel_id,
    s.time_id,
    s.amount_sold,
    AVG(s.amount_sold) OVER (
        PARTITION BY s.channel_id
        ORDER BY s.time_id
        GROUPS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS avg_over_last_7_active_days
FROM sh.sales s
WHERE s.channel_id = 4
  AND s.time_id BETWEEN DATE '2000-01-01' AND DATE '2000-01-15'
ORDER BY s.time_id, s.amount_sold
LIMIT 50;
