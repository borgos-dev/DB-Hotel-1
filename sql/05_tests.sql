-- =====================================================================
-- 05_tests.sql  (L5)  Violation attempts that MUST be rejected
-- ---------------------------------------------------------------------
-- A violation attempt normally aborts a mysql script. To keep this file
-- runnable from top to bottom WITHOUT errors, every attempt goes through the
-- helper procedure sp_expect_error(), which executes the statement, catches
-- the error and records the outcome in a temporary table:
--     PASS = the statement was rejected AND the error message contains the
--            expected marker (a business-rule id such as 'BR-07', or the name
--            of the violated CHECK / UNIQUE / FOREIGN KEY constraint)
--     FAIL = the statement was accepted, or rejected for another reason
-- At the end the script prints the full log, a summary, and verifies that the
-- attempts changed nothing (row counts, audit views).
--
-- Requires 01..03 to have been run. The helper procedure and the temporary
-- table are dropped at the end, so the database is left as 03 produced it.
-- Run with:  mysql -t < 05_tests.sql
-- =====================================================================

USE hotel_db;

-- snapshot used by the "nothing changed" check at the end
SET @n_res  = (SELECT COUNT(*) FROM reservation);
SET @n_rr   = (SELECT COUNT(*) FROM reservation_room);
SET @n_sb   = (SELECT COUNT(*) FROM service_booking);
SET @n_pay  = (SELECT COUNT(*) FROM payment);
SET @n_rev  = (SELECT COUNT(*) FROM review);
SET @n_cli  = (SELECT COUNT(*) FROM client);
SET @sum_paid = (SELECT SUM(amount) FROM payment);
SET @price_r1 = (SELECT nightly_price FROM reservation_room WHERE reservation_id = 1 AND room_id = 1);

DROP TEMPORARY TABLE IF EXISTS test_log;
CREATE TEMPORARY TABLE test_log (
    test_no    INT AUTO_INCREMENT PRIMARY KEY,
    rule       VARCHAR(12)  NOT NULL,
    scenario   VARCHAR(160) NOT NULL,
    outcome    VARCHAR(4)   NOT NULL,
    error_text VARCHAR(255) NULL
);

DROP PROCEDURE IF EXISTS sp_expect_error;
DELIMITER $$
CREATE PROCEDURE sp_expect_error(IN p_rule VARCHAR(12), IN p_scenario VARCHAR(160),
                                 IN p_marker VARCHAR(60), IN p_sql TEXT)
BEGIN
    DECLARE v_failed INT DEFAULT 0;
    DECLARE v_msg    TEXT DEFAULT NULL;

    -- SQLWARNING too: in strict mode an invalid ENUM value is an error whose
    -- SQLSTATE (01000, "data truncated") belongs to the warning class.
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION, SQLWARNING
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_failed = 1;
    END;

    SET @sql_under_test = p_sql;
    PREPARE stmt FROM @sql_under_test;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;

    INSERT INTO test_log (rule, scenario, outcome, error_text)
    VALUES (p_rule, p_scenario,
            IF(v_failed = 1 AND v_msg LIKE CONCAT('%', p_marker, '%'), 'PASS', 'FAIL'),
            IF(v_failed = 1, LEFT(v_msg, 255), 'statement was ACCEPTED'));
END$$
DELIMITER ;

-- =====================================================================
-- BR-05  check-out after check-in; guests within total capacity
-- =====================================================================
CALL sp_expect_error('BR-05', 'check-out equal to check-in', 'chk_reservation_dates',
 "INSERT INTO reservation (client_id, check_in_date, check_out_date, nb_guests) VALUES (1, '2027-01-10', '2027-01-10', 1)");

CALL sp_expect_error('BR-05', 'check-out before check-in', 'chk_reservation_dates',
 "INSERT INTO reservation (client_id, check_in_date, check_out_date, nb_guests) VALUES (1, '2027-01-10', '2027-01-05', 1)");

CALL sp_expect_error('BR-05', 'zero guests', 'chk_reservation_guests',
 "INSERT INTO reservation (client_id, check_in_date, check_out_date, nb_guests) VALUES (1, '2027-01-10', '2027-01-12', 0)");

