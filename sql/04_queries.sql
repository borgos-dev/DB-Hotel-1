-- =====================================================================
-- 04_queries.sql  (L6)  Six analytical queries
-- ---------------------------------------------------------------------
-- Conventions
--   * A stay covers the NIGHTS [check_in_date, check_out_date): the check-out
--     day is not a night. Two stays overlap when a.in < b.out AND b.in < a.out,
--     so back-to-back stays do not conflict.
--   * "Blocking" reservations are the non-cancelled ones (BR-07).
--   * Amounts are in XAF. Revenue is reported excluding VAT (net revenue).
--   * Totals are derived from invoice lines, never stored (BR-15, BR-10).
-- Run with:  mysql -t < 04_queries.sql   (the -t flag draws tables)
-- =====================================================================

USE hotel_db;

-- =====================================================================
-- Q1. Rooms of a given type available between two dates
-- ---------------------------------------------------------------------
-- A room is available when NO non-cancelled reservation (pending or
-- confirmed or completed) holds it on any night of [@from, @to).
-- Per BR-03 availability comes from reservations ONLY, not from
-- room.operational_status; the current status is shown as information
-- (e.g. room 404 is out of service today but may be back in December).
-- =====================================================================
SET @room_type = 'Double';
SET @from      = '2026-10-17';
SET @to        = '2026-10-20';

SELECT ro.room_number,
       ro.floor_number,
       rt.name            AS room_type,
       ro.max_capacity,
       ro.base_price      AS price_per_night,
       ro.operational_status AS status_today          -- informational only (BR-03)
  FROM room ro
  JOIN room_type rt ON rt.room_type_id = ro.room_type_id
 WHERE rt.name = @room_type
   AND NOT EXISTS (                                    -- no blocking reservation overlaps the period
         SELECT 1
           FROM reservation_room rr
           JOIN reservation r ON r.reservation_id = rr.reservation_id
          WHERE rr.room_id        = ro.room_id
            AND r.status         <> 'cancelled'
            AND r.check_in_date   < @to
            AND r.check_out_date  > @from)
 ORDER BY ro.room_number;
-- Expected: 203 (the in-house guest leaves on 16 Oct), 301 and 302.
-- 202 is held by confirmed #19 and 204 by pending #16; the cancelled #14 on 202 is ignored.

-- Same query, another type and period (suites over Christmas):
SET @room_type = 'Suite';
SET @from      = '2026-12-24';
SET @to        = '2027-01-02';

SELECT ro.room_number, rt.name AS room_type, ro.max_capacity,
       ro.base_price AS price_per_night, ro.operational_status AS status_today
  FROM room ro
  JOIN room_type rt ON rt.room_type_id = ro.room_type_id
 WHERE rt.name = @room_type
   AND NOT EXISTS (
         SELECT 1
           FROM reservation_room rr
           JOIN reservation r ON r.reservation_id = rr.reservation_id
          WHERE rr.room_id        = ro.room_id
            AND r.status         <> 'cancelled'
            AND r.check_in_date   < @to
            AND r.check_out_date  > @from)
 ORDER BY ro.room_number;
