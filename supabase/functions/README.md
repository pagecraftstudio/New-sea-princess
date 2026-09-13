# NSP Edge Functions

## Functions

| Function | Purpose |
|---|---|
| `verify-recaptcha` | Verifies Google reCAPTCHA v2 token server-side |
| `send-booking-email` | Sends booking confirmation email via Resend |

---

## Deploy

```bash
# Login
supabase login

# Link to your project
supabase link --project-ref uptaqdldbvmiigsfndtm

# Deploy all functions
supabase functions deploy verify-recaptcha
supabase functions deploy send-booking-email
```

---

## Secrets

```bash
# reCAPTCHA (already set)
supabase secrets set RECAPTCHA_SECRET_KEY=your_recaptcha_secret

# Resend API key — get from https://resend.com
supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxx

# Your site URL
supabase secrets set SITE_URL=https://newseaprincess.vercel.app
```

## Resend setup

1. Create account at https://resend.com
2. Add & verify your domain `newseaprincess.com`
3. Create API key with "Sending" permission
4. Set the secret above

> The `send-booking-email` function fails gracefully — if Resend is not configured,
> the booking is still saved and WhatsApp notification still fires. Only the email is skipped.
