/// أدوات مساعدة للأرقام والنصوص.

const String _arabicIndicDigits = '٠١٢٣٤٥٦٧٨٩';
const String _persianDigits = '۰۱۲۳۴۵۶۷۸۹';

/// تحويل الأرقام العربية/الفارسية (٠١٢٣...) إلى أرقام لاتينية (0123...).
String toLatinDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    final arabic = _arabicIndicDigits.indexOf(ch);
    if (arabic >= 0) {
      buffer.write(arabic);
      continue;
    }
    final persian = _persianDigits.indexOf(ch);
    if (persian >= 0) {
      buffer.write(persian);
      continue;
    }
    buffer.write(ch);
  }
  return buffer.toString();
}

/// تنظيف رقم الهاتف، وإضافة رمز الدولة إن كان معرّفاً ولم يكن الرقم دولياً.
String normalizePhone(String raw, String countryCode) {
  var p = toLatinDigits(raw).replaceAll(RegExp(r'[^\d+]'), '');
  if (p.startsWith('00')) p = '+${p.substring(2)}';

  final cc = toLatinDigits(countryCode).replaceAll(RegExp(r'\D'), '');
  if (cc.isNotEmpty && !p.startsWith('+')) {
    if (p.startsWith('0')) p = p.substring(1);
    if (!p.startsWith(cc)) p = '$cc$p';
    p = '+$p';
  }
  return p;
}

bool isValidPhone(String phone) => RegExp(r'^\+?\d{7,15}$').hasMatch(phone);

/// استبدال {license} و{B} و{A} ... بقيم الصف (غير حساس لحالة الأحرف).
String renderTemplate(String template, Map<String, String> vars) {
  final lower = {for (final e in vars.entries) e.key.toLowerCase(): e.value};
  return template.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (m) => lower[m.group(1)!.toLowerCase()] ?? m.group(0)!,
  );
}

/// تقدير عدد الأحرف وعدد أجزاء الرسالة (العربية = 70 حرفاً للجزء الواحد).
({int chars, int parts}) smsLength(String text) {
  final n = text.runes.length;
  if (n == 0) return (chars: 0, parts: 0);
  final unicode = text.runes.any((r) => r > 127);
  final single = unicode ? 70 : 160;
  final multi = unicode ? 67 : 153;
  final parts = n <= single ? 1 : (n / multi).ceil();
  return (chars: n, parts: parts);
}

String formatDurationAr(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0 && m == 0) return 'أقل من دقيقة';
  if (h == 0) return '$m دقيقة';
  if (m == 0) return '$h ساعة';
  return '$h ساعة و$m دقيقة';
}

String formatCountdown(Duration d) {
  if (d.isNegative) return '00:00';
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatDateTime(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
}