-- Expected: 401, 403, 404 (402 is booked by confirmed #20).

-- =====================================================================
-- Q2. Monthly occupancy rate = nights sold / nights available
-- ---------------------------------------------------------------------
-- * nights sold      : nights of confirmed and completed reservations, counted
--                      per room and clipped to the month (a stay spanning two
--                      months is split). Pending reservations are not "sold" yet.
-- * nights available : number of rooms x number of days in the month.
--                      Assumption: the room inventory is constant (the model keeps
--                      no history of operational status, so out-of-service rooms
--                      cannot be removed for past months).
-- * Months come from a recursive calendar so months with no sale show 0 %.
-- =====================================================================
WITH RECURSIVE months AS (
    SELECT DATE_SUB(MIN(check_in_date), INTERVAL DAYOFMONTH(MIN(check_in_date)) - 1 DAY) AS month_start
      FROM reservation
    UNION ALL
    SELECT DATE_ADD(month_start, INTERVAL 1 MONTH)
      FROM months
     WHERE month_start < (SELECT DATE_SUB(MAX(check_out_date), INTERVAL DAYOFMONTH(MAX(check_out_date)) - 1 DAY)
                            FROM reservation)
),
inventory AS (SELECT COUNT(*) AS nb_rooms FROM room),
sold AS (
    SELECT m.month_start,
           SUM(GREATEST(0,
               DATEDIFF(LEAST(r.check_out_date, DATE_ADD(m.month_start, INTERVAL 1 MONTH)),
                        GREATEST(r.check_in_date, m.month_start)))) AS nights_sold
      FROM months m
      JOIN reservation r       ON r.status IN ('confirmed', 'completed')
                              AND r.check_in_date  < DATE_ADD(m.month_start, INTERVAL 1 MONTH)
                              AND r.check_out_date > m.month_start
      JOIN reservation_room rr ON rr.reservation_id = r.reservation_id
     GROUP BY m.month_start
)
SELECT DATE_FORMAT(m.month_start, '%Y-%m')                                  AS month,
       COALESCE(s.nights_sold, 0)                                           AS nights_sold,
       i.nb_rooms * DAY(LAST_DAY(m.month_start))                            AS nights_available,
       ROUND(100 * COALESCE(s.nights_sold, 0)
                 / (i.nb_rooms * DAY(LAST_DAY(m.month_start))), 2)          AS occupancy_rate_pct
  FROM months m
 CROSS JOIN inventory i
  LEFT JOIN sold s ON s.month_start = m.month_start
 ORDER BY m.month_start;

-- =====================================================================
-- Q3. Monthly revenue, split between accommodation and services
-- ---------------------------------------------------------------------
-- Revenue is recognised in the month of the invoice issue date and taken from
-- the invoice lines, excluding VAT. Lines of type 'miscellaneous' are shown in
-- their own column so that the three columns add up to the total.
-- =====================================================================
SELECT DATE_FORMAT(i.issue_date, '%Y-%m')                                                  AS month,
       SUM(CASE WHEN l.line_type = 'accommodation' THEN l.line_subtotal ELSE 0 END)        AS accommodation_revenue,
       SUM(CASE WHEN l.line_type = 'service'       THEN l.line_subtotal ELSE 0 END)        AS services_revenue,
       SUM(CASE WHEN l.line_type = 'miscellaneous' THEN l.line_subtotal ELSE 0 END)        AS miscellaneous_revenue,
       SUM(l.line_subtotal)                                                                AS total_revenue_excl_tax
  FROM invoice i
  JOIN invoice_line l ON l.invoice_id = i.invoice_id
 GROUP BY DATE_FORMAT(i.issue_date, '%Y-%m')
 ORDER BY month;

-- =====================================================================
-- Q4. Unpaid invoices with the outstanding balance, oldest first
-- ---------------------------------------------------------------------
-- v_invoice_balance (01_schema.sql) derives total, amount paid and balance from
-- the lines and payments. An invoice is unpaid when its balance is > 0,
-- i.e. status 'due' or 'partially_paid'.
-- =====================================================================
SELECT b.invoice_id,
       b.issue_date,
       CONCAT(c.last_name, ' ', c.first_name)  AS client,
       b.total_incl_tax,
       b.amount_paid,
       b.balance_due                           AS outstanding_balance,
       b.derived_status                        AS status,
       DATEDIFF(CURDATE(), b.issue_date)       AS days_since_issue
  FROM v_invoice_balance b
  JOIN reservation r ON r.reservation_id = b.reservation_id
  JOIN client c      ON c.client_id      = r.client_id
 WHERE b.balance_due > 0
 ORDER BY b.issue_date ASC, b.invoice_id ASC;

-- =====================================================================
-- Q5. Average rating and number of reviews per room type
-- ---------------------------------------------------------------------
-- A review belongs to a reservation, which may hold several rooms. We first
-- reduce to DISTINCT (review, room type) pairs so that a reservation with two
-- rooms of the same type counts once; a reservation mixing two types counts
-- once in each. LEFT JOIN keeps types that have no review (NULL average, 0 count).
-- =====================================================================
SELECT rt.name                          AS room_type,
       COUNT(rv.review_id)              AS nb_reviews,
       ROUND(AVG(rv.rating), 2)         AS average_rating
  FROM room_type rt
  LEFT JOIN (SELECT DISTINCT rev.review_id, rev.rating, ro.room_type_id
               FROM review rev
               JOIN reservation_room rr ON rr.reservation_id = rev.reservation_id
               JOIN room ro             ON ro.room_id        = rr.room_id) rv
         ON rv.room_type_id = rt.room_type_id
 GROUP BY rt.room_type_id, rt.name
 ORDER BY average_rating DESC, rt.name;

-- =====================================================================
-- Q6. The 5 highest-spending clients, with their number of stays
-- ---------------------------------------------------------------------
-- Spending = total invoiced including VAT on the client's completed stays.
-- Stays    = number of completed reservations. Clients without a completed
--            stay do not appear. Ties on spending are broken by client id
--            (so the result is deterministic).
-- =====================================================================
SELECT c.client_id,
       CONCAT(c.last_name, ' ', c.first_name)      AS client,
       COUNT(*)                                    AS nb_stays,
       SUM(b.total_incl_tax)                       AS total_spent,
       SUM(b.amount_paid)                          AS total_paid
  FROM client c
  JOIN reservation r       ON r.client_id      = c.client_id AND r.status = 'completed'
  JOIN v_invoice_balance b ON b.reservation_id = r.reservation_id
 GROUP BY c.client_id, c.last_name, c.first_name
 ORDER BY total_spent DESC, c.client_id
 LIMIT 5;
