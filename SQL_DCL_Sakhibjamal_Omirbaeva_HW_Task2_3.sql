
--  SQL DCL HW Task2 & Task3
-- dvdrental database
-- Sakhibjamal Omirbaeva


--  File was run as the postgres superuser.
--  Testing was on PostgreSQL 14


--  TASK 2. Implement role-based authentication model


--  Step 1. Create rentaluser with password, connect only

--  The task says: give the ability to connect but no other
--  permissions. So I create the role with LOGIN and then grant
--  CONNECT on the database. Nothing else yet

CREATE ROLE rentaluser
    WITH LOGIN PASSWORD 'rentalpassword';

GRANT CONNECT ON DATABASE dvdrental TO rentaluser;

-- Verifying the role was created correctly:
SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname = 'rentaluser';



--  Step 2. Grant rentaluser SELECT on the customer table
--          then verify it actually works
--  I also need to grant USAGE on the schema, otherwise even
--  SELECT won't work — I learned that the hard way.

GRANT USAGE ON SCHEMA public TO rentaluser;
GRANT SELECT ON TABLE customer TO rentaluser;

-- Verify the grant is there:
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'rentaluser'
  AND table_name = 'customer';


-- Now switching to rentaluser and test the SELECT:
-- (Running the two lines below as rentaluser, not as postgres)

SET ROLE rentaluser;

SELECT customer_id, first_name, last_name, email
FROM customer
LIMIT 5;


-- Switching back to superuser for the rest:
RESET ROLE;


--  Step 3. Create the "rental" group role and add rentaluser to it

--  In PostgreSQL, a "group" is just a role without LOGIN.
--  I add rentaluser as a member using GRANT <group> TO <user>.

CREATE ROLE rental;   -- group role, no LOGIN

GRANT rental TO rentaluser;

-- Checking that the membership is there:
SELECT r.rolname AS group_role, m.rolname AS member
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname = 'rental';


--  Step 4. Grant rental group INSERT and UPDATE on the rental table
--          Then inserting a row and update a row under that role

GRANT INSERT, UPDATE ON TABLE rental TO rental;

-- The rental table uses a sequence for rental_id, so I need this:
GRANT USAGE ON SEQUENCE rental_rental_id_seq TO rental;

-- Now switching to rentaluser (which inherits rental group permissions):
SET ROLE rentaluser;

-- INSERT a new rental row:
INSERT INTO rental (rental_date, inventory_id, customer_id, staff_id, return_date)
VALUES (NOW(), 1, 1, 1, NOW() + INTERVAL '7 days');

-- UPDATE an existing rental row:
UPDATE rental
SET return_date = NOW() + INTERVAL '10 days'
WHERE rental_id = 1;

-- Switching back:
RESET ROLE;


--  Step 5. Revoke INSERT from the rental group
--          Then prove that INSERT is now denied

REVOKE INSERT ON TABLE rental FROM rental;

-- Now switching to rentaluser and try to insert — should fail:
SET ROLE rentaluser;

INSERT INTO rental (rental_date, inventory_id, customer_id, staff_id, return_date)
VALUES (NOW(), 2, 2, 1, NOW() + INTERVAL '7 days');

-- Expected error:
--   ERROR:  permission denied for table rental
--
-- That confirms the revoke worked. INSERT is blocked, which is
-- exactly what the task asked me to demonstrate.

-- UPDATE should still work though, since we only revoked INSERT:
UPDATE rental
SET return_date = NOW() + INTERVAL '14 days'
WHERE rental_id = 2;

-- Expected output: UPDATE 1  (still works — only INSERT was revoked)

RESET ROLE;


-- ----------------------------------------------------------------
--  Step 6. Create a personalized role for an existing customer
--          Format: client_{first_name}_{last_name}
--          Customer must have both rental and payment history

--  I looked at the data first to pick a customer who has both
--  rentals and payments. Mary Smith (customer_id = 1) fits well.

-- First I double-checked which customers have both:
SELECT c.customer_id,
       c.first_name,
       c.last_name,
       COUNT(DISTINCT r.rental_id)  AS rental_count,
       COUNT(DISTINCT p.payment_id) AS payment_count
FROM customer c
JOIN rental  r ON r.customer_id  = c.customer_id
JOIN payment p ON p.customer_id  = c.customer_id
GROUP BY c.customer_id, c.first_name, c.last_name
HAVING COUNT(DISTINCT r.rental_id) > 0
   AND COUNT(DISTINCT p.payment_id) > 0
ORDER BY rental_count DESC
LIMIT 5;

-- Output showed Mary Smith is a good choice.
-- Role name format: client_mary_smith

CREATE ROLE client_mary_smith
    WITH LOGIN PASSWORD 'mary_secure_pass!';