CALL sp_expect_error('BR-05', 'dates inverted through the booking procedure', 'BR-05',
 "CALL sp_create_reservation(1, '2027-01-10', '2027-01-09', 1, '[1]', @new_id)");

CALL sp_expect_error('BR-05', '2 guests in single room 101 (capacity 1)', 'BR-05',
 "CALL sp_create_reservation(1, '2027-02-01', '2027-02-03', 2, '[1]', @new_id)");

CALL sp_expect_error('BR-05', '3 guests in two single rooms 102 + 201 (total capacity 2)', 'BR-05',
 "CALL sp_create_reservation(1, '2027-02-01', '2027-02-03', 3, '[2, 4]', @new_id)");

CALL sp_expect_error('BR-05', 'raise guests of pending #17 to 10 (room 201 holds 1)', 'BR-05',
 "UPDATE reservation SET nb_guests = 10 WHERE reservation_id = 17");

CALL sp_expect_error('BR-05', 'remove room 204 from in-house #18 (203 alone holds 2 < 4 guests)', 'BR-05',
 "DELETE FROM reservation_room WHERE reservation_id = 18 AND room_id = 7");

-- =====================================================================
-- BR-07  no overlapping non-cancelled reservations on a room
-- =====================================================================
CALL sp_expect_error('BR-07', 'book room 202 over confirmed #19 (18-22 Oct) via procedure', 'BR-07',
 "CALL sp_create_reservation(1, '2026-10-19', '2026-10-21', 2, '[5]', @new_id)");

CALL sp_expect_error('BR-07', 'book room 202 for a period containing confirmed #19', 'BR-07',
 "CALL sp_create_reservation(1, '2026-10-01', '2026-11-30', 2, '[5]', @new_id)");

CALL sp_expect_error('BR-07', 'add room 202 to pending #16 (16-19 Oct) which overlaps #19', 'BR-07',
 "INSERT INTO reservation_room (reservation_id, room_id, nightly_price) VALUES (16, 5, 45000.00)");

CALL sp_expect_error('BR-07', 'one night inside in-house #18 on room 203 (13-14 Oct)', 'BR-07',
 "CALL sp_create_reservation(1, '2026-10-13', '2026-10-14', 1, '[6]', @new_id)");

CALL sp_expect_error('BR-07', 'move pending #16 one day earlier: collides with #18 on room 204', 'BR-07',
 "UPDATE reservation SET check_in_date = '2026-10-15' WHERE reservation_id = 16");

CALL sp_expect_error('BR-07', 'reopen cancelled #14 (its room 202 was resold to #19)', 'BR-07',
 "UPDATE reservation SET status = 'pending', cancelled_at = NULL WHERE reservation_id = 14");

CALL sp_expect_error('BR-07', 'change the room of a reservation line in place (must be delete + insert)', 'BR-07',
 "UPDATE reservation_room SET room_id = 8 WHERE reservation_id = 17 AND room_id = 4");

-- =====================================================================
-- BR-08  nightly price frozen at booking time
-- =====================================================================
CALL sp_expect_error('BR-08', 'change the frozen nightly price of a reservation line', 'BR-08',
 "UPDATE reservation_room SET nightly_price = 1000.00 WHERE reservation_id = 1 AND room_id = 1");

-- =====================================================================
-- BR-09  client identity: unique and well-formed email / phone
-- =====================================================================
CALL sp_expect_error('BR-09', 'duplicate email (different case)', 'uq_client_email',
 "INSERT INTO client (last_name, first_name, phone, email) VALUES ('Test', 'One', '+237600000001', 'MARIE.NGONO@example.com')");

CALL sp_expect_error('BR-09', 'duplicate phone number', 'uq_client_phone',
 "INSERT INTO client (last_name, first_name, phone, email) VALUES ('Test', 'Two', '+237677100101', 'test.two@example.com')");

CALL sp_expect_error('BR-09', 'phone not in canonical +digits format', 'chk_client_phone',
 "INSERT INTO client (last_name, first_name, phone, email) VALUES ('Test', 'Three', '677 10 01 01', 'test.three@example.com')");

CALL sp_expect_error('BR-09', 'malformed email', 'chk_client_email',
 "INSERT INTO client (last_name, first_name, phone, email) VALUES ('Test', 'Four', '+237600000004', 'not-an-email')");

