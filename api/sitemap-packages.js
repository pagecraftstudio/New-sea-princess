/**
 * Vercel Serverless Function: sitemap-packages
 * Generates a dynamic XML sitemap for all active packages from Supabase.
 *
 * Deploy path : api/sitemap-packages.js
 * Live URL    : https://your-domain.vercel.app/api/sitemap-packages
 *
 * Environment variables (Vercel dashboard → Project → Settings → Environment Variables):
 *   SUPABASE_URL       — your Supabase project URL
 *   SUPABASE_ANON_KEY  — your Supabase anon/public key
 */

const { createClient } = require('@supabase/supabase-js');

const SITE_URL = 'https://newseaprincess.vercel.app'; // ← update to your actual domain

module.exports = async (req, res) => {
  try {
    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_ANON_KEY
    );

    const { data: packages, error } = await supabase
      .from('packages')
      .select('id, updated_at')
      .eq('is_active', true)
      .order('created_at', { ascending: false });

    if (error) throw error;

    const today = new Date().toISOString().slice(0, 10);

    const packageUrls = (packages || []).map(pkg => {
      const lastmod = pkg.updated_at
        ? new Date(pkg.updated_at).toISOString().slice(0, 10)
        : today;
      return `
  <url>
    <loc>${SITE_URL}/package-detail.html?id=${pkg.id}</loc>
    <lastmod>${lastmod}</lastmod>
    <changefreq>weekly</changefreq>
    <priority>0.85</priority>
  </url>`;
    }).join('');

    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${packageUrls}
</urlset>`;

    res.setHeader('Content-Type', 'application/xml; charset=utf-8');
    res.setHeader('Cache-Control', 'public, max-age=3600');
    res.status(200).send(xml);

  } catch (err) {
    console.error('sitemap error:', err);
    res.setHeader('Content-Type', 'application/xml');
    res.status(500).send(`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>`);
  }
};
