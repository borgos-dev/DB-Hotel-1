-- =====================================================================
-- 03_test_data.sql  (L5)  Test data: normal cases + edge cases
-- ---------------------------------------------------------------------
-- Reference "today" of the data set: 2026-10-14 (a stay is in progress).
-- Rows are inserted with explicit ids so that 04_queries.sql / 05_tests.sql
-- can refer to them. Everything goes through the real constraints and
-- triggers of 02_constraints.sql: if a row broke a rule, this script would fail.
--
-- Minimum volumes (section 3.4) and what covers them
--   Rooms         15   4 types (Single, Double, Family, Suite), room 404 out of service
--   Clients       10   client 10 has NO reservation
--   Reservations  20   13 completed, 3 confirmed, 2 pending, 2 cancelled;
--                      multi-room: #5 (2 rooms) and #18 (2 rooms)
--   Services       4   opening hours differ by weekday (Spa closed on Sunday ...)
--   Invoices      13   7 paid, 3 partially paid, 3 due (several multi-payment)
--   Reviews        7   ratings 5,4,5,3,1,2,4
--
-- Edge cases deliberately present
--   * back-to-back stays on the same room (res 1 -> 2 on room 101; 18 -> 16 on 204)
--   * cancelled reservation #14 and confirmed #19 on the SAME room and dates
--     (a cancelled reservation frees its rooms, BR-07)
--   * guests == capacity (res 5: 6 guests / 4+2 places; res 10: 5 / 5)
--   * frozen nightly price lower than today's catalogue price (BR-08)
--   * service slot filled to capacity (Spa 16 Oct 14:00: 2 + 1 = 3), a slot used
--     on check-out day, a cancelled service booking
--   * review dated exactly on the check-out day (BR-17), completed stays without review
--   * invoice line with a 0 % tax rate; invoice settled by 2 payments
-- =====================================================================

USE hotel_db;

-- ---------------------------------------------------------------------
-- Rooms, types, amenities
-- ---------------------------------------------------------------------
INSERT INTO room_type (room_type_id, name, description) VALUES
 (1, 'Single', 'One bed, designed for one guest'),
 (2, 'Double', 'Double or twin beds, up to two or three guests'),
 (3, 'Family', 'Two bedrooms or large room for families'),
 (4, 'Suite',  'Separate living area, premium comfort');

INSERT INTO room (room_id, room_number, floor_number, room_type_id, max_capacity, base_price, operational_status) VALUES
 ( 1, '101', 1, 1, 1,  30000.00, 'available'),
 ( 2, '102', 1, 1, 1,  30000.00, 'available'),
 ( 3, '103', 1, 1, 1,  32000.00, 'being_cleaned'),
 ( 4, '201', 2, 1, 1,  32000.00, 'available'),
 ( 5, '202', 2, 2, 2,  45000.00, 'available'),
 ( 6, '203', 2, 2, 2,  45000.00, 'occupied'),
 ( 7, '204', 2, 2, 3,  52000.00, 'occupied'),
 ( 8, '301', 3, 2, 2,  48000.00, 'available'),
 ( 9, '302', 3, 2, 2,  48000.00, 'available'),
 (10, '303', 3, 3, 4,  78000.00, 'available'),
 (11, '304', 3, 3, 5,  90000.00, 'available'),
 (12, '401', 4, 4, 3, 120000.00, 'available'),
 (13, '402', 4, 4, 4, 150000.00, 'available'),
 (14, '403', 4, 4, 2, 115000.00, 'available'),
 (15, '404', 4, 4, 2, 115000.00, 'out_of_service');

INSERT INTO amenity (amenity_id, name) VALUES
 (1, 'Sea view'), (2, 'Balcony'), (3, 'Bathtub'), (4, 'Air conditioning'),
 (5, 'Minibar'), (6, 'Smart TV'), (7, 'Kitchenette'), (8, 'Safe');

