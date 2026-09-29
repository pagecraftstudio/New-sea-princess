/**
 * contact-config.js
 * مصدر واحد للأرقام — كل wa.me في الموقع يمر من هنا
  *
 * ─────────────────────────────────────────────────────────
 * © 2026 New Sea Princess Tourism & Pagecraft Studio Team. All rights reserved.
 * Unauthorized copying, modification, or distribution of
 * this file or any part of this project, via any medium,
 * is strictly prohibited without written permission.
 * ─────────────────────────────────────────────────────────
 */
window.NSP_CONTACTS = {
  general:  '201555154996',  // استفسارات عامة — الهيدر، صفحة "من نحن"، "تواصل معنا"
  booking:  '201031777295',  // تأكيد الحجوزات والدفع
  urgent:   '201093475254',  // طوارئ وحالات عاجلة — صفحة التتبع
};

/**
 * waLink(context, extraText?)
 * @param {'general'|'booking'|'urgent'} context
 * @param {string} [extraText] - رسالة واتساب مسبقة
 * @returns {string} رابط wa.me جاهز
 */
window.waLink = function(context, extraText) {
  var num  = (window.NSP_CONTACTS && window.NSP_CONTACTS[context])
           || window.NSP_CONTACTS.general;
  var text = extraText ? '?text=' + encodeURIComponent(extraText) : '';
  return 'https://wa.me/' + num + text;
};