GRANT CONNECT ON DATABASE dvdrental TO client_mary_smith;
GRANT USAGE   ON SCHEMA public      TO client_mary_smith;
GRANT SELECT  ON TABLE rental       TO client_mary_smith;
GRANT SELECT  ON TABLE payment      TO client_mary_smith;

-- Quick check:
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'client_mary_smith';

-- Expected output:
--   grantee          | table_name | privilege_type
--   -----------------+------------+---------------
--   client_mary_smith| payment    | SELECT
--   client_mary_smith| rental     | SELECT




--  TASK 3. Implement Row-Level Security (RLS)


--  The goal is: client_mary_smith should only see her own rows
--  in the rental and payment tables. She should not be able to
--  see data belonging to other customers.
--
--  Mary Smith's customer_id = 1. I use that in the RLS policy.


--  Step 1. Enable RLS on the rental and payment tables

--  RLS does NOT apply to superusers by default!
--  I need to use FORCE ROW SECURITY if I want it to apply to
--  table owners too — but for this task the client role is not
--  the owner, so regular ALTER TABLE is enough.

ALTER TABLE rental  ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment ENABLE ROW LEVEL SECURITY;

-- Confirm RLS is now enabled:
SELECT tablename, rowsecurity
FROM pg_tables
WHERE tablename IN ('rental', 'payment');

-- Expected output:
--   tablename | rowsecurity
--   ----------+------------
--   rental    | t
--   payment   | t


--  Step 2. Create RLS policy for rental table

--  The policy says: when client_mary_smith queries rental,
--  only return rows where customer_id matches her customer_id (1).

CREATE POLICY customer_own_rentals
    ON rental
    FOR SELECT
    TO client_mary_smith
    USING (customer_id = 1);

   
--  Step 3. Create RLS policy for payment table

CREATE POLICY customer_own_payments
    ON payment
    FOR SELECT
    TO client_mary_smith
    USING (customer_id = 1);

-- Checking both policies were created:
SELECT schemaname, tablename, policyname, roles, cmd, qual
FROM pg_policies
WHERE tablename IN ('rental', 'payment');

-- Expected output:
--   tablename | policyname             | roles              | cmd    | qual
--   ----------+------------------------+--------------------+--------+------------------
--   rental    | customer_own_rentals   | {client_mary_smith}| SELECT | (customer_id = 1)
--   payment   | customer_own_payments  | {client_mary_smith}| SELECT | (customer_id = 1)


--  Step 4. Test — demonstrate allowed access (her own data)

SET ROLE client_mary_smith;

-- This should return only Mary's rentals (customer_id = 1):
SELECT rental_id, rental_date, inventory_id, customer_id, return_date
FROM rental
ORDER BY rental_date DESC
LIMIT 5;

-- Expected output: only rows with customer_id = 1

-- Same for payments:
SELECT payment_id, amount, payment_date, customer_id
FROM payment
ORDER BY payment_date DESC
LIMIT 5;

-- Expected output: only rows with customer_id = 1


--  Step 5. Test — demonstrate denied access (other customers)

--  RLS does not throw an error — it just returns zero rows.
--  That is actually the expected behavior. The data is hidden,
--  not blocked with a permission error.

-- Trying to select specifically a row belonging to customer_id = 2:
SELECT rental_id, customer_id
FROM rental
WHERE customer_id = 2;

-- Expected output:

--   (0 rows)
--
--  No error, but no data either. Mary cannot see Patricia's rentals.

-- Checking total row count — should only show Mary's rows, not all:
SELECT COUNT(*) AS visible_rentals FROM rental;

-- Expected output: only Mary's rental count (not the full 16044)
--   visible_rentals
--   32
-- As superuser the real count is 16044. As client_mary_smith
-- we only see 32 — that confirms RLS is working correctly.

RESET ROLE;

-- As superuser we see the full table again:
SELECT COUNT(*) AS total_rentals FROM rental;

-- Expected output:
--   total_rentals
--   16044



--  CLEANUP

DROP POLICY IF EXISTS customer_own_rentals  ON rental;
DROP POLICY IF EXISTS customer_own_payments ON payment;
ALTER TABLE rental  DISABLE ROW LEVEL SECURITY;
ALTER TABLE payment DISABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE customer FROM rentaluser;
REVOKE ALL ON TABLE rental   FROM rental;
REVOKE ALL ON TABLE rental, payment FROM client_mary_smith;
REVOKE CONNECT ON DATABASE dvdrental FROM rentaluser, client_mary_smith;
DROP ROLE IF EXISTS rentaluser;
DROP ROLE IF EXISTS rental;
DROP ROLE IF EXISTS client_mary_smith;