-- =====================================================================
-- BR-01 / BR-02  rooms
-- =====================================================================
CALL sp_expect_error('BR-01', 'duplicate room number', 'uq_room_number',
 "INSERT INTO room (room_number, floor_number, room_type_id, max_capacity, base_price) VALUES ('101', 1, 1, 1, 30000)");

CALL sp_expect_error('BR-01', 'room with capacity 0', 'chk_room_capacity',
 "INSERT INTO room (room_number, floor_number, room_type_id, max_capacity, base_price) VALUES ('999', 9, 1, 0, 30000)");

CALL sp_expect_error('BR-01', 'room with a negative price', 'chk_room_price',
 "INSERT INTO room (room_number, floor_number, room_type_id, max_capacity, base_price) VALUES ('998', 9, 1, 1, -5)");

CALL sp_expect_error('BR-03', 'operational status outside the allowed list', 'Data truncated',
 "UPDATE room SET operational_status = 'haunted' WHERE room_id = 1");

-- =====================================================================
-- BR-06  cancellation date consistent with the status
-- =====================================================================
CALL sp_expect_error('BR-06', 'cancelled reservation without cancellation date', 'chk_reservation_cancel',
 "INSERT INTO reservation (client_id, check_in_date, check_out_date, nb_guests, status, cancelled_at) VALUES (1, '2027-03-01', '2027-03-03', 1, 'cancelled', NULL)");

CALL sp_expect_error('BR-06', 'cancellation date on a non-cancelled reservation', 'chk_reservation_cancel',
 "UPDATE reservation SET cancelled_at = '2026-10-01 10:00:00' WHERE reservation_id = 16");

-- =====================================================================
-- BR-10 / delete rules: history cannot be deleted from under its owners
-- =====================================================================
CALL sp_expect_error('BR-10', 'delete a client that has reservations (ON DELETE RESTRICT)', 'foreign key constraint',
 "DELETE FROM client WHERE client_id = 1");

CALL sp_expect_error('BR-01', 'delete a room that was booked (ON DELETE RESTRICT)', 'foreign key constraint',
 "DELETE FROM room WHERE room_id = 1");

CALL sp_expect_error('BR-13', 'delete a reservation that has an invoice (ON DELETE RESTRICT)', 'foreign key constraint',
 "DELETE FROM reservation WHERE reservation_id = 1");

-- =====================================================================
-- BR-12  service bookings
-- =====================================================================
CALL sp_expect_error('BR-12', 'slot before the stay of #18 (12-16 Oct)', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 3, '2026-10-11 10:00:00', 1)");

CALL sp_expect_error('BR-12', 'slot after the stay of #18', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 3, '2026-10-17 10:00:00', 1)");

