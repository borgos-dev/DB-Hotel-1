-- =====================================================================
-- 02_constraints.sql  (L4)  Advanced business constraints
-- ---------------------------------------------------------------------
-- Rules that span several tables cannot be written as CHECK / FK in MySQL,
-- so they are enforced here:
--   BR-07  no overlapping non-cancelled reservations on the same room
--   BR-12  service booked during the stay, inside opening hours, within
--          the slot capacity
--   BR-15  payment recorded in a transaction that updates invoice status
--   BR-05  (2nd half) guests <= total capacity of the reserved rooms
--   BR-08  nightly price frozen once booked
--   BR-16 / BR-17  review only for a completed reservation, dated on or
--          after check-out
--
-- Concurrency: the triggers take a row lock (SELECT ... FOR UPDATE) on the
-- room / service being booked, then read the competing bookings with a
-- locking read (FOR SHARE), which sees the latest COMMITTED data. Two sessions
-- therefore cannot both pass the check for the same room (or slot) and then
-- both insert. (Verified with two concurrent sessions, see README.)
--
-- All violations raise SQLSTATE '45000' with a message starting with the
-- business-rule identifier (e.g. 'BR-07: ...').
-- Run with the mysql client (it understands DELIMITER).
-- =====================================================================

USE hotel_db;

DELIMITER $$

-- ---------------------------------------------------------------------
-- Helper functions (billing)
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_invoice_total(p_invoice_id INT UNSIGNED)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(12,2) DEFAULT 0;
    SELECT COALESCE(SUM(line_subtotal + line_tax), 0) INTO v_total
      FROM invoice_line WHERE invoice_id = p_invoice_id;
    RETURN v_total;
END$$

CREATE FUNCTION fn_invoice_paid(p_invoice_id INT UNSIGNED)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_paid DECIMAL(12,2) DEFAULT 0;
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
      FROM payment WHERE invoice_id = p_invoice_id;
    RETURN v_paid;
END$$

-- ---------------------------------------------------------------------
-- BR-07  Room availability
-- Two reservations overlap on a room when their night ranges
-- [check_in, check_out) intersect:  a.in < b.out  AND  b.in < a.out.
-- Back-to-back stays (check-out day = next check-in day) are allowed.
-- Cancelled reservations are ignored: they free their rooms at once.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_assert_room_free(
    IN p_room_id        SMALLINT UNSIGNED,
    IN p_reservation_id INT UNSIGNED,
    IN p_check_in       DATE,
    IN p_check_out      DATE)
