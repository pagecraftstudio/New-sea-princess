# NSP Database Migrations

All files follow Supabase's timestamp convention: `YYYYMMDDHHmmss_description.sql`

## Migration Order

| File | Description |
|------|-------------|
| `202601001000000_initial_schema.sql` | Core tables: bookings, packages, travelers, profiles |
| `202601003000000_settings.sql` | Site settings key-value store |
| `202601005000000_accounting.sql` | Double-entry accounting engine (accounts, journal_entries, journal_entry_lines) |
| `202601005100000_expenses.sql` | Expenses module (expense_categories, cost_centers, expenses) |
| `202601005200000_expenses_fixed.sql` | Expenses idempotent fix |
| `202601006000000_coa_seed.sql` | Seed data for Chart of Accounts |
| `202601007000000_customers_suppliers.sql` | Customers and suppliers tables |
| `202601008000000_invoices_payments.sql` | nsp_invoices and nsp_payments |
| `202601008100000_invoices.sql` | Invoice auxiliary tables |
| `202601009000000_cash_bank.sql` | Cash, bank accounts, wallets |
| `202601010000000_ar_ap.sql` | AR/AP aging views |
| `202601011000000_multicurrency_tax.sql` | Multi-currency and tax support |
| `202601012000000_reports.sql` | Reporting views |
| `202601013000000_fiscal_periods.sql` | Fiscal periods management |
| `202601014000000_roles_permissions_fixed.sql` | Admin roles and RLS policies |
| `202601015000000_audit_approvals.sql` | Audit log and approval workflow |
| `202601016000000_health_check_FIXED.sql` | Accounting health check functions |
| `202601017000000_auto_accounting_fix.sql` | Auto-accounting triggers |
| `202601018000000_debit_notes_expense_trigger.sql` | Debit/credit note triggers |
| `202601019000000_supplier_bills_payments.sql` | Supplier bills and payments |
| `202601020000000_dashboard_fixes.sql` | Dashboard view fixes |

## Archived

Files in `_archive/` are superseded by the initial schema and kept for history only.
Do **not** re-run them — all their columns already exist in `202601001000000_initial_schema.sql`.

## Running Migrations

```bash
# Run all pending migrations
supabase db push

# Or run a single file in Supabase SQL Editor
# Dashboard → SQL Editor → paste file content → Run
```
