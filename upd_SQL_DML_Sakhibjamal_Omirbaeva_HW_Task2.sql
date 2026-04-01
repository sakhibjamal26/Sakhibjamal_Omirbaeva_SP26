-- ============================================================
-- Task 2: DELETE vs TRUNCATE Investigation
-- Database: sakhibjamal (localhost:5431)
-- Author: Sakhibjamal Omirbaeva
-- ============================================================


-- ============================================================
-- STEP 1
-- Creating the table and filling it with 10 million rows
-- ============================================================

CREATE TABLE table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;


-- ============================================================
-- STEP 2
-- Checking how much space the table takes before anything
-- ============================================================

SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS INDEX,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS TABLE
FROM (
    SELECT *, total_bytes-index_bytes-COALESCE(toast_bytes,0) AS table_bytes
    FROM (
        SELECT c.oid, nspname AS table_schema, relname AS TABLE_NAME,
               c.reltuples AS row_estimate,
               pg_total_relation_size(c.oid) AS total_bytes,
               pg_indexes_size(c.oid) AS index_bytes,
               pg_total_relation_size(reltoastrelid) AS toast_bytes
        FROM pg_class c
        LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE relkind = 'r'
    ) a
) a
WHERE table_name LIKE '%table_to_delete%';

-- got 575 MB with 10,000,000 rows


-- ============================================================
-- STEP 3a
-- Running DELETE to remove every 3rd row
-- ============================================================

DELETE FROM table_to_delete
WHERE REPLACE(col, 'veeeeeeery_long_string','')::int % 3 = 0;

-- took 11 seconds (start 08:00:01, finish 08:00:12)
-- deleted 3,333,333 rows, 6,666,667 rows remaining


-- ============================================================
-- STEP 3b
-- Checking space after DELETE
-- ============================================================

-- still 575 MB — same as before, nothing changed
-- I was surprised by this at first but it makes sense after reading about MVCC.
-- Postgres doesn't actually remove the rows from disk when I DELETE them —
-- it just marks them as "dead" so they become invisible to new transactions.
-- The old data stays there on the page in case other transactions still need it.
-- So the physical size stays the same even though 1/3 of rows are gone.


-- ============================================================
-- STEP 3c
-- Running VACUUM FULL to actually reclaim the space
-- ============================================================

VACUUM FULL VERBOSE table_to_delete;

-- took 6 seconds (start 08:09:44, finish 08:09:50)
-- output said: found 46 removable, 6,666,667 nonremovable row versions in 73536 pages


-- ============================================================
-- STEP 3d
-- Checking space after VACUUM FULL
-- ============================================================

-- now 383 MB — down from 575 MB, so about 192 MB was freed
-- VACUUM FULL physically rewrote the whole table into a new file,
-- keeping only the live rows and releasing the rest back to the OS.
-- this is different from regular VACUUM which only marks dead space as reusable
-- but doesn't actually give it back to the OS.
-- the downside is that VACUUM FULL locks the table while it runs,
-- so you can't use it on a busy production table without planning downtime.


-- ============================================================
-- STEP 3e
-- Recreating the table fresh for the TRUNCATE test
-- ============================================================

DROP TABLE table_to_delete;

CREATE TABLE table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1,(10^7)::int) x;

-- back to 10,000,000 rows and 575 MB


-- ============================================================
-- STEP 4
-- Running TRUNCATE and comparing with DELETE
-- ============================================================

TRUNCATE table_to_delete;

-- took 1 second (start 08:13:00, finish 08:13:01)
-- space after: 8192 bytes (basically empty)
-- this is a huge difference compared to DELETE which took 11 seconds
-- and didn't free any space at all


-- ============================================================
-- INVESTIGATION RESULTS AND CONCLUSIONS
-- ============================================================

