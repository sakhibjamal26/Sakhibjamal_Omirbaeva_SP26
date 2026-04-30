
--  dvd_rental Database
--  by Sakhibjamal Omirbaeva
--
--  Revised after mentor review. Five things needed to be changed:
--   1) added SELECT to the rental group grant — UPDATE ... WHERE
--      needs SELECT to read the row before updating it
--   2) no more hardcoded ids — values are looked up dynamically
--   3) script is re-runnable: CREATE ROLE wrapped in DO blocks,
--      DROP POLICY IF EXISTS before each CREATE POLICY
--   4) every table is schema-qualified with public.
--   5) RLS policy is generic — uses current_user to find the
--      matching customer, so it works for any client_{first}_{last}
--      role, not only one hardcoded user


-- ============================================================
--  TASK 2. Implement role-based authentication model
-- ============================================================


--  Step 1. Create rentaluser (LOGIN + CONNECT only)
--
--  CREATE ROLE doesn't support IF NOT EXISTS, so I wrap it in a
--  DO block to make the script re-runnable.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rentaluser') THEN
        CREATE ROLE rentaluser WITH LOGIN PASSWORD 'rentalpassword';
    END IF;
END $$;

GRANT CONNECT ON DATABASE dvdrental TO rentaluser;

-- Verify the role:
SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname = 'rentaluser';


--  Step 2. Grant rentaluser SELECT on customer + USAGE on schema
--
--  Without USAGE on the schema even SELECT fails — learned that
--  the hard way last time.

GRANT USAGE  ON SCHEMA public          TO rentaluser;
GRANT SELECT ON TABLE  public.customer TO rentaluser;

-- Verify the grant:
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'rentaluser'
  AND table_name = 'customer';

-- Test as rentaluser:
SET ROLE rentaluser;

SELECT customer_id, first_name, last_name, email
FROM public.customer
LIMIT 5;

RESET ROLE;


--  Step 3. Create "rental" group role and add rentaluser

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rental') THEN
        CREATE ROLE rental;   -- NOLOGIN by default => group role
    END IF;
END $$;

GRANT rental TO rentaluser;

-- Verify membership:
SELECT r.rolname AS group_role, m.rolname AS member
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname = 'rental';


--  Step 4. Grant rental group SELECT, INSERT, UPDATE on rental
--          then INSERT a row and UPDATE one row dynamically
--
--  IMPORTANT: SELECT is required here even though the task only
--  asks for INSERT and UPDATE. The reason is that
--  UPDATE rental ... WHERE rental_id = X has to *read* the row
--  to find it, and that read needs SELECT privilege. Without it
--  we get "permission denied for table rental" on the UPDATE.
--  This was the bug the mentor caught last time.

GRANT SELECT, INSERT, UPDATE ON TABLE public.rental TO rental;
GRANT USAGE ON SEQUENCE public.rental_rental_id_seq TO rental;

SET ROLE rentaluser;

-- INSERT one rental row + UPDATE that exact row, no hardcoded ids.
-- I use a CTE with RETURNING to pass the new rental_id straight
-- into the UPDATE.

WITH new_rental AS (
    INSERT INTO public.rental (rental_date, inventory_id, customer_id, staff_id, return_date)
    VALUES (
        NOW(),
        (SELECT inventory_id FROM public.inventory LIMIT 1),
        (SELECT customer_id  FROM public.customer  LIMIT 1),
        (SELECT staff_id     FROM public.staff     LIMIT 1),
        NOW() + INTERVAL '7 days'
    )
    RETURNING rental_id
)
UPDATE public.rental
   SET return_date = NOW() + INTERVAL '10 days'
 WHERE rental_id = (SELECT rental_id FROM new_rental);

RESET ROLE;


--  Step 5. Revoke INSERT from rental group, prove INSERT is denied
--
--  This INSERT is *expected to fail* — that's the demonstration
--  the task asks for. The mentor's "no errors" rule explicitly
--  excludes validations for denied access, so I let it run.

REVOKE INSERT ON TABLE public.rental FROM rental;

SET ROLE rentaluser;

-- Expected: ERROR: permission denied for table rental
INSERT INTO public.rental (rental_date, inventory_id, customer_id, staff_id, return_date)
VALUES (
    NOW(),
    (SELECT inventory_id FROM public.inventory LIMIT 1),
    (SELECT customer_id  FROM public.customer  LIMIT 1),
    (SELECT staff_id     FROM public.staff     LIMIT 1),
    NOW() + INTERVAL '7 days'
);

-- UPDATE still works because we only revoked INSERT:
UPDATE public.rental
   SET return_date = NOW() + INTERVAL '14 days'
 WHERE rental_id = (SELECT MAX(rental_id) FROM public.rental);

RESET ROLE;


--  Step 6. Personalized role for an existing customer
--          Format: client_{first_name}_{last_name}
--
--  I'm picking Mary Smith — she has plenty of rental and payment
--  history. The role NAME has to include her name (that's the
--  format the task specifies), but I never use her customer_id
--  literally anywhere — the RLS policy below looks it up via
--  current_user.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'client_mary_smith') THEN
        CREATE ROLE client_mary_smith WITH LOGIN PASSWORD 'mary_secure_pass!';
    END IF;