-- every room: air conditioning + smart TV
INSERT INTO room_amenity (room_id, amenity_id)
SELECT r.room_id, a.amenity_id FROM room r JOIN amenity a ON a.name IN ('Air conditioning', 'Smart TV');
-- the rest, by room number (a room has several amenities, an amenity serves several rooms: BR-02)
INSERT INTO room_amenity (room_id, amenity_id)
SELECT r.room_id, a.amenity_id
  FROM (            SELECT '301' n, 'Sea view' a UNION ALL SELECT '302','Sea view' UNION ALL SELECT '401','Sea view'
         UNION ALL  SELECT '402','Sea view'      UNION ALL SELECT '403','Sea view' UNION ALL SELECT '404','Sea view'
         UNION ALL  SELECT '301','Balcony'       UNION ALL SELECT '302','Balcony'  UNION ALL SELECT '303','Balcony'
         UNION ALL  SELECT '304','Balcony'       UNION ALL SELECT '401','Balcony'  UNION ALL SELECT '402','Balcony'
         UNION ALL  SELECT '403','Balcony'
         UNION ALL  SELECT '303','Bathtub'       UNION ALL SELECT '304','Bathtub'  UNION ALL SELECT '401','Bathtub'
         UNION ALL  SELECT '402','Bathtub'       UNION ALL SELECT '403','Bathtub'  UNION ALL SELECT '404','Bathtub'
         UNION ALL  SELECT '202','Minibar'       UNION ALL SELECT '203','Minibar'  UNION ALL SELECT '204','Minibar'
         UNION ALL  SELECT '301','Minibar'       UNION ALL SELECT '302','Minibar'  UNION ALL SELECT '401','Minibar'
         UNION ALL  SELECT '402','Minibar'       UNION ALL SELECT '403','Minibar'  UNION ALL SELECT '404','Minibar'
         UNION ALL  SELECT '303','Kitchenette'   UNION ALL SELECT '304','Kitchenette'
         UNION ALL  SELECT '401','Safe'          UNION ALL SELECT '402','Safe'     UNION ALL SELECT '403','Safe'
         UNION ALL  SELECT '404','Safe'
       ) x
  JOIN room r    ON r.room_number = x.n
  JOIN amenity a ON a.name = x.a;

-- ---------------------------------------------------------------------
-- Clients (client 10 deliberately has no reservation)
-- ---------------------------------------------------------------------
INSERT INTO client (client_id, last_name, first_name, phone, email) VALUES
 ( 1, 'Ngono',   'Marie',       '+237677100101', 'marie.ngono@example.com'),
 ( 2, 'Tchoumi', 'Paul',        '+237699200202', 'paul.tchoumi@example.com'),
 ( 3, 'Mbarga',  'Esther',      '+237655300303', 'esther.mbarga@example.com'),
 ( 4, 'Fotso',   'Jean-Pierre', '+237670400404', 'jp.fotso@example.com'),
 ( 5, 'Kamga',   'Sandrine',    '+237690500505', 'sandrine.kamga@example.com'),
 ( 6, 'Etoundi', 'Patrick',     '+237677600606', 'patrick.etoundi@example.com'),
 ( 7, 'Nkeng',   'Alice',       '+237656700707', 'alice.nkeng@example.com'),
 ( 8, 'Biyong',  'Samuel',      '+237699800808', 'samuel.biyong@example.com'),
 ( 9, 'Dupont',  'Claire',      '+33612345678',  'claire.dupont@example.com'),
 (10, 'Abena',   'Grace',       '+237670900909', 'grace.abena@example.com');

-- ---------------------------------------------------------------------
-- Reservations (20)
-- ---------------------------------------------------------------------
INSERT INTO reservation (reservation_id, client_id, check_in_date, check_out_date, nb_guests, status, created_at, cancelled_at) VALUES
 -- completed stays
 ( 1, 1, '2026-03-02', '2026-03-05', 1, 'completed', '2026-02-10 09:15:00', NULL),
 ( 2, 6, '2026-03-05', '2026-03-07', 1, 'completed', '2026-02-20 14:30:00', NULL),  -- back-to-back with #1 on room 101
 ( 3, 2, '2026-03-10', '2026-03-14', 2, 'completed', '2026-02-25 10:00:00', NULL),
 ( 4, 3, '2026-04-18', '2026-04-22', 2, 'completed', '2026-03-30 16:45:00', NULL),
 ( 5, 4, '2026-05-01', '2026-05-04', 6, 'completed', '2026-04-10 11:20:00', NULL),  -- 2 rooms, guests = capacity
 ( 6, 1, '2026-06-12', '2026-06-15', 2, 'completed', '2026-05-20 08:50:00', NULL),
 ( 7, 5, '2026-06-20', '2026-06-27', 3, 'completed', '2026-05-28 19:05:00', NULL),
 ( 8, 2, '2026-07-08', '2026-07-10', 1, 'completed', '2026-06-30 13:10:00', NULL),
 ( 9, 6, '2026-07-15', '2026-07-18', 2, 'completed', '2026-07-01 09:00:00', NULL),
 (10, 7, '2026-08-05', '2026-08-09', 5, 'completed', '2026-07-12 17:25:00', NULL),  -- guests = capacity
 (11, 3, '2026-08-20', '2026-08-23', 2, 'completed', '2026-08-01 12:00:00', NULL),
 (12, 8, '2026-09-10', '2026-09-12', 1, 'completed', '2026-08-25 15:40:00', NULL),
 (13, 4, '2026-09-25', '2026-09-28', 3, 'completed', '2026-09-05 10:30:00', NULL),
 -- cancelled
 (14, 5, '2026-10-18', '2026-10-22', 2, 'cancelled', '2026-09-02 09:00:00', '2026-09-30 18:20:00'),  -- same room/dates as #19
 (15, 9, '2026-11-10', '2026-11-13', 2, 'cancelled', '2026-09-15 11:11:00', '2026-10-05 08:05:00'),
 -- pending
 (16, 8, '2026-10-16', '2026-10-19', 2, 'pending',   '2026-10-10 10:10:00', NULL),  -- starts the day #18 leaves room 204
 (17, 6, '2026-12-20', '2026-12-27', 1, 'pending',   '2026-10-12 09:45:00', NULL),
 -- confirmed
 (18, 9, '2026-10-12', '2026-10-16', 4, 'confirmed', '2026-09-20 14:00:00', NULL),  -- in house now, 2 rooms
 (19, 7, '2026-10-18', '2026-10-22', 2, 'confirmed', '2026-10-01 16:30:00', NULL),
 (20, 2, '2026-12-24', '2026-12-30', 3, 'confirmed', '2026-10-03 12:00:00', NULL);

