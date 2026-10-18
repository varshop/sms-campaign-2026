import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;

import '../models/recipient.dart';
import '../utils/text_utils.dart';

class ParseResult {
  const ParseResult(this.recipients, this.invalid);

  final List<Recipient> recipients;
  final int invalid;
}

/// تحويل النص إلى مستلمين. كل سطر: `الهاتف` أو `الهاتف,قيمة B,قيمة C ...`
/// الفاصل يمكن أن يكون فاصلة أو tab أو فاصلة منقوطة.
/// السطر الأول يُتجاهل تلقائياً إن بدا عنواناً (لا يحتوي رقماً).
ParseResult parseRecipients(String raw, {String countryCode = ''}) {
  final out = <Recipient>[];
  var invalid = 0;
  var isFirstLine = true;

  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final text = line.trim();
    if (text.isEmpty) continue;

    final cols = text.split(RegExp(r'[,\t;]')).map((e) => e.trim()).toList();
    final firstLine = isFirstLine;
    isFirstLine = false;

    final digits = toLatinDigits(cols.first).replaceAll(RegExp(r'\D'), '');
    if (firstLine && digits.length < 6) continue; // صف عناوين

    final phone = normalizePhone(cols.first, countryCode);
    if (!isValidPhone(phone)) {
      invalid++;
      continue;
    }

    final vars = <String, String>{};
    for (var i = 0; i < cols.length && i < 26; i++) {
      vars[String.fromCharCode(65 + i)] = cols[i]; // A, B, C ...
    }
    final b = cols.length > 1 ? cols[1] : '';
    vars['phone'] = phone;
    vars['license'] = b;
    vars['code'] = b;
    vars['name'] = b;

    out.add(Recipient(phone: phone, vars: vars));
  }
  return ParseResult(out, invalid);
}

/// تحويل ملف xlsx أو csv إلى نص بصيغة أسطر (العمود A ثم B ثم C ... مفصولة بفاصلة).
String tableFileToText(Uint8List bytes, String extension) {
  if (extension.toLowerCase() == 'csv') {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text.replaceAll('"', '').replaceAll('\r\n', '\n').trim();
  }

  final book = xl.Excel.decodeBytes(bytes);
  if (book.tables.isEmpty) return '';
  final sheet = book.tables[book.tables.keys.first]!;

  final lines = <String>[];
  for (final row in sheet.rows) {
    final cells = row.map((cell) => _cellText(cell?.value)).toList();
    while (cells.isNotEmpty && cells.last.isEmpty) {
      cells.removeLast();
    }
    if (cells.isEmpty || cells.first.isEmpty) continue;
    lines.add(cells.join(','));
  }
  return lines.join('\n');
}

String _cellText(dynamic cell) {
  if (cell == null) return '';
  dynamic raw;
  try {
    raw = cell.value; // CellValue.value (نص / رقم / ...)
  } catch (_) {
    raw = cell;
  }
  if (raw == null) return '';

  String text;
  if (raw is double && raw == raw.truncateToDouble()) {
    text = raw.toInt().toString(); // أرقام الهواتف قد تأتي كـ double
  } else if (raw is String || raw is num || raw is bool) {
    text = raw.toString();
  } else {
    text = raw.toString();
    if (text.startsWith('TextSpan')) {
      try {
        final t = (raw as dynamic).text;
        if (t is String) text = t;
      } catch (_) {}
    }
  }
  // منع كسر صيغة الأسطر
  return text.replaceAll(RegExp(r'[,;\t\r\n]'), ' ').trim();
}
