-- ============================================================
-- Migration v22: Backfill mecca_hotels / madina_hotels JSONB
-- from legacy flat fields for packages that have none yet.
-- Safe to run multiple times (only updates NULL/empty rows).
-- ============================================================

UPDATE packages
SET mecca_hotels = jsonb_build_array(
  jsonb_build_object(
    'name',        COALESCE(mecca_hotel, ''),
    'stars',       COALESCE(mecca_hotel_stars, 4),
    'nights',      COALESCE(nights_mecca, 0),
    'distance',    COALESCE(mecca_hotel_distance, ''),
    'description', '',
    'room_tiers',  '[]'::jsonb
  )
)
WHERE
  (mecca_hotels IS NULL OR mecca_hotels = '[]'::jsonb)
  AND mecca_hotel IS NOT NULL
  AND mecca_hotel <> '';

UPDATE packages
SET madina_hotels = jsonb_build_array(
  jsonb_build_object(
    'name',        COALESCE(medina_hotel, ''),
    'stars',       COALESCE(medina_hotel_stars, 4),
    'nights',      COALESCE(nights_medina, 0),
    'distance',    COALESCE(medina_hotel_distance, ''),
    'description', '',
    'room_tiers',  '[]'::jsonb
  )
)
WHERE
  (madina_hotels IS NULL OR madina_hotels = '[]'::jsonb)
  AND medina_hotel IS NOT NULL
  AND medina_hotel <> '';

-- Report how many packages still have no hotels after backfill
-- (These need manual admin attention to add room tiers)
DO $$
DECLARE
  missing_count INT;
BEGIN
  SELECT COUNT(*) INTO missing_count
  FROM packages
  WHERE is_active = TRUE
    AND (
      (mecca_hotels IS NULL OR mecca_hotels = '[]'::jsonb)
      OR (madina_hotels IS NULL OR madina_hotels = '[]'::jsonb)
    );

  IF missing_count > 0 THEN
    RAISE NOTICE '⚠️  % active package(s) still missing hotel data — open each in the admin packages page and add hotels + room tiers.', missing_count;
  ELSE
    RAISE NOTICE '✅  All active packages have hotel data.';
  END IF;
END $$;
