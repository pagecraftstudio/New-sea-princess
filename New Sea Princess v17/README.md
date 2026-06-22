# نيو سي برنسيس لسياحة (New Sea Princess Tourism)

A complete, production-ready website for an Egyptian Umrah and Hajj travel company. Built with HTML5, Vanilla JavaScript, Tailwind CSS, and Supabase.

## ✨ Features
- **Arabic-First Design:** Fully RTL with Cairo typography and an Islamic luxury theme.
- **Packages & Search:** Filter and browse travel packages dynamically.
- **Booking Flow:** Multi-step booking form with document uploads (to Supabase Storage).
- **Tracking System:** Real-time booking tracking pipeline for customers.
- **Admin Panel:** Complete suite for managing packages, reviews, and bookings.
- **Supabase Backend:** Uses PostgreSQL, Auth, and Storage entirely from the client side without a dedicated Node.js server.

## 🚀 Setup & Deployment

1. **Create a Supabase Project:**
   - Go to [Supabase](https://supabase.com) and create a new project.
   - Run the provided `schema.sql` code in the Supabase SQL Editor to create all tables, policies, and sample data.
   - Create a Storage Bucket named `booking-documents` and make it private (or public depending on strict security needs, but typically private is better for passports).

2. **Configure Keys:**
   - Open `/js/supabase-config.js`.
   - Replace the `SUPABASE_URL` and `SUPABASE_ANON_KEY` variables with your actual Supabase credentials.

3. **Admin User:**
   - Go to Supabase Auth -> Users and invite or create a user that you will use to log into the `/admin/login.html` dashboard.

4. **Deploy:**
   - Because this project uses pure HTML/JS and CDN links (no bundler needed), you can simply drag and drop this entire folder into Netlify Drop (https://app.netlify.com/drop) or deploy it via GitHub Pages / Vercel.

## 📚 Technical Details
- WhatsApp Integration: Links are dynamically built to `wa.me/201555154996` with pre-filled encoded text.
- Form Validations: Handled client-side using Vanilla JS.
- Database: All operations are executed directly against the Supabase REST API via `supabase-js`.
- Customizations: Tailwind CSS is executed dynamically in the browser (via CDN) which is great for fast prototyping, but for high-traffic production, consider compiling Tailwind locally.
# New-sea-princess