-- Rooms of each reservation with the price frozen at booking time (BR-08).
-- Several prices are lower than today's room.base_price (rates rose later).
INSERT INTO reservation_room (reservation_id, room_id, nightly_price) VALUES
 ( 1,  1,  28000.00),   -- 101
 ( 2,  1,  28000.00),   -- 101 (back-to-back)
 ( 3,  5,  42000.00),   -- 202
 ( 4, 12, 110000.00),   -- 401
 ( 5, 10,  75000.00),   -- 303 (family, 4) + 301 (double, 2) = 6 places
 ( 5,  8,  45000.00),
 ( 6,  6,  45000.00),   -- 203
 ( 7, 13, 140000.00),   -- 402
 ( 8,  2,  30000.00),   -- 102
 ( 9,  9,  48000.00),   -- 302
 (10, 11,  85000.00),   -- 304 (family, 5)
 (11, 14, 115000.00),   -- 403
 (12,  3,  32000.00),   -- 103
 (13,  7,  52000.00),   -- 204
 (14,  5,  45000.00),   -- 202, cancelled: no effect on availability
 (15, 12, 120000.00),   -- 401, cancelled
 (16,  7,  52000.00),   -- 204, pending
 (17,  4,  32000.00),   -- 201, pending
 (18,  6,  45000.00),   -- 203 + 204 = 5 places for 4 guests, in house
 (18,  7,  52000.00),
 (19,  5,  45000.00),   -- 202, same dates as cancelled #14
 (20, 13, 150000.00);   -- 402

-- ---------------------------------------------------------------------
-- Services and opening hours (vary by weekday). day_of_week: 1 = Monday .. 7 = Sunday
-- ---------------------------------------------------------------------
INSERT INTO service (service_id, name, description, price, slot_minutes, slot_capacity) VALUES
 (1, 'Spa & Wellness',  'Massage and wellness treatments, 60-minute sessions',        25000.00, 60, 3),
 (2, 'Restaurant',      'Table at the hotel restaurant, set menu per guest',          12000.00, 60, 20),
 (3, 'Fitness Gym',     'Gym access with towel service',                               3000.00, 60, 8),
 (4, 'Airport Shuttle', 'Private transfer to or from the airport, per passenger',     15000.00, 60, 6);

INSERT INTO service_opening_hours (service_id, day_of_week, open_time, close_time) VALUES
 -- Spa: Mon-Fri 10:00-19:00, Sat 09:00-20:00, closed on Sunday (no row)
 (1, 1, '10:00', '19:00'), (1, 2, '10:00', '19:00'), (1, 3, '10:00', '19:00'),
 (1, 4, '10:00', '19:00'), (1, 5, '10:00', '19:00'), (1, 6, '09:00', '20:00'),
 -- Restaurant: Mon-Thu 12-22, Fri-Sat 12-23, Sun 11-21
 (2, 1, '12:00', '22:00'), (2, 2, '12:00', '22:00'), (2, 3, '12:00', '22:00'), (2, 4, '12:00', '22:00'),
 (2, 5, '12:00', '23:00'), (2, 6, '12:00', '23:00'), (2, 7, '11:00', '21:00'),
 -- Gym: Mon-Fri 06-22, weekend 07-20
 (3, 1, '06:00', '22:00'), (3, 2, '06:00', '22:00'), (3, 3, '06:00', '22:00'),
 (3, 4, '06:00', '22:00'), (3, 5, '06:00', '22:00'), (3, 6, '07:00', '20:00'), (3, 7, '07:00', '20:00'),
 -- Shuttle: Mon-Fri 05-23, weekend 06-22
 (4, 1, '05:00', '23:00'), (4, 2, '05:00', '23:00'), (4, 3, '05:00', '23:00'),
 (4, 4, '05:00', '23:00'), (4, 5, '05:00', '23:00'), (4, 6, '06:00', '22:00'), (4, 7, '06:00', '22:00');

