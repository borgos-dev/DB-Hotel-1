-- =====================================================================
-- 01_schema.sql  (L3)  Hotel Management database - MySQL 8.0 / InnoDB
-- ---------------------------------------------------------------------
-- Creates the database, all tables, primary/foreign keys, UNIQUE, NOT NULL,
-- CHECK constraints, ENUMs / lookup tables and two read-only views.
-- Cross-table rules that MySQL cannot declare (BR-05 capacity, BR-07, BR-12,
-- BR-15, BR-16, BR-17) are enforced in 02_constraints.sql.
-- =====================================================================

DROP DATABASE IF EXISTS hotel_db;
CREATE DATABASE hotel_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE hotel_db;

-- ---------------------------------------------------------------------
-- ROOMS  (BR-01, BR-02, BR-03)
-- ---------------------------------------------------------------------

-- Lookup table: the list of types is open ("single, double, suite...").
CREATE TABLE room_type (
    room_type_id  TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name          VARCHAR(30)      NOT NULL,
    description   VARCHAR(255)     NULL,
    CONSTRAINT pk_room_type      PRIMARY KEY (room_type_id),
    CONSTRAINT uq_room_type_name UNIQUE (name)
) ENGINE = InnoDB;

CREATE TABLE room (
    room_id            SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    room_number        VARCHAR(10)       NOT NULL,                 -- BR-01: unique number
    floor_number       TINYINT           NOT NULL,                 -- signed: basement floors allowed
    room_type_id       TINYINT UNSIGNED  NOT NULL,
    max_capacity       TINYINT UNSIGNED  NOT NULL,
    base_price         DECIMAL(10,2)     NOT NULL,                 -- current catalogue price / night
    -- BR-03: CURRENT situation only. Availability over a period is NEVER read
    -- from this column; it is derived from reservations.
    operational_status ENUM('available','occupied','being_cleaned','out_of_service')
                                         NOT NULL DEFAULT 'available',
    CONSTRAINT pk_room        PRIMARY KEY (room_id),
    CONSTRAINT uq_room_number UNIQUE (room_number),
    CONSTRAINT chk_room_floor    CHECK (floor_number BETWEEN -3 AND 100),
    CONSTRAINT chk_room_capacity CHECK (max_capacity >= 1),
    CONSTRAINT chk_room_price    CHECK (base_price > 0),
    -- RESTRICT: a room type still used by rooms must not disappear.
    CONSTRAINT fk_room_type FOREIGN KEY (room_type_id) REFERENCES room_type (room_type_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE TABLE amenity (
    amenity_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name       VARCHAR(40)      NOT NULL,
    CONSTRAINT pk_amenity      PRIMARY KEY (amenity_id),
    CONSTRAINT uq_amenity_name UNIQUE (name)
) ENGINE = InnoDB;

-- BR-02: many-to-many between room and amenity.
CREATE TABLE room_amenity (
    room_id    SMALLINT UNSIGNED NOT NULL,
    amenity_id TINYINT UNSIGNED  NOT NULL,
    CONSTRAINT pk_room_amenity PRIMARY KEY (room_id, amenity_id),
    -- CASCADE both ways: a link row has no meaning without its two parents.
    CONSTRAINT fk_room_amenity_room    FOREIGN KEY (room_id)    REFERENCES room (room_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_room_amenity_amenity FOREIGN KEY (amenity_id) REFERENCES amenity (amenity_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- CLIENTS  (BR-09, BR-10)
-- ---------------------------------------------------------------------
-- BR-10: no reservation list / counter is stored here; history = query.
CREATE TABLE client (
    client_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    last_name  VARCHAR(60)  NOT NULL,
    first_name VARCHAR(60)  NOT NULL,
    phone      VARCHAR(20)  NOT NULL,   -- canonical E.164 (+ and digits) so that UNIQUE is meaningful
    email      VARCHAR(120) NOT NULL,   -- utf8mb4_0900_ai_ci: unique ignoring case
    CONSTRAINT pk_client       PRIMARY KEY (client_id),
    CONSTRAINT uq_client_phone UNIQUE (phone),
    CONSTRAINT uq_client_email UNIQUE (email),
    CONSTRAINT chk_client_phone CHECK (phone REGEXP '^\\+[0-9]{8,15}$'),
    CONSTRAINT chk_client_email CHECK (email REGEXP '^[^@ ]+@[^@ ]+\\.[A-Za-z]{2,}$')
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- RESERVATIONS  (BR-04 .. BR-08)
-- ---------------------------------------------------------------------
-- BR-04: one client, shared check-in / check-out dates for all its rooms.
CREATE TABLE reservation (
    reservation_id INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    client_id      INT UNSIGNED      NOT NULL,
    check_in_date  DATE              NOT NULL,
    check_out_date DATE              NOT NULL,
    nb_guests      SMALLINT UNSIGNED NOT NULL,
    status         ENUM('pending','confirmed','cancelled','completed')
                                     NOT NULL DEFAULT 'pending',      -- BR-06
    created_at     DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cancelled_at   DATETIME          NULL,
    CONSTRAINT pk_reservation PRIMARY KEY (reservation_id),
    -- BR-05 (first half): check-out strictly after check-in
    CONSTRAINT chk_reservation_dates  CHECK (check_out_date > check_in_date),
    CONSTRAINT chk_reservation_guests CHECK (nb_guests >= 1),
    -- BR-06: cancelled_at present if and only if the reservation is cancelled
    CONSTRAINT chk_reservation_cancel CHECK (
        (status = 'cancelled' AND cancelled_at IS NOT NULL AND cancelled_at >= created_at)
        OR (status <> 'cancelled' AND cancelled_at IS NULL)),
    KEY idx_reservation_dates (check_in_date, check_out_date),
    -- RESTRICT: a client with history cannot be deleted (BR-10 history must stay queryable).
    CONSTRAINT fk_reservation_client FOREIGN KEY (client_id) REFERENCES client (client_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- BR-04 (rooms of a reservation) + BR-08 (price frozen at booking time).
-- The room set of a reservation never overlaps in time with another
-- non-cancelled reservation (BR-07, trigger in 02_constraints.sql).
CREATE TABLE reservation_room (
    reservation_id INT UNSIGNED      NOT NULL,
    room_id        SMALLINT UNSIGNED NOT NULL,
    nightly_price  DECIMAL(10,2)     NOT NULL,   -- BR-08: snapshot of room.base_price when booked
    CONSTRAINT pk_reservation_room PRIMARY KEY (reservation_id, room_id),
    CONSTRAINT chk_reservation_room_price CHECK (nightly_price > 0),
    KEY idx_reservation_room_room (room_id),     -- speeds up the BR-07 overlap lookup
    -- CASCADE: lines are owned by the reservation (deleting a draft reservation removes them).
    CONSTRAINT fk_reservation_room_reservation FOREIGN KEY (reservation_id)
        REFERENCES reservation (reservation_id) ON DELETE CASCADE ON UPDATE CASCADE,
    -- RESTRICT: a room that was ever booked cannot be deleted (history, invoices).
    CONSTRAINT fk_reservation_room_room FOREIGN KEY (room_id)
        REFERENCES room (room_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- SERVICES  (BR-11, BR-12)
-- ---------------------------------------------------------------------
CREATE TABLE service (
    service_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name          VARCHAR(60)       NOT NULL,
    description   VARCHAR(255)      NOT NULL,
    price         DECIMAL(10,2)     NOT NULL,   -- price per participant per slot
    slot_minutes  SMALLINT UNSIGNED NOT NULL,   -- length of one time slot (defines the slot grid)
    slot_capacity SMALLINT UNSIGNED NOT NULL,   -- BR-11: max participants per time slot
    CONSTRAINT pk_service      PRIMARY KEY (service_id),
    CONSTRAINT uq_service_name UNIQUE (name),
    CONSTRAINT chk_service_price    CHECK (price >= 0),
    CONSTRAINT chk_service_slot_len CHECK (slot_minutes BETWEEN 5 AND 480),
    CONSTRAINT chk_service_capacity CHECK (slot_capacity >= 1)
) ENGINE = InnoDB;

-- BR-11: opening hours for each day of the week. One interval per day;
-- a day with no row means the service is closed that day.
CREATE TABLE service_opening_hours (
    service_id  SMALLINT UNSIGNED NOT NULL,
    day_of_week TINYINT UNSIGNED  NOT NULL,     -- ISO: 1 = Monday ... 7 = Sunday
    open_time   TIME              NOT NULL,
    close_time  TIME              NOT NULL,
    CONSTRAINT pk_service_opening_hours PRIMARY KEY (service_id, day_of_week),
    CONSTRAINT chk_opening_day   CHECK (day_of_week BETWEEN 1 AND 7),
    CONSTRAINT chk_opening_times CHECK (close_time > open_time),
    -- CASCADE: opening hours are part of the service definition.
    CONSTRAINT fk_opening_hours_service FOREIGN KEY (service_id) REFERENCES service (service_id)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE = InnoDB;

-- BR-12: a service is booked for a stay (reservation), hence for its client.
-- "During the stay", "within opening hours" and "within slot capacity" are
-- enforced by triggers (02_constraints.sql).
CREATE TABLE service_booking (
    service_booking_id INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    reservation_id     INT UNSIGNED      NOT NULL,
    service_id         SMALLINT UNSIGNED NOT NULL,
    slot_start         DATETIME          NOT NULL,
    participants       SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    status             ENUM('booked','cancelled') NOT NULL DEFAULT 'booked',  -- cancelled frees the slot
    CONSTRAINT pk_service_booking PRIMARY KEY (service_booking_id),
    CONSTRAINT chk_service_booking_participants CHECK (participants >= 1),
    KEY idx_service_booking_slot (service_id, slot_start),
    -- CASCADE: bookings belong to the stay; a draft reservation removed with its bookings.
    CONSTRAINT fk_service_booking_reservation FOREIGN KEY (reservation_id)
        REFERENCES reservation (reservation_id) ON DELETE CASCADE ON UPDATE CASCADE,
    -- RESTRICT: a service that has bookings cannot be deleted (deactivate it instead).
    CONSTRAINT fk_service_booking_service FOREIGN KEY (service_id)
        REFERENCES service (service_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- BILLING  (BR-13, BR-14, BR-15)
-- ---------------------------------------------------------------------
-- BR-13: exactly one invoice per reservation (UNIQUE on reservation_id).
-- status is the stored result of BR-15, maintained by sp_record_payment.
CREATE TABLE invoice (
    invoice_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
    reservation_id INT UNSIGNED NOT NULL,
    issue_date     DATE         NOT NULL,
    status         ENUM('due','partially_paid','paid') NOT NULL DEFAULT 'due',
    CONSTRAINT pk_invoice PRIMARY KEY (invoice_id),
    CONSTRAINT uq_invoice_reservation UNIQUE (reservation_id),
    -- RESTRICT: accounting documents must not vanish with a reservation.
    CONSTRAINT fk_invoice_reservation FOREIGN KEY (reservation_id)
        REFERENCES reservation (reservation_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- BR-13: lines = nights, services used, miscellaneous charges.
CREATE TABLE invoice_line (
    invoice_line_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    invoice_id         INT UNSIGNED NOT NULL,
    line_type          ENUM('accommodation','service','miscellaneous') NOT NULL,
    description        VARCHAR(150) NOT NULL,
    quantity           INT UNSIGNED NOT NULL,
    unit_price         DECIMAL(10,2) NOT NULL,          -- frozen price, independent of the catalogue
    tax_rate           DECIMAL(5,4)  NOT NULL DEFAULT 0, -- 0.1925 = 19.25 %
    service_booking_id INT UNSIGNED  NULL,              -- traceability of "services used"
    -- derived amounts, always consistent with quantity / unit_price / tax_rate
    line_subtotal DECIMAL(12,2) AS (ROUND(quantity * unit_price, 2)) STORED,
    line_tax      DECIMAL(12,2) AS (ROUND(quantity * unit_price * tax_rate, 2)) STORED,
    CONSTRAINT pk_invoice_line PRIMARY KEY (invoice_line_id),
    CONSTRAINT uq_invoice_line_booking UNIQUE (service_booking_id),   -- a booking is billed once
    CONSTRAINT chk_invoice_line_qty   CHECK (quantity >= 1),
    CONSTRAINT chk_invoice_line_price CHECK (unit_price >= 0),
    CONSTRAINT chk_invoice_line_tax   CHECK (tax_rate BETWEEN 0 AND 1),
    CONSTRAINT chk_invoice_line_link  CHECK ((line_type = 'service') = (service_booking_id IS NOT NULL)),
    -- CASCADE: lines are part of the invoice document (while no payment exists, see payment FK).
    CONSTRAINT fk_invoice_line_invoice FOREIGN KEY (invoice_id) REFERENCES invoice (invoice_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    -- RESTRICT: keep the audit link between a billed service and its booking.
    CONSTRAINT fk_invoice_line_booking FOREIGN KEY (service_booking_id)
        REFERENCES service_booking (service_booking_id) ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE = InnoDB;

-- BR-14: an invoice may be settled by several payments.
CREATE TABLE payment (
    payment_id INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    invoice_id INT UNSIGNED  NOT NULL,
    paid_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    amount     DECIMAL(12,2) NOT NULL,
    method     ENUM('cash','card','mobile_money','bank_transfer') NOT NULL,
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT chk_payment_amount CHECK (amount > 0),              -- BR-14: strictly positive
    KEY idx_payment_invoice_date (invoice_id, paid_at),
    -- RESTRICT: an invoice with payments can never be deleted (financial trail).
    CONSTRAINT fk_payment_invoice FOREIGN KEY (invoice_id) REFERENCES invoice (invoice_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- REVIEWS  (BR-16, BR-17)
-- ---------------------------------------------------------------------
-- "Completed reservation" (BR-16) and "date >= check-out" (BR-17) cross
-- tables, so they are enforced by trigger. "At most one review" is UNIQUE.
CREATE TABLE review (
    review_id      INT UNSIGNED     NOT NULL AUTO_INCREMENT,
    reservation_id INT UNSIGNED     NOT NULL,
    rating         TINYINT UNSIGNED NOT NULL,
    comment_text   VARCHAR(1000)    NULL,                           -- optional
    review_date    DATE             NOT NULL DEFAULT (CURRENT_DATE),
    CONSTRAINT pk_review PRIMARY KEY (review_id),
    CONSTRAINT uq_review_reservation UNIQUE (reservation_id),
    CONSTRAINT chk_review_rating CHECK (rating BETWEEN 1 AND 5),
    -- RESTRICT: reviewed reservations cannot be deleted silently.
    CONSTRAINT fk_review_reservation FOREIGN KEY (reservation_id)
        REFERENCES reservation (reservation_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- DERIVED DATA AS VIEWS  (BR-10, BR-15: derive, do not store)
-- ---------------------------------------------------------------------
-- Invoice totals, amount paid, balance and the status that BR-15 says
-- "follows from the sum of payments". stored_status vs derived_status lets
-- the audit in 02/05 prove they are in sync.
CREATE VIEW v_invoice_balance AS
SELECT i.invoice_id,
       i.reservation_id,
       i.issue_date,
       i.status                                              AS stored_status,
       COALESCE(l.subtotal, 0)                               AS total_excl_tax,
       COALESCE(l.tax, 0)                                    AS total_tax,
       COALESCE(l.subtotal, 0) + COALESCE(l.tax, 0)          AS total_incl_tax,
       COALESCE(p.paid, 0)                                   AS amount_paid,
       COALESCE(l.subtotal, 0) + COALESCE(l.tax, 0) - COALESCE(p.paid, 0) AS balance_due,
       CASE WHEN COALESCE(p.paid, 0) = 0 THEN 'due'
            WHEN COALESCE(p.paid, 0) >= COALESCE(l.subtotal, 0) + COALESCE(l.tax, 0) THEN 'paid'
            ELSE 'partially_paid' END                        AS derived_status
FROM invoice i
LEFT JOIN (SELECT invoice_id, SUM(line_subtotal) AS subtotal, SUM(line_tax) AS tax
             FROM invoice_line GROUP BY invoice_id) l ON l.invoice_id = i.invoice_id
LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid
             FROM payment GROUP BY invoice_id) p ON p.invoice_id = i.invoice_id;