CALL sp_expect_error('BR-12', 'spa on a Sunday (closed) during stay #20', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (20, 1, '2026-12-27 15:00:00', 1)");

CALL sp_expect_error('BR-12', 'spa slot before opening time (08:00, opens at 10:00)', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 1, '2026-10-14 08:00:00', 1)");

CALL sp_expect_error('BR-12', 'spa slot ending after closing time (19:00-20:00, closes at 19:00)', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 1, '2026-10-14 19:00:00', 1)");

CALL sp_expect_error('BR-12', 'slot start not on the 60-minute grid (14:30)', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 1, '2026-10-14 14:30:00', 1)");

CALL sp_expect_error('BR-12', 'spa slot of 16 Oct 14:00 is full (3 of 3 places): one more guest', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 1, '2026-10-16 14:00:00', 1)");

CALL sp_expect_error('BR-12', 'service booked on a cancelled reservation (#14)', 'BR-12',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (14, 3, '2026-10-19 10:00:00', 1)");

CALL sp_expect_error('BR-12', 'raise the participants of an existing booking beyond the slot capacity', 'BR-12',
 "UPDATE service_booking SET participants = 3 WHERE service_booking_id = 12");

CALL sp_expect_error('BR-12', 'zero participants', 'chk_service_booking_participants',
 "INSERT INTO service_booking (reservation_id, service_id, slot_start, participants) VALUES (18, 3, '2026-10-14 10:00:00', 0)");

CALL sp_expect_error('BR-11', 'opening interval with close time before open time', 'chk_opening_times',
 "INSERT INTO service_opening_hours (service_id, day_of_week, open_time, close_time) VALUES (1, 7, '18:00', '10:00')");

-- =====================================================================
-- BR-13 / BR-14 / BR-15  invoices and payments
-- =====================================================================
CALL sp_expect_error('BR-13', 'second invoice for the same reservation', 'uq_invoice_reservation',
 "INSERT INTO invoice (reservation_id, issue_date) VALUES (1, '2026-03-05')");

CALL sp_expect_error('BR-13', 'invoice line with zero quantity', 'chk_invoice_line_qty',
 "INSERT INTO invoice_line (invoice_id, line_type, description, quantity, unit_price, tax_rate) VALUES (13, 'miscellaneous', 'x', 0, 100, 0)");

CALL sp_expect_error('BR-13', 'invoice line with a tax rate above 100 %', 'chk_invoice_line_tax',
 "INSERT INTO invoice_line (invoice_id, line_type, description, quantity, unit_price, tax_rate) VALUES (13, 'miscellaneous', 'x', 1, 100, 1.5)");

CALL sp_expect_error('BR-13', 'service line without a service booking', 'chk_invoice_line_link',
 "INSERT INTO invoice_line (invoice_id, line_type, description, quantity, unit_price, tax_rate) VALUES (13, 'service', 'x', 1, 100, 0)");

CALL sp_expect_error('BR-14', 'negative payment inserted directly', 'chk_payment_amount',
 "INSERT INTO payment (invoice_id, amount, method) VALUES (11, -50.00, 'cash')");

CALL sp_expect_error('BR-14', 'zero payment through the procedure', 'BR-14',
 "CALL sp_record_payment(11, 0, 'cash', NULL, @st, @bal)");

CALL sp_expect_error('BR-14', 'payment method outside the allowed list', 'Data truncated',
 "CALL sp_record_payment(11, 1000, 'cheque', NULL, @st, @bal)");

CALL sp_expect_error('BR-15', 'payment above the outstanding balance of invoice 11', 'BR-15',
 "CALL sp_record_payment(11, 999999999, 'cash', NULL, @st, @bal)");

CALL sp_expect_error('BR-15', 'payment on a fully paid invoice (#1)', 'BR-15',
 "CALL sp_record_payment(1, 1, 'cash', NULL, @st, @bal)");

CALL sp_expect_error('BR-13', 'payment on an unknown invoice', 'BR-13',
 "CALL sp_record_payment(9999, 1000, 'cash', NULL, @st, @bal)");

-- =====================================================================
-- BR-16 / BR-17  reviews
-- =====================================================================
CALL sp_expect_error('BR-16', 'review of a pending reservation (#17)', 'BR-16',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (17, 4, '2026-12-28')");

CALL sp_expect_error('BR-16', 'review of a confirmed in-house reservation (#18)', 'BR-16',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (18, 4, '2026-10-17')");

CALL sp_expect_error('BR-16', 'review of a cancelled reservation (#14)', 'BR-16',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (14, 4, '2026-10-23')");

CALL sp_expect_error('BR-16', 'second review for reservation #1 (at most one per reservation)', 'uq_review_reservation',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (1, 3, '2026-03-10')");

CALL sp_expect_error('BR-16', 'review of an unknown reservation', 'foreign key constraint',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (9999, 3, '2026-03-10')");

CALL sp_expect_error('BR-16', 'cancel a reservation that already has a review', 'BR-16',
 "UPDATE reservation SET status = 'cancelled' WHERE reservation_id = 1");

CALL sp_expect_error('BR-17', 'review dated before the check-out of #12 (12 Sep)', 'BR-17',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (12, 4, '2026-09-11')");

CALL sp_expect_error('BR-17', 'move a review before the check-out date', 'BR-17',
 "UPDATE review SET review_date = '2026-03-01' WHERE reservation_id = 1");

CALL sp_expect_error('BR-17', 'rating 0', 'chk_review_rating',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (12, 0, '2026-09-13')");

CALL sp_expect_error('BR-17', 'rating 6', 'chk_review_rating',
 "INSERT INTO review (reservation_id, rating, review_date) VALUES (12, 6, '2026-09-13')");

-- =====================================================================
-- Positive controls: valid operations that the triggers must NOT block.
-- Run inside a transaction that is rolled back, so the data is untouched.
-- =====================================================================
START TRANSACTION;

-- BR-07: cancelling #19 frees room 202 at once, so the same nights can be sold again
UPDATE reservation SET status = 'cancelled' WHERE reservation_id = 19;
SET @stamped = (SELECT cancelled_at IS NOT NULL FROM reservation WHERE reservation_id = 19);

INSERT INTO reservation (client_id, check_in_date, check_out_date, nb_guests, status)
VALUES (1, '2026-10-18', '2026-10-22', 2, 'pending');
SET @tmp_res = LAST_INSERT_ID();
INSERT INTO reservation_room (reservation_id, room_id, nightly_price) VALUES (@tmp_res, 5, 45000.00);
SET @resold = (SELECT COUNT(*) FROM reservation_room WHERE reservation_id = @tmp_res AND room_id = 5);

-- BR-08: a later catalogue price change does not touch the frozen price of an old stay
UPDATE room SET base_price = base_price * 2 WHERE room_id = 1;
SET @price_after = (SELECT nightly_price FROM reservation_room WHERE reservation_id = 1 AND room_id = 1);

ROLLBACK;

INSERT INTO test_log (rule, scenario, outcome, error_text) VALUES
 ('BR-07', 'positive: a cancelled reservation frees its room (re-sold at once) and gets cancelled_at',
  IF(@stamped = 1 AND @resold = 1, 'PASS', 'FAIL'), 'accepted as expected, then rolled back'),
 ('BR-08', 'positive: doubling the catalogue price leaves the frozen nightly price unchanged',
  IF(@price_after = @price_r1, 'PASS', 'FAIL'), 'accepted as expected, then rolled back');

-- =====================================================================
-- Results
-- =====================================================================
SELECT test_no, rule, outcome, scenario, error_text FROM test_log ORDER BY test_no;

SELECT outcome, COUNT(*) AS nb_tests FROM test_log GROUP BY outcome ORDER BY outcome DESC;

-- Nothing may have changed, and the audit views must be empty.
SELECT 'attempts changed nothing' AS check_name,
       IF(@n_res = (SELECT COUNT(*) FROM reservation)
      AND @n_rr  = (SELECT COUNT(*) FROM reservation_room)
      AND @n_sb  = (SELECT COUNT(*) FROM service_booking)
      AND @n_pay = (SELECT COUNT(*) FROM payment)
      AND @n_rev = (SELECT COUNT(*) FROM review)
      AND @n_cli = (SELECT COUNT(*) FROM client)
      AND @sum_paid = (SELECT SUM(amount) FROM payment)
      AND @price_r1 = (SELECT nightly_price FROM reservation_room WHERE reservation_id = 1 AND room_id = 1),
          'PASS', 'FAIL') AS outcome
UNION ALL
SELECT 'BR-05 audit: no reservation exceeds its capacity',
       IF((SELECT COUNT(*) FROM v_reservation_capacity_audit) = 0, 'PASS', 'FAIL')
UNION ALL
SELECT 'BR-15 audit: stored invoice status = status derived from payments',
       IF((SELECT COUNT(*) FROM v_invoice_status_audit) = 0, 'PASS', 'FAIL')
UNION ALL
SELECT 'BR-07 audit: no two non-cancelled reservations overlap on a room',
       IF((SELECT COUNT(*)
             FROM reservation_room a
             JOIN reservation ra     ON ra.reservation_id = a.reservation_id
             JOIN reservation_room b ON b.room_id = a.room_id AND b.reservation_id > a.reservation_id
             JOIN reservation rb     ON rb.reservation_id = b.reservation_id
            WHERE ra.status <> 'cancelled' AND rb.status <> 'cancelled'
              AND ra.check_in_date < rb.check_out_date AND rb.check_in_date < ra.check_out_date) = 0,
          'PASS', 'FAIL');

DROP PROCEDURE IF EXISTS sp_expect_error;
DROP TEMPORARY TABLE IF EXISTS test_log;