-- Service bookings (BR-12): during the stay, inside opening hours, on the slot grid.
INSERT INTO service_booking (service_booking_id, reservation_id, service_id, slot_start, participants, status) VALUES
 ( 1,  3, 1, '2026-03-11 15:00:00', 2, 'booked'),     -- Wed spa
 ( 2,  3, 2, '2026-03-12 20:00:00', 2, 'booked'),     -- Thu dinner
 ( 3,  4, 1, '2026-04-20 11:00:00', 2, 'booked'),     -- Mon spa
 ( 4,  4, 3, '2026-04-21 07:00:00', 1, 'booked'),     -- Tue gym
 ( 5,  7, 2, '2026-06-23 19:00:00', 3, 'booked'),     -- Tue dinner
 ( 6,  7, 4, '2026-06-27 08:00:00', 3, 'booked'),     -- Sat shuttle on CHECK-OUT day
 ( 7, 10, 2, '2026-08-08 21:00:00', 5, 'booked'),     -- Sat late dinner (Sat closes at 23:00)
 ( 8, 10, 1, '2026-08-07 16:00:00', 2, 'booked'),     -- Fri spa
 ( 9, 11, 4, '2026-08-20 14:00:00', 2, 'booked'),     -- Thu shuttle on CHECK-IN day
 (10, 13, 3, '2026-09-26 07:00:00', 1, 'booked'),     -- Sat gym (weekend hours start at 07:00)
 (11, 18, 1, '2026-10-16 14:00:00', 2, 'booked'),     -- Fri spa, check-out day of #18 ...
 (12, 16, 1, '2026-10-16 14:00:00', 1, 'booked'),     -- ... + check-in day of #16 => slot full (3/3)
 (13,  9, 1, '2026-07-16 12:00:00', 2, 'cancelled');  -- cancelled booking (not invoiced)

-- ---------------------------------------------------------------------
-- Invoices: one per completed reservation (invoice_id = reservation_id).
-- Issued on the check-out day.
-- ---------------------------------------------------------------------
INSERT INTO invoice (invoice_id, reservation_id, issue_date, status)
SELECT reservation_id, reservation_id, check_out_date, 'due'
  FROM reservation WHERE status = 'completed';

-- accommodation lines: nights x frozen nightly price, 19.25 % VAT
INSERT INTO invoice_line (invoice_id, line_type, description, quantity, unit_price, tax_rate)
SELECT i.invoice_id, 'accommodation', CONCAT('Room ', ro.room_number, ' (', rt.name, ')'),
       DATEDIFF(r.check_out_date, r.check_in_date), rr.nightly_price, 0.1925
  FROM invoice i
  JOIN reservation r       ON r.reservation_id  = i.reservation_id
  JOIN reservation_room rr ON rr.reservation_id = r.reservation_id
  JOIN room ro             ON ro.room_id        = rr.room_id
  JOIN room_type rt        ON rt.room_type_id   = ro.room_type_id;

-- service lines: every non-cancelled booking of an invoiced stay, billed once
INSERT INTO invoice_line (invoice_id, line_type, description, quantity, unit_price, tax_rate, service_booking_id)
SELECT i.invoice_id, 'service', CONCAT(s.name, ' ', DATE_FORMAT(sb.slot_start, '%d/%m/%Y %H:%i')),
       sb.participants, s.price, 0.1925, sb.service_booking_id
  FROM service_booking sb
  JOIN invoice i ON i.reservation_id = sb.reservation_id
  JOIN service s ON s.service_id     = sb.service_id
 WHERE sb.status = 'booked';

-- miscellaneous charges
INSERT INTO invoice_line (invoice_id, line_type, description, quantity, unit_price, tax_rate) VALUES
 ( 3, 'miscellaneous', 'Minibar',                 1,  6500.00, 0.1925),
 ( 4, 'miscellaneous', 'Late check-out',          1, 20000.00, 0.1925),
 ( 7, 'miscellaneous', 'Laundry',                 3,  2500.00, 0.1925),
 (10, 'miscellaneous', 'Extra bed',               4, 10000.00, 0.1925),
 (12, 'miscellaneous', 'Tourist tax (0 % VAT)',   2,  1000.00, 0.0000);

