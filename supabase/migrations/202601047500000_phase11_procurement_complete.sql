-- ═══════════════════════════════════════════════════════════════════════
-- PHASE 11 COMPLETION — Procurement page missing columns
-- Migration: 202601042000000_phase11_procurement_complete.sql
-- Additive only.
-- ═══════════════════════════════════════════════════════════════════════

-- Add confirmed quantity fields to supplier_confirmations
ALTER TABLE supplier_confirmations
  ADD COLUMN IF NOT EXISTS confirmed_qty      INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS confirmed_qty_unit TEXT    NOT NULL DEFAULT 'pax'
    CHECK (confirmed_qty_unit IN ('pax','room','seat','unit'));

-- Ensure is_active column exists (used to deactivate old confirmations)
ALTER TABLE supplier_confirmations
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;

CREATE INDEX IF NOT EXISTS idx_sup_conf_service_active
  ON supplier_confirmations(trip_service_id, is_active);

-- ═══ END PHASE 11 COMPLETION ════════════════════════════════════════════
