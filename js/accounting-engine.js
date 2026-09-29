/**
 * accounting-engine.js
 * NSP Double-Entry Accounting Engine — Auto Journal Creation
 * All account IDs resolved from accounting_mappings table (never hardcoded).
 *
 * © 2026 New Sea Princess Tourism & Pagecraft Studio. All rights reserved.
 */

window.NSPAccounting = (() => {

  // ── Resolve account ID from mapping key ──────────────────────
  async function getAccount(key) {
    const { data, error } = await window.db
      .from('accounting_mappings')
      .select('account_id')
      .eq('mapping_key', key)
      .single();
    if (error || !data) throw new Error(`Missing accounting mapping: ${key}`);
    return data.account_id;
  }

  // ── Get active fiscal period for a date ──────────────────────
  async function getFiscalPeriod(date) {
    const d = date || new Date().toISOString().split('T')[0];
    const { data } = await window.db
      .from('fiscal_periods')
      .select('id, status')
      .lte('start_date', d)
      .gte('end_date', d)
      .eq('status', 'open')
      .single();
    return data?.id || null;
  }

  // ── Core: create + post a balanced journal entry ──────────────
  async function createJournalEntry({ date, description, reference_type, reference_id, lines, cost_center_id }) {
    if (!window.db) throw new Error('DB not initialized');

    // Validate balance
    const totalDebit  = lines.reduce((s, l) => s + (l.debit  || 0), 0);
    const totalCredit = lines.reduce((s, l) => s + (l.credit || 0), 0);
    if (Math.abs(totalDebit - totalCredit) > 0.01) {
      throw new Error(`Unbalanced entry: Dr ${totalDebit} Cr ${totalCredit}`);
    }

    const entryDate = date || new Date().toISOString().split('T')[0];
    const fiscal_period_id = await getFiscalPeriod(entryDate);

    // Insert header
    const { data: je, error: jeErr } = await window.db
      .from('journal_entries')
      .insert({
        entry_date: entryDate,
        fiscal_period_id,
        description,
        reference_type,
        reference_id,
        status: 'posted',
        total_debit: totalDebit,
        total_credit: totalCredit,
        cost_center_id: cost_center_id || null,
        posted_at: new Date().toISOString(),
      })
      .select('id')
      .single();
    if (jeErr) throw jeErr;

    // Insert lines
    const lineRows = lines.map((l, i) => ({
      journal_entry_id: je.id,
      account_id:  l.account_id,
      debit:  l.debit  || 0,
      credit: l.credit || 0,
      description: l.description || description,
      cost_center_id: l.cost_center_id || cost_center_id || null,
      line_order: i,
    }));
    const { error: lineErr } = await window.db
      .from('journal_entry_lines')
      .insert(lineRows);
    if (lineErr) throw lineErr;

    return je.id;
  }

  // ── 1. Invoice Posted → Dr AR / Cr Revenue ───────────────────
  async function onInvoicePosted({ invoiceId, bookingId, amount, date, category, customerName }) {
    // Pick revenue account by package category
    const categoryMap = {
      umrah:   'revenue_umrah',
      hajj:    'revenue_hajj',
      tourism: 'revenue_tourism',
    };
    const revKey = categoryMap[category] || 'revenue_default';

    const [arAcct, revAcct] = await Promise.all([
      getAccount('ar_account'),
      getAccount(revKey),
    ]);

    return createJournalEntry({
      date,
      description: `فاتورة مبيعات — ${customerName}`,
      reference_type: 'invoice',
      reference_id: invoiceId,
      lines: [
        { account_id: arAcct,  debit: amount,  credit: 0,      description: `ذمم مدينة — ${customerName}` },
        { account_id: revAcct, debit: 0,        credit: amount, description: `إيراد — ${revKey}`           },
      ],
    });
  }

  // ── 2. Customer Payment → Dr Cash/Bank / Cr AR ───────────────
  async function onPaymentReceived({ paymentId, invoiceId, amount, date, cashAccountGlId, customerName }) {
    // cashAccountGlId = gl_account_id from cash_accounts record
    const arAcct = await getAccount('ar_account');
    const cashAcct = cashAccountGlId || await getAccount('cash_account');

    return createJournalEntry({
      date,
      description: `استلام دفعة — ${customerName}`,
      reference_type: 'payment',
      reference_id: paymentId,
      lines: [
        { account_id: cashAcct, debit: amount,  credit: 0      },
        { account_id: arAcct,   debit: 0,        credit: amount },
      ],
    });
  }

  // ── 3. Expense Posted → Dr Expense / Cr Cash/Bank ────────────
  async function onExpensePosted({ expenseId, amount, date, expenseAccountId, cashAccountGlId, description, costCenterId }) {
    const cashAcct = cashAccountGlId || await getAccount('cash_account');

    return createJournalEntry({
      date,
      description: description || 'مصروف',
      reference_type: 'expense',
      reference_id: expenseId,
      cost_center_id: costCenterId,
      lines: [
        { account_id: expenseAccountId, debit: amount, credit: 0      },
        { account_id: cashAcct,          debit: 0,      credit: amount },
      ],
    });
  }

  // ── 4. Refund → reverse payment entry ────────────────────────
  async function onRefundIssued({ originalJeId, refundId, amount, date, cashAccountGlId, customerName }) {
    const arAcct   = await getAccount('ar_account');
    const cashAcct = cashAccountGlId || await getAccount('cash_account');

    return createJournalEntry({
      date,
      description: `استرداد — ${customerName}`,
      reference_type: 'refund',
      reference_id: refundId,
      lines: [
        { account_id: arAcct,   debit: amount,  credit: 0      },
        { account_id: cashAcct, debit: 0,        credit: amount },
      ],
    });
  }

  // ── 5. Bank Fee → Dr Bank Fees / Cr Bank ─────────────────────
  async function onBankFee({ amount, date, bankGlAccountId, description }) {
    const feeAcct  = await getAccount('bank_fees');
    const bankAcct = bankGlAccountId || await getAccount('cash_account');

    return createJournalEntry({
      date,
      description: description || 'رسوم بنكية',
      reference_type: 'bank_fee',
      reference_id: null,
      lines: [
        { account_id: feeAcct,  debit: amount, credit: 0      },
        { account_id: bankAcct, debit: 0,       credit: amount },
      ],
    });
  }

  // ── 6. Cash Transfer between accounts ────────────────────────
  async function onCashTransfer({ fromGlAccountId, toGlAccountId, amount, date, description }) {
    return createJournalEntry({
      date,
      description: description || 'تحويل داخلي',
      reference_type: 'transfer',
      lines: [
        { account_id: toGlAccountId,   debit: amount, credit: 0      },
        { account_id: fromGlAccountId, debit: 0,       credit: amount },
      ],
    });
  }

  // ── 7. Booking cost recorded (supplier cost) ─────────────────
  async function onBookingCostAdded({ bookingCostId, amount, date, costType, supplierApAccountId, description }) {
    const costKeyMap = {
      hotel:     'cost_hotel',
      flight:    'cost_flight',
      visa:      'cost_visa',
      transport: 'cost_transport',
      other:     'cost_other',
    };
    const costKey  = costKeyMap[costType] || 'cost_other';
    const costAcct = await getAccount(costKey);
    const apAcct   = supplierApAccountId || await getAccount('ap_account');

    return createJournalEntry({
      date,
      description: description || `تكلفة ${costType}`,
      reference_type: 'booking_cost',
      reference_id: bookingCostId,
      lines: [
        { account_id: costAcct, debit: amount, credit: 0      },
        { account_id: apAcct,   debit: 0,       credit: amount },
      ],
    });
  }

  // ── Public API ────────────────────────────────────────────────
  return {
    createJournalEntry,
    onInvoicePosted,
    onPaymentReceived,
    onExpensePosted,
    onRefundIssued,
    onBankFee,
    onCashTransfer,
    onBookingCostAdded,
    getAccount,
    getFiscalPeriod,
  };

})();