-- ---------------------------------------------------------------------
-- Payments, ALWAYS through sp_record_payment (updates the invoice status, BR-15)
--   paid           : 1, 2, 3 (2 payments), 4, 6, 8, 9
--   partially paid : 5, 7, 10
--   due            : 11, 12, 13 (no payment)
-- ---------------------------------------------------------------------
CALL sp_record_payment( 1, fn_invoice_total(1), 'card',          '2026-03-05 10:30:00', @s, @b);
CALL sp_record_payment( 2, fn_invoice_total(2), 'cash',          '2026-03-07 09:50:00', @s, @b);
CALL sp_record_payment( 3, ROUND(fn_invoice_total(3) * 0.50, 2), 'bank_transfer', '2026-03-01 12:00:00', @s, @b);  -- deposit
CALL sp_record_payment( 3, fn_invoice_total(3) - fn_invoice_paid(3), 'cash',      '2026-03-14 11:05:00', @s, @b);  -- balance
CALL sp_record_payment( 4, fn_invoice_total(4), 'mobile_money',  '2026-04-22 10:15:00', @s, @b);
CALL sp_record_payment( 5, ROUND(fn_invoice_total(5) * 0.50, 2), 'bank_transfer', '2026-05-04 09:30:00', @s, @b);  -- half only
CALL sp_record_payment( 6, fn_invoice_total(6), 'card',          '2026-06-15 10:40:00', @s, @b);
CALL sp_record_payment( 7, ROUND(fn_invoice_total(7) * 0.40, 2), 'card',          '2026-06-20 18:00:00', @s, @b);  -- deposit
CALL sp_record_payment( 7, ROUND(fn_invoice_total(7) * 0.30, 2), 'mobile_money',  '2026-06-27 10:00:00', @s, @b);  -- 70 % so far
CALL sp_record_payment( 8, fn_invoice_total(8), 'cash',          '2026-07-10 09:20:00', @s, @b);
CALL sp_record_payment( 9, fn_invoice_total(9), 'mobile_money',  '2026-07-18 10:05:00', @s, @b);
CALL sp_record_payment(10, ROUND(fn_invoice_total(10) * 0.30, 2), 'mobile_money', '2026-08-09 08:45:00', @s, @b);

-- ---------------------------------------------------------------------
-- Reviews: completed reservations only (BR-16), date >= check-out (BR-17)
-- Ratings 5, 4, 5, 3, 1, 2, 4. Completed stays 2, 5, 6, 8, 12, 13 have none.
-- ---------------------------------------------------------------------
INSERT INTO review (reservation_id, rating, comment_text, review_date) VALUES
 ( 1, 5, 'Spotless room and very friendly staff.',               '2026-03-06'),
 ( 3, 4, 'Great stay, breakfast could be faster.',               '2026-03-14'),  -- same day as check-out
 ( 4, 5, 'Superb suite, perfect for our anniversary.',           '2026-04-23'),
 ( 7, 3, NULL,                                                   '2026-06-28'),  -- optional comment omitted
 ( 9, 1, 'Air conditioning was broken for the whole stay.',      '2026-07-19'),
 (10, 2, 'Family room too noisy at night.',                      '2026-08-10'),
 (11, 4, 'Lovely suite and a great spa.',                        '2026-08-24');

-- ---------------------------------------------------------------------
-- Quick summary of what was loaded (compare with section 3.4)
-- ---------------------------------------------------------------------
SELECT 'rooms'        AS entity, COUNT(*) AS loaded FROM room
UNION ALL SELECT 'room types',   COUNT(*) FROM room_type
UNION ALL SELECT 'clients',      COUNT(*) FROM client
UNION ALL SELECT 'reservations', COUNT(*) FROM reservation
UNION ALL SELECT 'services',     COUNT(*) FROM service
UNION ALL SELECT 'invoices',     COUNT(*) FROM invoice
UNION ALL SELECT 'payments',     COUNT(*) FROM payment
UNION ALL SELECT 'reviews',      COUNT(*) FROM review;

SELECT 'reservation status' AS what, status AS value, COUNT(*) AS n FROM reservation GROUP BY status
UNION ALL SELECT 'invoice status', status, COUNT(*) FROM invoice GROUP BY status
UNION ALL SELECT 'room status', operational_status, COUNT(*) FROM room GROUP BY operational_status;
