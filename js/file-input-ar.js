/**
 * file-input-ar.js — توسم input[type=file] بـ data-has-file عند اختيار ملف
 * يُستخدم مع custom.css لإخفاء النص الوهمي "اختر ملفاً" وإظهار اسم الملف الفعلي.
 */
document.addEventListener('change', function (e) {
  if (e.target && e.target.tagName === 'INPUT' && e.target.type === 'file') {
    if (e.target.files && e.target.files.length > 0) {
      e.target.setAttribute('data-has-file', '1');
    } else {
      e.target.removeAttribute('data-has-file');
    }
  }
}, true);

// Tag any file inputs already populated when the page/script loads (e.g. restored drafts)
document.addEventListener('DOMContentLoaded', function () {
  document.querySelectorAll('input[type="file"]').forEach(function (inp) {
    if (inp.files && inp.files.length > 0) inp.setAttribute('data-has-file', '1');
  });
});
