/**
 * Vercel Serverless Function: ocr-scan
 * Proxies passport/national-ID image OCR to Google Cloud Vision's
 * DOCUMENT_TEXT_DETECTION feature. Replaces the old client-side Tesseract.js
 * pipeline, which was unreliable on Arabic-Indic numerals (٠-٩) printed on
 * Egyptian national ID cards.
 *
 * Deploy path : api/ocr-scan.js
 * Live URL    : https://your-domain.vercel.app/api/ocr-scan
 *
 * Why server-side: Cloud Vision needs an API key on every request. If we
 * called it directly from the browser, that key would be visible to anyone
 * who opens dev tools and could be stolen and abused on Google's bill. This
 * endpoint keeps the key in Vercel's environment variables and only ever
 * talks to Google from the server.
 *
 * Environment variables (Vercel dashboard → Project → Settings → Environment Variables):
 *   GOOGLE_VISION_API_KEY — API key for a Google Cloud project with the
 *                           Cloud Vision API enabled. Restrict this key in
 *                           the Google Cloud Console to the Vision API only
 *                           (API restrictions), since it has no IP/referrer
 *                           restriction option when called from a server.
 *
 * Request  (POST, JSON body):
 *   { "imageBase64": "<base64-encoded image, no data: prefix>" }
 *
 * Response (200, JSON body):
 *   { "text": "<full extracted text, newline-separated lines>" }
 *
 * Error response (4xx/5xx, JSON body):
 *   { "error": "<human-readable message>" }
 */

const VISION_ENDPOINT = 'https://vision.googleapis.com/v1/images:annotate';

// Reasonable upper bound so we don't forward huge payloads to Vision or sit
// on a slow client upload — matches the ~2400px-longest-side resize the old
// client-side preprocessor used, base64-encoded JPEG/PNG comfortably fits
// well under this even at decent quality.
const MAX_BASE64_LENGTH = 15 * 1024 * 1024; // ~15MB of base64 text

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed — use POST.' });
    return;
  }

  const apiKey = process.env.GOOGLE_VISION_API_KEY;
  if (!apiKey) {
    console.error('[ocr-scan] Missing GOOGLE_VISION_API_KEY env var');
    res.status(500).json({ error: 'OCR service is not configured. Please contact support.' });
    return;
  }

  let body = req.body;
  // Vercel usually parses JSON bodies automatically, but guard against the
  // rare case where it arrives as a raw string.
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { body = null; }
  }

  const imageBase64 = body?.imageBase64;
  if (!imageBase64 || typeof imageBase64 !== 'string') {
    res.status(400).json({ error: 'Missing imageBase64 in request body.' });
    return;
  }
  if (imageBase64.length > MAX_BASE64_LENGTH) {
    res.status(413).json({ error: 'Image is too large. Please upload a smaller photo.' });
    return;
  }

  try {
    const visionRequestBody = {
      requests: [
        {
          image: { content: imageBase64 },
          features: [{ type: 'DOCUMENT_TEXT_DETECTION' }],
          // Hint both languages so Vision weighs Arabic-Indic digits and
          // Arabic script correctly instead of defaulting to Latin-only.
          imageContext: { languageHints: ['ar', 'en'] },
        },
      ],
    };

    const visionRes = await fetch(`${VISION_ENDPOINT}?key=${apiKey}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(visionRequestBody),
    });

    const visionData = await visionRes.json();

    if (!visionRes.ok) {
      console.error('[ocr-scan] Vision API error:', visionData);
      res.status(502).json({ error: 'OCR provider returned an error. Please try again.' });
      return;
    }

    const annotateResponse = visionData.responses?.[0];

    if (annotateResponse?.error) {
      console.error('[ocr-scan] Vision annotate error:', annotateResponse.error);
      res.status(502).json({ error: 'OCR provider could not process this image.' });
      return;
    }

    const text = annotateResponse?.fullTextAnnotation?.text || '';

    res.status(200).json({ text });
  } catch (err) {
    console.error('[ocr-scan] Unexpected error:', err);
    res.status(500).json({ error: 'Unexpected error while processing the image.' });
  }
};