/*
--- Space consumption at each stage ---

| Stage                    | Size        | Rows       |
|--------------------------|-------------|------------|
| After CREATE             | 575 MB      | 10,000,000 |
| After DELETE (1/3 rows)  | 575 MB      | 6,666,667  |
| After VACUUM FULL        | 383 MB      | 6,666,667  |
| After TRUNCATE           | 8192 bytes  | 0          |


--- Comparing DELETE and TRUNCATE ---

Execution time:
DELETE took 11 seconds to remove 3,333,333 rows.
It had to go through every row one by one, check the condition,
write each deletion to the WAL log, and mark the row as dead.
That's a lot of work for 10 million rows.

TRUNCATE did the same job (removing all rows) in just 1 second.
It doesn't touch individual rows at all — it just drops the
underlying data files and creates new empty ones. That's why
it's so fast regardless of how many rows are in the table.

Disk space usage:
DELETE was honestly disappointing here — after removing 1/3 of
all rows the table was still exactly 575 MB. No space was freed.
I had to run VACUUM FULL separately to get it down to 383 MB,
and that took another 6 seconds on top of the 11 for DELETE.

TRUNCATE freed space immediately and completely — down to 8192
bytes in 1 second. No VACUUM needed at all.

Transaction behavior:
DELETE logs every single row deletion in the WAL, which is
why it's slower but also why it's fully transactional.
TRUNCATE is also transactional in PostgreSQL — it logs the
operation as a single DDL event rather than row by row,
which is what makes it so much faster.

Rollback:
Both can be rolled back in PostgreSQL.
If I wrap DELETE in a transaction and ROLLBACK, all the
deleted rows come back. Same with TRUNCATE — I can do
BEGIN; TRUNCATE ...; ROLLBACK; and the data is still there.
The difference is that TRUNCATE holds a stronger lock on
the table (ACCESS EXCLUSIVE) so it blocks even SELECT queries
while it runs, whereas DELETE uses ROW EXCLUSIVE which is lighter.
Mentor also noted that TRUNCATE resets the table's sequence if it has one —
so after TRUNCATE, the next INSERT starts from 1 again.
DELETE doesn't do this, so the sequence keeps counting from where it left off.


--- Why DELETE doesn't free space immediately ---

Postgres uses MVCC (Multi-Version Concurrency Control).
When I DELETE a row, Postgres doesn't remove it from the disk —
it just sets the row's xmax field to the current transaction ID,
which makes the row invisible to new queries. But the row stays
physically on the page because other transactions that started
before my DELETE might still need to see the old version.
The space only gets reclaimed when VACUUM confirms no transaction
needs that old row anymore and marks the space as reusable.
VACUUM FULL goes even further and actually compacts the table.

This is why after deleting 1/3 of rows the table was still 575 MB —
all those deleted rows were still sitting on disk as dead tuples.


--- Why VACUUM FULL changes table size ---

Regular VACUUM marks dead rows as available for reuse but doesn't
shrink the table file or return space to the operating system.
So if I have a 575 MB table and delete half of it, regular VACUUM
won't make the file any smaller — it just makes the freed pages
available for future inserts.

VACUUM FULL is different — it rewrites the entire table into a
brand new file, packing only the live rows tightly together, then
deletes the old file. That's why I saw it drop from 575 MB to 383 MB.
The tradeoff is that it locks the whole table and takes real time
(6 seconds in my test), so it's not something I'd run casually
on a production database during business hours.


--- Why TRUNCATE behaves differently ---

TRUNCATE skips the whole per-row process completely.
Instead of deleting rows one by one, it just tells the OS
"delete these data files" and creates new empty ones.
This is why it doesn't matter if the table has 1 row or
10 million rows — it always takes the same tiny amount of time.

It also explains why space is freed immediately — there are
literally no data files left, just an empty table structure.
The one thing TRUNCATE can't do is filter rows with WHERE —
it always removes everything, so I have to be sure that's
what I want before running it.


--- How these operations affect performance and storage ---

DELETE is the right choice when I need to remove specific rows
using a WHERE condition and need the safety of being able to roll back.
But on large tables it gets slow, and if I'm doing lots of deletes
regularly without proper VACUUM configuration, I'll end up with
"table bloat" — a table that's physically much larger than the
actual data in it, which slows down scans significantly.

TRUNCATE is the right choice when I want to clear a whole table
fast — for example resetting staging tables in ETL pipelines,
cleaning up temporary data, or refreshing a lookup table.
It's also better for storage since space is freed right away.

The main lesson from this experiment: just because I deleted
a lot of rows doesn't mean the table is smaller on disk.
I need VACUUM (or better, TRUNCATE if I can) to actually
recover that space. In production databases autovacuum handles
this automatically in the background, but VACUUM FULL requires
manual planning because of the table lock it takes.
*/
