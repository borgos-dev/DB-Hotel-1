# Data dictionary - Hotel Management database

MySQL 8.0, InnoDB, charset `utf8mb4` / collation `utf8mb4_0900_ai_ci`. Amounts are `DECIMAL` (never FLOAT, BR-15), currency XAF.

Types, nullability, keys, defaults and CHECK clauses below are read from the live schema built by `sql/01_schema.sql`; the *Business rule* column cites the rule (BR-xx) each attribute comes from. Rules marked *(trigger)* cross several tables and are enforced in `sql/02_constraints.sql`.

Legend: **PK** primary key, **FK** foreign key (with `ON DELETE` / `ON UPDATE` action), **UQ** unique, **NN** NOT NULL, **NULL** nullable.

## Tables
- [`room_type`](#room_type)
- [`room`](#room)
- [`amenity`](#amenity)
- [`room_amenity`](#room_amenity)
- [`client`](#client)
- [`reservation`](#reservation)
- [`reservation_room`](#reservation_room)
- [`service`](#service)
- [`service_opening_hours`](#service_opening_hours)
- [`service_booking`](#service_booking)
- [`invoice`](#invoice)
- [`invoice_line`](#invoice_line)
- [`payment`](#payment)
- [`review`](#review)

## room_type

Lookup of room categories (open list, so a table rather than an ENUM).

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `room_type_id` | `tinyint unsigned` | PK<br>AUTO_INCREMENT | Surrogate identifier of the room type. | BR-01 |
| `name` | `varchar(30)` | NN<br>UQ `uq_room_type_name` | Type label: Single, Double, Family, Suite... | BR-01 |
| `description` | `varchar(255)` | NULL | Free-text description of the category (optional). | BR-01 |

## room

Physical rooms of the hotel.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `room_id` | `smallint unsigned` | PK<br>AUTO_INCREMENT | Surrogate identifier of the room. | BR-01 |
| `room_number` | `varchar(10)` | NN<br>UQ `uq_room_number` | Unique room number shown on the door (text, e.g. '204'). | BR-01 |
| `floor_number` | `tinyint` | NN<br>CHECK `chk_room_floor`: `(floor_number between -3 and 100)` | Floor where the room is located (negative = basement). | BR-01 |
| `room_type_id` | `tinyint unsigned` | NN<br>FK -> `room_type.room_type_id` ON DELETE RESTRICT ON UPDATE CASCADE | Type of the room. | BR-01 |
| `max_capacity` | `tinyint unsigned` | NN<br>CHECK `chk_room_capacity`: `(max_capacity >= 1)` | Maximum number of guests the room can host. | BR-01, BR-05 |
| `base_price` | `decimal(10,2)` | NN<br>CHECK `chk_room_price`: `(base_price > 0)` | Current catalogue price per night (XAF). Copied into reservation_room when booked, so later changes do not affect existing bookings. | BR-01, BR-08 |
| `operational_status` | `enum('available','occupied','being_cleaned','out_of_service')` | NN<br>DEFAULT 'available' | CURRENT operational situation (available, occupied, being_cleaned, out_of_service). Never used to compute availability over a period. | BR-03 |

## amenity

Catalogue of room amenities.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `amenity_id` | `tinyint unsigned` | PK<br>AUTO_INCREMENT | Surrogate identifier of the amenity. | BR-02 |
| `name` | `varchar(40)` | NN<br>UQ `uq_amenity_name` | Amenity label (sea view, balcony, bathtub...). | BR-02 |

## room_amenity

Associative table: a room has several amenities, an amenity applies to several rooms.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `room_id` | `smallint unsigned` | PK (part of composite 2-column key)<br>FK -> `room.room_id` ON DELETE CASCADE ON UPDATE CASCADE | Room that offers the amenity. | BR-02 |
| `amenity_id` | `tinyint unsigned` | PK (part of composite 2-column key)<br>FK -> `amenity.amenity_id` ON DELETE CASCADE ON UPDATE CASCADE | Amenity offered by the room. | BR-02 |

## client

Hotel clients. The reservation history is obtained by query, never stored here.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `client_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Client identifier. | BR-09 |
| `last_name` | `varchar(60)` | NN | Client last name. | BR-09 |
| `first_name` | `varchar(60)` | NN | Client first name. | BR-09 |
| `phone` | `varchar(20)` | NN<br>UQ `uq_client_phone`<br>CHECK `chk_client_phone`: `regexp_like(phone,'^\\\\+[0-9]{8,15}$')` | Phone number in canonical international format (+ then digits, no spaces) so that UNIQUE detects real duplicates. | BR-09 |
| `email` | `varchar(120)` | NN<br>UQ `uq_client_email`<br>CHECK `chk_client_email`: `regexp_like(email,'^[^@ ]+@[^@ ]+\\\\.[A-Za-z]{2,}$')` | Email address; unique, compared case-insensitively (utf8mb4_0900_ai_ci). | BR-09 |

## reservation

A booking made by one client for one stay (shared dates) covering one or more rooms.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `reservation_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Reservation identifier. | BR-04 |
| `client_id` | `int unsigned` | NN<br>FK -> `client.client_id` ON DELETE RESTRICT ON UPDATE CASCADE | The single client the reservation belongs to. | BR-04 |
| `check_in_date` | `date` | NN<br>CHECK `chk_reservation_dates`: `(check_out_date > check_in_date)` | First night of the stay (shared by all rooms). | BR-04 |
| `check_out_date` | `date` | NN<br>CHECK `chk_reservation_dates`: `(check_out_date > check_in_date)` | Departure day, strictly after check-in; the nights are [check-in, check-out). | BR-04, BR-05 |
| `nb_guests` | `smallint unsigned` | NN<br>CHECK `chk_reservation_guests`: `(nb_guests >= 1)` | Number of guests; must not exceed the total capacity of the reserved rooms (trigger / procedure). | BR-05 |
| `status` | `enum('pending','confirmed','cancelled','completed')` | NN<br>DEFAULT 'pending'<br>CHECK `chk_reservation_cancel` | pending, confirmed, cancelled or completed. A cancelled reservation frees its rooms at once. | BR-06, BR-07 |
| `created_at` | `datetime` | NN<br>DEFAULT CURRENT_TIMESTAMP<br>CHECK `chk_reservation_cancel` | Creation date and time. | BR-06 |
| `cancelled_at` | `datetime` | NULL<br>CHECK `chk_reservation_cancel` | Cancellation date and time; present if and only if status = cancelled (stamped by trigger). | BR-06 |

## reservation_room

Rooms covered by a reservation, with the nightly price frozen at booking time.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `reservation_id` | `int unsigned` | PK (part of composite 2-column key)<br>FK -> `reservation.reservation_id` ON DELETE CASCADE ON UPDATE CASCADE | Reservation the room line belongs to. | BR-04 |
| `room_id` | `smallint unsigned` | PK (part of composite 2-column key)<br>FK -> `room.room_id` ON DELETE RESTRICT ON UPDATE CASCADE | Reserved room. Two non-cancelled reservations cannot hold the same room on overlapping nights (trigger). | BR-04, BR-07 |
| `nightly_price` | `decimal(10,2)` | NN<br>CHECK `chk_reservation_room_price`: `(nightly_price > 0)` | Price per night applied to this room for this reservation, copied from room.base_price at booking time; immutable afterwards (trigger). | BR-08 |

## service

Hotel services (spa, restaurant, gym...).

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `service_id` | `smallint unsigned` | PK<br>AUTO_INCREMENT | Service identifier. | BR-11 |
| `name` | `varchar(60)` | NN<br>UQ `uq_service_name` | Service name. | BR-11 |
| `description` | `varchar(255)` | NN | Description of the service. | BR-11 |
| `price` | `decimal(10,2)` | NN<br>CHECK `chk_service_price`: `(price >= 0)` | Price per participant per time slot (XAF). | BR-11 |
| `slot_minutes` | `smallint unsigned` | NN<br>CHECK `chk_service_slot_len`: `(slot_minutes between 5 and 480)` | Length of one time slot in minutes; slots start at opening time and follow this grid (design choice needed to define a 'time slot'). | BR-11, BR-12 |
| `slot_capacity` | `smallint unsigned` | NN<br>CHECK `chk_service_capacity`: `(slot_capacity >= 1)` | Maximum number of participants per time slot. | BR-11, BR-12 |

## service_opening_hours

Opening interval of a service for each day of the week; no row = closed that day.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `service_id` | `smallint unsigned` | PK (part of composite 2-column key)<br>FK -> `service.service_id` ON DELETE CASCADE ON UPDATE CASCADE | Service concerned. | BR-11 |
| `day_of_week` | `tinyint unsigned` | PK (part of composite 2-column key)<br>CHECK `chk_opening_day`: `(day_of_week between 1 and 7)` | ISO day of week: 1 = Monday ... 7 = Sunday. | BR-11 |
| `open_time` | `time` | NN<br>CHECK `chk_opening_times`: `(close_time > open_time)` | Opening time. | BR-11 |
| `close_time` | `time` | NN<br>CHECK `chk_opening_times`: `(close_time > open_time)` | Closing time; a slot must end at or before it. | BR-11 |

## service_booking

A service booked for a stay in a given time slot (BR-12 rules enforced by trigger).

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `service_booking_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Booking identifier. | BR-12 |
| `reservation_id` | `int unsigned` | NN<br>FK -> `reservation.reservation_id` ON DELETE CASCADE ON UPDATE CASCADE | Stay (and hence client) the service is booked for; the slot must fall during this stay. | BR-12 |
| `service_id` | `smallint unsigned` | NN<br>FK -> `service.service_id` ON DELETE RESTRICT ON UPDATE CASCADE | Booked service. | BR-12 |
| `slot_start` | `datetime` | NN | Start of the time slot; must lie within opening hours and on the slot grid. | BR-12 |
| `participants` | `smallint unsigned` | NN<br>DEFAULT 1<br>CHECK `chk_service_booking_participants`: `(participants >= 1)` | Number of places taken in the slot; the sum per slot cannot exceed slot_capacity. | BR-12 |
| `status` | `enum('booked','cancelled')` | NN<br>DEFAULT 'booked' | booked or cancelled; a cancelled booking frees its places. | BR-12 |

## invoice

The single invoice of a reservation.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `invoice_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Invoice identifier. | BR-13 |
| `reservation_id` | `int unsigned` | NN<br>UQ `uq_invoice_reservation`<br>FK -> `reservation.reservation_id` ON DELETE RESTRICT ON UPDATE CASCADE | Invoiced reservation; UNIQUE = exactly one invoice per reservation. | BR-13 |
| `issue_date` | `date` | NN | Date the invoice was issued. | BR-13 |
| `status` | `enum('due','partially_paid','paid')` | NN<br>DEFAULT 'due' | due, partially_paid or paid; follows from the sum of payments and is maintained by sp_record_payment. | BR-15 |

## invoice_line

Lines of an invoice: nights, services used, miscellaneous charges.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `invoice_line_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Line identifier. | BR-13 |
| `invoice_id` | `int unsigned` | NN<br>FK -> `invoice.invoice_id` ON DELETE CASCADE ON UPDATE CASCADE | Invoice the line belongs to. | BR-13 |
| `line_type` | `enum('accommodation','service','miscellaneous')` | NN<br>CHECK `chk_invoice_line_link`: `((line_type = 'service') = (service_booking_id is not null))` | accommodation (nights), service, or miscellaneous. | BR-13 |
| `description` | `varchar(150)` | NN | Label printed on the invoice. | BR-13 |
| `quantity` | `int unsigned` | NN<br>CHECK `chk_invoice_line_qty`: `(quantity >= 1)` | Quantity billed (nights, participants, units). | BR-13 |
| `unit_price` | `decimal(10,2)` | NN<br>CHECK `chk_invoice_line_price`: `(unit_price >= 0)` | Unit price excluding tax, frozen on the line (XAF). | BR-13, BR-15 |
| `tax_rate` | `decimal(5,4)` | NN<br>DEFAULT 0.0000<br>CHECK `chk_invoice_line_tax`: `(tax_rate between 0 and 1)` | Applicable tax rate as a fraction (0.1925 = 19.25 %). | BR-13 |
| `service_booking_id` | `int unsigned` | NULL<br>UQ `uq_invoice_line_booking`<br>FK -> `service_booking.service_booking_id` ON DELETE RESTRICT ON UPDATE RESTRICT<br>CHECK `chk_invoice_line_link`: `((line_type = 'service') = (service_booking_id is not null))` | Service booking billed by a 'service' line (NULL for other lines); a booking is billed once. | BR-13 |
| `line_subtotal` | `decimal(12,2)` | GENERATED STORED `round((quantity * unit_price),2)` | Generated: quantity x unit_price, rounded to 2 decimals (excl. tax). | BR-13, BR-15 |
| `line_tax` | `decimal(12,2)` | GENERATED STORED `round(((quantity * unit_price) * tax_rate),2)` | Generated: tax amount of the line, rounded to 2 decimals. | BR-13, BR-15 |

## payment

Payments settling an invoice (several allowed).

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `payment_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Payment identifier. | BR-14 |
| `invoice_id` | `int unsigned` | NN<br>FK -> `invoice.invoice_id` ON DELETE RESTRICT ON UPDATE CASCADE | Invoice being settled. | BR-14 |
| `paid_at` | `datetime` | NN<br>DEFAULT CURRENT_TIMESTAMP | Date and time of the payment. | BR-14 |
| `amount` | `decimal(12,2)` | NN<br>CHECK `chk_payment_amount`: `(amount > 0)` | Amount paid, strictly positive (XAF); never more than the outstanding balance (procedure). | BR-14, BR-15 |
| `method` | `enum('cash','card','mobile_money','bank_transfer')` | NN | cash, card, mobile_money or bank_transfer. | BR-14 |

## review

Client review of a completed stay.

| Attribute | MySQL type | Constraints | Description | Business rule |
|---|---|---|---|---|
| `review_id` | `int unsigned` | PK<br>AUTO_INCREMENT | Review identifier. | BR-16 |
| `reservation_id` | `int unsigned` | NN<br>UQ `uq_review_reservation`<br>FK -> `reservation.reservation_id` ON DELETE RESTRICT ON UPDATE CASCADE | Reviewed reservation; must be completed (trigger); UNIQUE = at most one review per reservation. | BR-16 |
| `rating` | `tinyint unsigned` | NN<br>CHECK `chk_review_rating`: `(rating between 1 and 5)` | Overall rating from 1 to 5. | BR-17 |
| `comment_text` | `varchar(1000)` | NULL | Optional comment. | BR-17 |
| `review_date` | `date` | NN<br>DEFAULT curdate() | Date of the review; on or after the check-out date (trigger). | BR-17 |

## Derived data (views)

| View | Purpose | Business rule |
|---|---|---|
| `v_invoice_balance` | Per invoice: total excl. tax, tax, total incl. tax, amount paid, balance due, stored status and status derived from the payments. Used by queries 4 and 6. | BR-13, BR-15 |
| `v_reservation_capacity_audit` | Non-cancelled reservations whose guests exceed the capacity of their rooms (must be empty). | BR-05 |
| `v_invoice_status_audit` | Invoices whose stored status differs from the status derived from payments (must be empty). | BR-15 |

## Rules enforced by programmable objects (`sql/02_constraints.sql`)

| Object | Kind | Rule enforced |
|---|---|---|
| `trg_reservation_room_bi`, `sp_assert_room_free` | trigger + procedure | BR-07: no overlapping nights on a room for non-cancelled reservations (back-to-back stays allowed; cancelled reservations ignored); row lock + locking read make it safe under concurrency |
| `trg_reservation_bu` | trigger | BR-07 when dates change, BR-05 guests <= capacity when guests/status change, BR-06 automatic `cancelled_at`, cancelled is terminal, BR-16/17 reviewed stays frozen |
| `trg_reservation_room_bu`, `trg_reservation_room_bd` | trigger | BR-08 frozen price; room lines immutable; BR-05 capacity kept when a room line is removed |
| `sp_create_reservation` | procedure | BR-04/05/07/08: atomic creation of a reservation with its rooms, price snapshot, capacity check |
| `trg_service_booking_bi`, `trg_service_booking_bu`, `sp_assert_service_slot` | trigger + procedure | BR-12: booking during the stay, inside opening hours on the slot grid, within slot capacity |
| `sp_record_payment`, `fn_invoice_total`, `fn_invoice_paid` | procedure + functions | BR-14/15: records a payment in a transaction, rejects non-positive amounts and overpayment, updates the invoice status |
| `trg_review_bi`, `trg_review_bu` | trigger | BR-16: review only for a completed reservation; BR-17: review date >= check-out date |

## All CHECK constraints

| Table | Constraint | Clause |
|---|---|---|
| `client` | `chk_client_email` | `regexp_like(email,'^[^@ ]+@[^@ ]+\\\\.[A-Za-z]{2,}$')` |
| `client` | `chk_client_phone` | `regexp_like(phone,'^\\\\+[0-9]{8,15}$')` |
| `invoice_line` | `chk_invoice_line_link` | `((line_type = 'service') = (service_booking_id is not null))` |
| `invoice_line` | `chk_invoice_line_price` | `(unit_price >= 0)` |
| `invoice_line` | `chk_invoice_line_qty` | `(quantity >= 1)` |
| `invoice_line` | `chk_invoice_line_tax` | `(tax_rate between 0 and 1)` |
| `payment` | `chk_payment_amount` | `(amount > 0)` |
| `reservation` | `chk_reservation_cancel` | `(((status = 'cancelled') and (cancelled_at is not null) and (cancelled_at >= created_at)) or ((status <> 'cancelled') and (cancelled_at is null)))` |
| `reservation` | `chk_reservation_dates` | `(check_out_date > check_in_date)` |
| `reservation` | `chk_reservation_guests` | `(nb_guests >= 1)` |
| `reservation_room` | `chk_reservation_room_price` | `(nightly_price > 0)` |
| `review` | `chk_review_rating` | `(rating between 1 and 5)` |
| `room` | `chk_room_capacity` | `(max_capacity >= 1)` |
| `room` | `chk_room_floor` | `(floor_number between -3 and 100)` |
| `room` | `chk_room_price` | `(base_price > 0)` |
| `service` | `chk_service_capacity` | `(slot_capacity >= 1)` |
| `service` | `chk_service_price` | `(price >= 0)` |
| `service` | `chk_service_slot_len` | `(slot_minutes between 5 and 480)` |
| `service_booking` | `chk_service_booking_participants` | `(participants >= 1)` |
| `service_opening_hours` | `chk_opening_day` | `(day_of_week between 1 and 7)` |
| `service_opening_hours` | `chk_opening_times` | `(close_time > open_time)` |