BEGIN
    DECLARE v_lock   SMALLINT UNSIGNED DEFAULT NULL;
    DECLARE v_other  INT UNSIGNED      DEFAULT NULL;
    DECLARE v_number VARCHAR(10)       DEFAULT NULL;
    DECLARE v_msg    VARCHAR(128);

    -- serialise concurrent bookings of the same room
    SELECT room_id INTO v_lock FROM room WHERE room_id = p_room_id FOR UPDATE;

    SELECT rr.reservation_id, ro.room_number INTO v_other, v_number
      FROM reservation_room rr
      JOIN reservation r ON r.reservation_id = rr.reservation_id
      JOIN room ro       ON ro.room_id       = rr.room_id
     WHERE rr.room_id = p_room_id
       AND rr.reservation_id <> p_reservation_id
       AND r.status <> 'cancelled'
       AND r.check_in_date  < p_check_out
       AND r.check_out_date > p_check_in
     LIMIT 1
       FOR SHARE;   -- locking read: sees the latest COMMITTED data, not the transaction snapshot

    IF v_other IS NOT NULL THEN
        SET v_msg = CONCAT('BR-07: room ', v_number,
                ' is already booked on overlapping nights (reservation #', v_other, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

CREATE TRIGGER trg_reservation_room_bi
BEFORE INSERT ON reservation_room
FOR EACH ROW
BEGIN
    DECLARE v_in     DATE        DEFAULT NULL;
    DECLARE v_out    DATE        DEFAULT NULL;
    DECLARE v_status VARCHAR(20) DEFAULT NULL;

    SELECT check_in_date, check_out_date, status INTO v_in, v_out, v_status
      FROM reservation WHERE reservation_id = NEW.reservation_id;

    IF v_status IS NOT NULL AND v_status <> 'cancelled' THEN
        CALL sp_assert_room_free(NEW.room_id, NEW.reservation_id, v_in, v_out);
    END IF;
END$$

-- reservation_room rows are immutable: a different room means a different
-- price snapshot (BR-08) and a new availability check (BR-07), i.e. DELETE + INSERT.
CREATE TRIGGER trg_reservation_room_bu
BEFORE UPDATE ON reservation_room
FOR EACH ROW
BEGIN
    IF NEW.nightly_price <> OLD.nightly_price THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-08: the nightly price is frozen at booking time and cannot be changed';
    END IF;
    IF NEW.room_id <> OLD.room_id OR NEW.reservation_id <> OLD.reservation_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-07: to change the room, delete the line and insert a new one';
    END IF;
END$$

-- BR-05 (capacity): a room cannot be removed if the remaining rooms can no
-- longer hold the guests. (FK cascades do not fire triggers, so deleting a
-- whole reservation is not affected.)
CREATE TRIGGER trg_reservation_room_bd
BEFORE DELETE ON reservation_room
FOR EACH ROW
BEGIN
    DECLARE v_status   VARCHAR(20) DEFAULT NULL;
    DECLARE v_guests   INT         DEFAULT 0;
    DECLARE v_cap_left INT         DEFAULT 0;

    SELECT status, nb_guests INTO v_status, v_guests
      FROM reservation WHERE reservation_id = OLD.reservation_id;

    IF v_status IS NOT NULL AND v_status <> 'cancelled' THEN
        SELECT COALESCE(SUM(ro.max_capacity), 0) INTO v_cap_left
          FROM reservation_room rr JOIN room ro ON ro.room_id = rr.room_id
         WHERE rr.reservation_id = OLD.reservation_id AND rr.room_id <> OLD.room_id;
        IF v_cap_left < v_guests THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR-05: removing this room leaves less capacity than the number of guests';
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- Reservation updates: BR-07 (re-dating), BR-05 (capacity), BR-06
-- (cancellation date), BR-16/17 (reviewed stays are frozen).
-- A cancelled reservation is terminal: re-opening it would silently
-- re-claim rooms that may have been sold since (BR-07).
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_reservation_bu
BEFORE UPDATE ON reservation
FOR EACH ROW
BEGIN
    DECLARE v_cap     INT          DEFAULT 0;
    DECLARE v_locked  INT          DEFAULT 0;
    DECLARE v_reviews INT          DEFAULT 0;
    DECLARE v_room    VARCHAR(10)  DEFAULT NULL;
    DECLARE v_other   INT UNSIGNED DEFAULT NULL;
    DECLARE v_msg     VARCHAR(128);

    IF OLD.status = 'cancelled'
       AND (NEW.status <> 'cancelled'
            OR NEW.check_in_date <> OLD.check_in_date
            OR NEW.check_out_date <> OLD.check_out_date) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-07: a cancelled reservation cannot be reopened or re-dated; create a new one';
    END IF;

    -- BR-06: stamp the cancellation date automatically
    IF NEW.status = 'cancelled' AND OLD.status <> 'cancelled' AND NEW.cancelled_at IS NULL THEN
        SET NEW.cancelled_at = NOW();
    END IF;

    -- BR-16 / BR-17: once reviewed, the stay must stay completed and keep its check-out date
    IF NEW.status <> OLD.status OR NEW.check_out_date <> OLD.check_out_date THEN
        SELECT COUNT(*) INTO v_reviews FROM review WHERE reservation_id = NEW.reservation_id;
        IF v_reviews > 0 AND (NEW.status <> 'completed' OR NEW.check_out_date <> OLD.check_out_date) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR-16: a reviewed reservation must remain completed with the same check-out date';
        END IF;
    END IF;

    IF NEW.status <> 'cancelled' THEN
        -- BR-07: moving the dates must not collide with another booking of any of its rooms
        IF NEW.check_in_date <> OLD.check_in_date OR NEW.check_out_date <> OLD.check_out_date THEN
            SELECT COUNT(*) INTO v_locked FROM room
             WHERE room_id IN (SELECT room_id FROM reservation_room
                                WHERE reservation_id = NEW.reservation_id) FOR UPDATE;

            SELECT ro.room_number, oth.reservation_id INTO v_room, v_other
              FROM reservation_room mine
              JOIN reservation_room oth ON oth.room_id = mine.room_id
                                       AND oth.reservation_id <> mine.reservation_id
              JOIN reservation r        ON r.reservation_id = oth.reservation_id
              JOIN room ro              ON ro.room_id = mine.room_id
             WHERE mine.reservation_id = NEW.reservation_id
               AND r.status <> 'cancelled'
               AND r.check_in_date  < NEW.check_out_date
               AND r.check_out_date > NEW.check_in_date
             LIMIT 1
               FOR SHARE;

            IF v_other IS NOT NULL THEN
                SET v_msg = CONCAT('BR-07: room ', v_room,
                        ' is already booked on overlapping nights (reservation #', v_other, ')');
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
        END IF;

        -- BR-05: guests must fit in the reserved rooms
        IF NEW.nb_guests <> OLD.nb_guests OR NEW.status <> OLD.status THEN
            SELECT COALESCE(SUM(ro.max_capacity), 0) INTO v_cap
              FROM reservation_room rr JOIN room ro ON ro.room_id = rr.room_id
             WHERE rr.reservation_id = NEW.reservation_id;
            IF NEW.nb_guests > v_cap THEN
                SET v_msg = CONCAT('BR-05: ', NEW.nb_guests,
                        ' guests exceed the total capacity of the reserved rooms (', v_cap, ')');
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- BR-05 + BR-07 + BR-08  Atomic creation of a reservation with its rooms.
-- MySQL has no deferred constraints, so "guests <= total capacity" cannot
-- be checked row by row while the rooms are being inserted. This procedure
-- is the supported entry point: it validates everything, snapshots each
-- room price (BR-08) and inserts the reservation and its rooms in ONE
-- transaction (the BR-07 trigger runs on every room line).
--   p_room_ids: JSON array of room ids, e.g. '[10, 8]'
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_create_reservation(
    IN  p_client_id      INT UNSIGNED,
    IN  p_check_in       DATE,
    IN  p_check_out      DATE,
    IN  p_guests         SMALLINT UNSIGNED,
    IN  p_room_ids       JSON,
    OUT p_reservation_id INT UNSIGNED)
BEGIN
    DECLARE v_requested INT DEFAULT 0;
    DECLARE v_found     INT DEFAULT 0;
    DECLARE v_cap       INT DEFAULT 0;
    DECLARE v_msg       VARCHAR(128);
    DECLARE v_done      INT DEFAULT 0;
    DECLARE v_room_id   SMALLINT UNSIGNED;
    DECLARE v_price     DECIMAL(10,2);

    -- The rooms are read through a cursor and inserted one by one: an
    -- INSERT ... SELECT FROM room would be rejected (error 1442) because the
    -- BR-07 trigger locks the room row it is booking (FOR UPDATE).
    DECLARE cur_rooms CURSOR FOR
        SELECT ro.room_id, ro.base_price
          FROM room ro
         WHERE ro.room_id IN (SELECT jt.room_id
                                FROM JSON_TABLE(p_room_ids, '$[*]' COLUMNS (room_id INT PATH '$')) jt)
         ORDER BY ro.room_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_room_ids IS NULL OR JSON_TYPE(p_room_ids) <> 'ARRAY' OR JSON_LENGTH(p_room_ids) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'BR-04: a reservation needs at least one room (JSON array of room ids)';
    END IF;
    IF p_check_out <= p_check_in THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'BR-05: check-out date must be strictly after check-in date';
    END IF;

    SET v_requested = JSON_LENGTH(p_room_ids);
    SELECT COUNT(*), COALESCE(SUM(ro.max_capacity), 0) INTO v_found, v_cap
      FROM room ro
     WHERE ro.room_id IN (SELECT jt.room_id
                            FROM JSON_TABLE(p_room_ids, '$[*]' COLUMNS (room_id INT PATH '$')) jt);

    IF v_found <> v_requested THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'BR-04: unknown or duplicated room id in the list';
    END IF;
    IF p_guests > v_cap THEN
        SET v_msg = CONCAT('BR-05: ', p_guests, ' guests exceed the total capacity of the rooms (', v_cap, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    START TRANSACTION;

    INSERT INTO reservation (client_id, check_in_date, check_out_date, nb_guests, status)
    VALUES (p_client_id, p_check_in, p_check_out, p_guests, 'pending');
    SET p_reservation_id = LAST_INSERT_ID();

    SET v_done = 0;
    OPEN cur_rooms;
    room_loop: LOOP
        FETCH cur_rooms INTO v_room_id, v_price;
        IF v_done = 1 THEN
            LEAVE room_loop;
        END IF;
        -- BR-08: price snapshot; the BR-07 trigger fires on every line
        INSERT INTO reservation_room (reservation_id, room_id, nightly_price)
        VALUES (p_reservation_id, v_room_id, v_price);
    END LOOP;
    CLOSE cur_rooms;

    COMMIT;
END$$

-- ---------------------------------------------------------------------
-- BR-12  Service bookings
--  1. the reservation must not be cancelled
--  2. the slot must fall during the stay (check-in day .. check-out day,
--     both included: a guest may still use the spa on departure day)
--  3. the service must be open that weekday, and the whole slot must lie
--     inside the opening interval, on the slot grid that starts at opening time
--  4. participants already booked on that slot + new ones <= slot capacity
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_assert_service_slot(
    IN p_booking_id     INT UNSIGNED,
    IN p_reservation_id INT UNSIGNED,
    IN p_service_id     SMALLINT UNSIGNED,
    IN p_slot_start     DATETIME,
    IN p_participants   SMALLINT UNSIGNED,
    IN p_status         VARCHAR(10))
sp_body: BEGIN
    DECLARE v_in       DATE              DEFAULT NULL;
    DECLARE v_out      DATE              DEFAULT NULL;
    DECLARE v_res_stat VARCHAR(20)       DEFAULT NULL;
    DECLARE v_open     TIME              DEFAULT NULL;
    DECLARE v_close    TIME              DEFAULT NULL;
    DECLARE v_minutes  SMALLINT UNSIGNED DEFAULT NULL;
    DECLARE v_capacity SMALLINT UNSIGNED DEFAULT NULL;
    DECLARE v_used     INT               DEFAULT 0;
    DECLARE v_start_s  INT;
    DECLARE v_len_s    INT;
    DECLARE v_msg      VARCHAR(128);

    -- a cancelled booking occupies nothing: nothing to check
    IF p_status = 'cancelled' THEN
        LEAVE sp_body;
    END IF;

    SELECT check_in_date, check_out_date, status INTO v_in, v_out, v_res_stat
      FROM reservation WHERE reservation_id = p_reservation_id;
    -- unknown reservation or service: leave it to the foreign keys
    IF v_res_stat IS NULL THEN
        LEAVE sp_body;
    END IF;

    -- lock the service row: serialises concurrent bookings of the same service
    SELECT slot_minutes, slot_capacity INTO v_minutes, v_capacity
      FROM service WHERE service_id = p_service_id FOR UPDATE;
    IF v_minutes IS NULL THEN
        LEAVE sp_body;
    END IF;

    IF v_res_stat = 'cancelled' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-12: services cannot be booked on a cancelled reservation';
    END IF;

    IF DATE(p_slot_start) < v_in OR DATE(p_slot_start) > v_out THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-12: the time slot is outside the client stay';
    END IF;

    -- ISO weekday: WEEKDAY() is 0 = Monday, so +1 gives 1 = Monday .. 7 = Sunday
    SELECT open_time, close_time INTO v_open, v_close
      FROM service_opening_hours
     WHERE service_id = p_service_id
       AND day_of_week = WEEKDAY(p_slot_start) + 1;

    IF v_open IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-12: the service is closed on that day of the week';
    END IF;

    SET v_start_s = TIME_TO_SEC(TIME(p_slot_start));
    SET v_len_s   = v_minutes * 60;

    IF v_start_s < TIME_TO_SEC(v_open) OR v_start_s + v_len_s > TIME_TO_SEC(v_close) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-12: the time slot is not within the opening hours';
    END IF;

    IF MOD(v_start_s - TIME_TO_SEC(v_open), v_len_s) <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'BR-12: the slot start does not match the slot grid of the service';
    END IF;

    SELECT COALESCE(SUM(participants), 0) INTO v_used
      FROM service_booking
     WHERE service_id = p_service_id
       AND slot_start = p_slot_start
       AND status = 'booked'
       AND (p_booking_id IS NULL OR service_booking_id <> p_booking_id)
       FOR SHARE;   -- latest committed bookings (see sp_assert_room_free)

    IF v_used + p_participants > v_capacity THEN
        SET v_msg = CONCAT('BR-12: slot capacity exceeded (', v_used, ' of ',
                           v_capacity, ' places already taken)');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

CREATE TRIGGER trg_service_booking_bi
BEFORE INSERT ON service_booking
FOR EACH ROW
BEGIN
    CALL sp_assert_service_slot(NULL, NEW.reservation_id, NEW.service_id,
                                NEW.slot_start, NEW.participants, NEW.status);
END$$

CREATE TRIGGER trg_service_booking_bu
BEFORE UPDATE ON service_booking
FOR EACH ROW
BEGIN
    CALL sp_assert_service_slot(OLD.service_booking_id, NEW.reservation_id, NEW.service_id,
                                NEW.slot_start, NEW.participants, NEW.status);
END$$

-- ---------------------------------------------------------------------
-- BR-16 / BR-17  Reviews
--   BR-16: the reservation must be completed (one review per reservation
--          is already guaranteed by UNIQUE uq_review_reservation)
--   BR-17: review date on or after the check-out date
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_review_bi
BEFORE INSERT ON review
FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_out    DATE        DEFAULT NULL;

    SELECT status, check_out_date INTO v_status, v_out
      FROM reservation WHERE reservation_id = NEW.reservation_id;

    IF v_status IS NOT NULL THEN
        IF v_status <> 'completed' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR-16: a review can only be written for a completed reservation';
        END IF;
        IF NEW.review_date < v_out THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR-17: the review date must be on or after the check-out date';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_review_bu
BEFORE UPDATE ON review
FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_out    DATE        DEFAULT NULL;

    SELECT status, check_out_date INTO v_status, v_out
      FROM reservation WHERE reservation_id = NEW.reservation_id;

    IF v_status IS NOT NULL THEN
        IF v_status <> 'completed' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR-16: a review can only be written for a completed reservation';
        END IF;
        IF NEW.review_date < v_out THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'BR-17: the review date must be on or after the check-out date';
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- BR-14 + BR-15  Record a payment and update the invoice status atomically
--   * the invoice row is locked, so two concurrent payments cannot both
--     see the same outstanding balance
--   * amount strictly positive (BR-14), never more than the balance due
--   * status: due (nothing paid) / partially_paid / paid (sum >= total)
-- Outputs the new status and the remaining balance.
-- Note: START TRANSACTION implicitly commits a transaction already open in
-- the calling session. Call it in autocommit mode (the normal way).
-- Direct INSERTs into payment bypass the status update: in production,
-- grant applications EXECUTE on this procedure and no INSERT on payment.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_record_payment(
    IN  p_invoice_id INT UNSIGNED,
    IN  p_amount     DECIMAL(12,2),
    IN  p_method     VARCHAR(20),
    IN  p_paid_at    DATETIME,
    OUT p_status     VARCHAR(20),
    OUT p_balance    DECIMAL(12,2))
BEGIN
    DECLARE v_found INT           DEFAULT 0;
    DECLARE v_total DECIMAL(12,2) DEFAULT 0;
    DECLARE v_paid  DECIMAL(12,2) DEFAULT 0;
    DECLARE v_msg   VARCHAR(128);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT COUNT(*) INTO v_found FROM invoice WHERE invoice_id = p_invoice_id FOR UPDATE;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'BR-13: unknown invoice';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'BR-14: a payment amount must be strictly positive';
    END IF;

    SET v_total = fn_invoice_total(p_invoice_id);
    SET v_paid  = fn_invoice_paid(p_invoice_id);

    IF v_paid + p_amount > v_total THEN
        SET v_msg = CONCAT('BR-15: payment exceeds the outstanding balance (', v_total - v_paid, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    INSERT INTO payment (invoice_id, paid_at, amount, method)
    VALUES (p_invoice_id, COALESCE(p_paid_at, NOW()), p_amount, p_method);

    SET v_paid = v_paid + p_amount;
    SET p_status = CASE WHEN v_paid = 0       THEN 'due'
                        WHEN v_paid >= v_total THEN 'paid'
                        ELSE 'partially_paid' END;
    SET p_balance = v_total - v_paid;

    UPDATE invoice SET status = p_status WHERE invoice_id = p_invoice_id;

    COMMIT;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Integrity audits for what MySQL cannot make declarative.
-- Both views must return ZERO rows on a healthy database (05_tests.sql checks it).
-- ---------------------------------------------------------------------

-- BR-05 (capacity): non-cancelled reservations with no room, or more guests
-- than the total capacity of their rooms.
CREATE VIEW v_reservation_capacity_audit AS
SELECT r.reservation_id, r.status, r.nb_guests,
       COALESCE(SUM(ro.max_capacity), 0) AS total_capacity
  FROM reservation r
  LEFT JOIN reservation_room rr ON rr.reservation_id = r.reservation_id
  LEFT JOIN room ro             ON ro.room_id = rr.room_id
 WHERE r.status <> 'cancelled'
 GROUP BY r.reservation_id, r.status, r.nb_guests
HAVING r.nb_guests > COALESCE(SUM(ro.max_capacity), 0);

-- BR-15: stored invoice status differs from the status derived from payments.
CREATE VIEW v_invoice_status_audit AS
SELECT invoice_id, stored_status, derived_status, total_incl_tax, amount_paid
  FROM v_invoice_balance
 WHERE stored_status <> derived_status;

