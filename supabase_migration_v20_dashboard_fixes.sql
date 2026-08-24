-- ── v20: Dashboard data fetch fixes ──────────────────────────
-- 1. Add booking_date to booking_profitability view so the
--    accounting dashboard can filter KPIs by period.

DROP VIEW IF EXISTS booking_profitability CASCADE;

CREATE OR REPLACE VIEW booking_profitability AS
SELECT
  b.id                                             AS booking_id,
  b.booking_number,
  b.customer_name,
  b.package_title,
  b.status,
  b.created_at::DATE                               AS booking_date,
  b.package_departure,
  b.total_price                                    AS selling_price,
  b.paid_amount,
  b.remaining_amount,
  COALESCE(SUM(CASE bc.type WHEN 'hotel'     THEN bc.base_amount ELSE 0 END), 0) AS hotel_cost,
  COALESCE(SUM(CASE bc.type WHEN 'flight'    THEN bc.base_amount ELSE 0 END), 0) AS flight_cost,
  COALESCE(SUM(CASE bc.type WHEN 'visa'      THEN bc.base_amount ELSE 0 END), 0) AS visa_cost,
  COALESCE(SUM(CASE bc.type WHEN 'transport' THEN bc.base_amount ELSE 0 END), 0) AS transport_cost,
  COALESCE(SUM(CASE bc.type WHEN 'other'     THEN bc.base_amount ELSE 0 END), 0) AS other_cost,
  COALESCE(SUM(bc.base_amount), 0)                 AS total_cost,
  b.total_price - COALESCE(SUM(bc.base_amount), 0) AS gross_profit,
  CASE WHEN b.total_price = 0 THEN 0
       ELSE ROUND(
         (b.total_price - COALESCE(SUM(bc.base_amount), 0))
         / b.total_price * 100, 2)
  END                                              AS gross_margin_pct
FROM bookings b
LEFT JOIN booking_costs bc ON bc.booking_id = b.id
WHERE b.status != 'cancelled'
GROUP BY b.id, b.booking_number, b.customer_name, b.package_title,
         b.status, b.created_at, b.package_departure,
         b.total_price, b.paid_amount, b.remaining_amount
ORDER BY gross_profit DESC;

GRANT SELECT ON booking_profitability TO authenticated;
