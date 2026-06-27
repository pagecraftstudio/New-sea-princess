/**
 * Vercel Serverless Function: ocr-scan
 * Proxies passport/national-ID image OCR to the OCR.space API (Engine 2).
 *
 * Deploy path : api/ocr-scan.js
 * Live URL    : https://your-domain.vercel.app/api/ocr-scan
 *
 * Why OCR.space instead of Google Cloud Vision: Cloud Vision requires an
 * active billing account linked even to use its free tier — no card on file
 * means every request is rejected with a 403, regardless of API key/IAM
 * setup. OCR.space's free tier (25,000 requests/month, no card required)
 * gives a comparable upgrade over the original client-side Tesseract.js
 * setup — notably much better handling of Arabic script and MRZ zones —
 * without that blocker. If volume or accuracy needs grow later, this file
 * can be swapped for Cloud Vision again with the same overall shape.
 *
 * Why server-side: keeps the OCR.space API key out of the browser. It's a
 * much lower-stakes key than a cloud-billing-linked one (worst case if
 * leaked: someone burns your free monthly quota), but there's no reason to
 * expose it when a tiny proxy avoids that entirely.
 *
 * Environment variables (Vercel dashboard → Project → Settings → Environment Variables):
 *   OCR_SPACE_API_KEY — free key from https://ocr.space/ocrapi/freekey
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

const OCR_SPACE_ENDPOINT = 'https://api.ocr.space/parse/image';

// OCR.space's free tier caps uploads at 1MB — well under Cloud Vision's old
// limit, so the client-side resize step must compress harder to fit this.
const MAX_BASE64_LENGTH = Math.ceil((1 * 1024 * 1024) * 1.4); // ~1MB binary, base64-inflated

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed — use POST.' });
    return;
  }

  const apiKey = process.env.OCR_SPACE_API_KEY;
  if (!apiKey) {
    console.error('[ocr-scan] Missing OCR_SPACE_API_KEY env var');
    res.status(500).json({ error: 'OCR service is not configured. Please contact support.' });
    return;
  }

  let body = req.body;
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
    // OCR.space expects the base64 string prefixed with its data URI content
    // type (e.g. "data:image/jpeg;base64,...") — a bare base64 string is
    // rejected with "Not a valid base64 image."
    const dataUri = `data:image/jpeg;base64,${imageBase64}`;

    const params = new URLSearchParams({
      base64Image: dataUri,
      // Auto-detect rather than hardcoding one language: this same endpoint
      // handles both passport scans (mostly Latin MRZ text) and NID scans
      // (mostly Arabic), and Engine 2/3 support automatic language detection.
      language: 'auto',
      OCREngine: '2',       // Best balance for ID/MRZ documents per OCR.space's own guidance
      scale: 'true',        // Internal upscaling — helps accuracy on small/low-res phone photos
      isTable: 'false',
    });

    const ocrRes = await fetch(OCR_SPACE_ENDPOINT, {
      method: 'POST',
      headers: {
        'apikey': apiKey,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
    });

    const ocrData = await ocrRes.json().catch(() => null);

    if (!ocrRes.ok || !ocrData) {
      console.error('[ocr-scan] OCR.space HTTP error:', ocrRes.status, ocrData);
      res.status(502).json({ error: 'OCR provider returned an error. Please try again.' });
      return;
    }

    if (ocrData.IsErroredOnProcessing) {
      console.error('[ocr-scan] OCR.space processing error:', ocrData.ErrorMessage, ocrData.ErrorDetails);
      res.status(502).json({ error: 'OCR provider could not process this image.' });
      return;
    }

    // Concatenate ParsedText across all returned results (normally just one
    // for a single image) — same shape parsePassport()/parseNID() expect.
    const text = (ocrData.ParsedResults || [])
      .map(r => r.ParsedText || '')
      .join('\n');

    res.status(200).json({ text });
  } catch (err) {
    console.error('[ocr-scan] Unexpected error:', err);
    res.status(500).json({ error: 'Unexpected error while processing the image.' });
  }
};