END $$;

GRANT CONNECT ON DATABASE dvdrental    TO client_mary_smith;
GRANT USAGE   ON SCHEMA   public       TO client_mary_smith;
GRANT SELECT  ON TABLE    public.rental  TO client_mary_smith;
GRANT SELECT  ON TABLE    public.payment TO client_mary_smith;

-- Confirm Mary actually has rental + payment history (sanity check,
-- looked up by name, no hardcoded id):
SELECT c.first_name,
       c.last_name,
       COUNT(DISTINCT r.rental_id)  AS rental_count,
       COUNT(DISTINCT p.payment_id) AS payment_count
FROM public.customer c
JOIN public.rental   r ON r.customer_id = c.customer_id
JOIN public.payment  p ON p.customer_id = c.customer_id
WHERE LOWER(c.first_name) = 'mary'
  AND LOWER(c.last_name)  = 'smith'
GROUP BY c.first_name, c.last_name;

-- Verify grants:
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'client_mary_smith';


-- ============================================================
--  TASK 3. Implement Row-Level Security (RLS)
-- ============================================================
--
--  Goal: any client_{first_name}_{last_name} role sees ONLY their
--  own rows in rental and payment.
--
--  The trick to making the policy generic (not tied to one user)
--  is to parse current_user back into first_name + last_name and
--  look up the matching customer_id. So if I create another role
--  later — say client_patricia_johnson — the same policy filters
--  her rows automatically. No edits needed.


--  Step 1. Enable RLS on rental and payment

ALTER TABLE public.rental  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment ENABLE ROW LEVEL SECURITY;

SELECT schemaname, tablename, rowsecurity
FROM pg_tables
WHERE tablename IN ('rental', 'payment')
  AND schemaname = 'public';


--  Step 2. Create generic RLS policies on rental and payment
--
--  Applied TO PUBLIC so they cover all client_*_* roles (current
--  and future). Superusers bypass RLS, so postgres still sees
--  the whole table.
--  DROP POLICY IF EXISTS first => re-runnable.

DROP POLICY IF EXISTS customer_own_rentals  ON public.rental;
DROP POLICY IF EXISTS customer_own_payments ON public.payment;

CREATE POLICY customer_own_rentals
    ON public.rental
    FOR SELECT
    TO PUBLIC
    USING (
        customer_id = (
            SELECT c.customer_id
            FROM public.customer c
            WHERE 'client_' || LOWER(c.first_name) || '_' || LOWER(c.last_name) = current_user
        )
    );

CREATE POLICY customer_own_payments
    ON public.payment
    FOR SELECT
    TO PUBLIC
    USING (
        customer_id = (
            SELECT c.customer_id
            FROM public.customer c
            WHERE 'client_' || LOWER(c.first_name) || '_' || LOWER(c.last_name) = current_user
        )
    );

-- Verify both policies:
SELECT schemaname, tablename, policyname, roles, cmd, qual
FROM pg_policies
WHERE tablename IN ('rental', 'payment');


--  Step 3. Test — allowed access (Mary sees her own rows)

SET ROLE client_mary_smith;

-- Should return only Mary's rentals:
SELECT rental_id, rental_date, customer_id, return_date
FROM public.rental
ORDER BY rental_date DESC
LIMIT 5;

-- Should return only Mary's payments:
SELECT payment_id, amount, payment_date, customer_id
FROM public.payment
ORDER BY payment_date DESC
LIMIT 5;


--  Step 4. Test — denied access (other customers' rows are hidden)
--
--  RLS doesn't throw an error, it just silently filters. So the
--  "denial" looks like (0 rows). That's the documented behavior.

-- Try to look at someone else's rentals — should be 0 rows:
SELECT rental_id, customer_id
FROM public.rental
WHERE customer_id <> (
    SELECT customer_id FROM public.customer
    WHERE 'client_' || LOWER(first_name) || '_' || LOWER(last_name) = current_user
);

-- Total rows visible — should be only Mary's count, not 16044:
SELECT COUNT(*) AS visible_rentals FROM public.rental;

RESET ROLE;

-- As superuser the full table is visible again:
SELECT COUNT(*) AS total_rentals FROM public.rental;
-- 16044


-- ============================================================
--  CLEANUP
-- ============================================================

DROP POLICY IF EXISTS customer_own_rentals  ON public.rental;
DROP POLICY IF EXISTS customer_own_payments ON public.payment;

ALTER TABLE public.rental  DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment DISABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.customer        FROM rentaluser;
REVOKE ALL ON TABLE public.rental          FROM rental;
REVOKE ALL ON TABLE public.rental, public.payment FROM client_mary_smith;
REVOKE CONNECT ON DATABASE dvdrental       FROM rentaluser, client_mary_smith;

DROP ROLE IF EXISTS rentaluser;
DROP ROLE IF EXISTS rental;
DROP ROLE IF EXISTS client_mary_smith;
