import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:another_telephony/telephony.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ════════════════════════════════════════════════════════════════
// 1) النماذج وحفظ الحالة
// ════════════════════════════════════════════════════════════════

const kCampaignKey = 'campaign_v1';

class Recipient {
  String phone;
  Map<String, String> vars;
  String status; // pending | sending | sent | failed
  String? error;

  Recipient({
    required this.phone,
    required this.vars,
    this.status = 'pending',
    this.error,
  });

  Map<String, dynamic> toJson() =>
      {'p': phone, 'v': vars, 's': status, 'e': error};

  factory Recipient.fromJson(Map<String, dynamic> j) => Recipient(
        phone: j['p'],
        vars: Map<String, String>.from(j['v']),
        status: j['s'],
        error: j['e'],
      );
}

class Campaign {
  String template;
  int minSec;
  int maxSec;
  int startMs;
  int nextSendMs;
  bool running;
  List<Recipient> recipients;

  Campaign({
    required this.template,
    required this.minSec,
    required this.maxSec,
    required this.startMs,
    required this.recipients,
    this.nextSendMs = 0,
    this.running = false,
  });

  int get sent => recipients.where((r) => r.status == 'sent').length;
  int get failed => recipients.where((r) => r.status == 'failed').length;
  int get pending => recipients.where((r) => r.status == 'pending').length;

  Map<String, dynamic> toJson() => {
        't': template,
        'min': minSec,
        'max': maxSec,
        'start': startMs,
        'next': nextSendMs,
        'run': running,
        'r': recipients.map((e) => e.toJson()).toList(),
      };

  factory Campaign.fromJson(Map<String, dynamic> j) => Campaign(
        template: j['t'],
        minSec: j['min'],
        maxSec: j['max'],
        startMs: j['start'],
        nextSendMs: j['next'] ?? 0,
        running: j['run'] ?? false,
        recipients: (j['r'] as List)
            .map((e) => Recipient.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

Future<void> saveCampaign(Campaign c) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(kCampaignKey, jsonEncode(c.toJson()));
}

Future<Campaign?> loadCampaign() async {
  final p = await SharedPreferences.getInstance();
  await p.reload(); // مهم: لقراءة ما كتبته عملية الخلفية
  final raw = p.getString(kCampaignKey);
  if (raw == null) return null;
  return Campaign.fromJson(jsonDecode(raw));
}

/// استبدال {license} أو {B} أو {A} ... بقيم الصف
String renderTemplate(String template, Recipient r) {
  final m = {for (final e in r.vars.entries) e.key.toLowerCase(): e.value};
  return template.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (x) => m[x.group(1)!.toLowerCase()] ?? x.group(0)!,
  );
}

String normalizePhone(String raw, String countryCode) {
  var p = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (p.startsWith('00')) p = '+${p.substring(2)}';
  if (countryCode.isNotEmpty && !p.startsWith('+')) {
    if (p.startsWith('0')) p = p.substring(1);
    p = '+$countryCode$p';
  }
  return p;
}

// ════════════════════════════════════════════════════════════════
// 2) قراءة ملف Excel / CSV
// ════════════════════════════════════════════════════════════════

String _cellText(dynamic raw) {
  if (raw == null) return '';
  if (raw is String) return raw.trim();
  if (raw is double && raw == raw.truncateToDouble()) {
    return raw.toInt().toString(); // الأرقام قد تأتي كـ double
  }
  if (raw is num || raw is bool) return raw.toString();
  final s = raw.toString();
  if (s.startsWith('TextSpan')) {
    try {
      final t = (raw as dynamic).text;
      if (t is String) return t.trim();
    } catch (_) {}
  }
  return s.trim();
}

List<List<String>> _readRows(Uint8List bytes, String ext) {
  if (ext.toLowerCase() == 'csv') {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n');
    final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(text);
    return rows
        .map((r) => r.map((e) => e.toString().trim()).toList())
        .toList();
  }
  final book = xl.Excel.decodeBytes(bytes);
  final sheet = book.tables[book.tables.keys.first]!;
  return sheet.rows
      .map((r) => r.map((cell) => _cellText((cell?.value as dynamic)?.value)).toList())
      .toList();
}

/// العمود A = الهاتف، العمود B = الترخيص/البيانات، وبقية الأعمدة C, D ...
List<Recipient> parseContacts(Uint8List bytes, String ext) {
  final rows = _readRows(bytes, ext);
  final out = <Recipient>[];
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row.isEmpty || row[0].isEmpty) continue;
    final digits = row[0].replaceAll(RegExp(r'\D'), '');
    if (i == 0 && digits.length < 6) continue; // صف العناوين
    final vars = <String, String>{};
    for (var c = 0; c < row.length && c < 26; c++) {
      vars[String.fromCharCode(65 + c)] = row[c]; // A, B, C ...
    }
    final b = row.length > 1 ? row[1] : '';
    vars['phone'] = row[0];
    vars['license'] = b;
    vars['code'] = b;
    vars['name'] = b;
    out.add(Recipient(phone: row[0], vars: vars));
  }
  return out;
}

// ════════════════════════════════════════════════════════════════
// 3) خدمة الإرسال في الخلفية
// ════════════════════════════════════════════════════════════════

Future<void> initService() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      initialNotificationTitle: 'حملة الرسائل',
      initialNotificationContent: 'جاري التحضير...',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  var stop = false;
  service.on('stop').listen((_) => stop = true);

  void notify(String text) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
          title: 'حملة الرسائل', content: text);
    }
  }

  final c = await loadCampaign();
  if (c == null) {
    service.stopSelf();
    return;
  }

  c.running = true;
  await saveCampaign(c);
  service.invoke('update');

  final telephony = Telephony.instance;
  final rnd = Random();

  // انتظار وقت البدء
  while (!stop && DateTime.now().millisecondsSinceEpoch < c.startMs) {
    final left = Duration(
        milliseconds: c.startMs - DateTime.now().millisecondsSinceEpoch);
    notify('سيبدأ الإرسال بعد ${left.inMinutes} دقيقة');
    await Future.delayed(const Duration(seconds: 1));
  }

  for (var i = 0; i < c.recipients.length && !stop; i++) {
    final r = c.recipients[i];
    if (r.status != 'pending') continue;

    r.status = 'sending'; // يمنع التكرار لو أُوقفت الخدمة أثناء الإرسال
    await saveCampaign(c);
    try {
      await telephony.sendSms(
        to: r.phone,
        message: renderTemplate(c.template, r),
        isMultipart: true,
      );
      r.status = 'sent';
    } catch (e) {
      r.status = 'failed';
      r.error = e.toString();
    }

    final hasMore = c.recipients.skip(i + 1).any((x) => x.status == 'pending');
    if (hasMore) {
      final secs = c.minSec + rnd.nextInt(c.maxSec - c.minSec + 1);
      c.nextSendMs = DateTime.now().millisecondsSinceEpoch + secs * 1000;
    } else {
      c.nextSendMs = 0;
    }
    await saveCampaign(c);
    service.invoke('update');
    notify('أُرسل ${c.sent} • فشل ${c.failed} • متبقي ${c.pending}');

    // انتظار الفاصل العشوائي مع إمكانية الإيقاف
    while (!stop && DateTime.now().millisecondsSinceEpoch < c.nextSendMs) {
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  c.running = false;
  c.nextSendMs = 0;
  await saveCampaign(c);
  service.invoke('update');
  notify(stop ? 'تم إيقاف الحملة' : 'اكتملت الحملة');
  await Future.delayed(const Duration(seconds: 2));
  service.stopSelf();
}

// ════════════════════════════════════════════════════════════════
// 4) الواجهة
// ════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initService();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'حملة الرسائل',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Recipient> _recipients = [];
  String? _fileName;
  final _tpl = TextEditingController(
      text: 'مرحباً، رقم ترخيص اشتراكك هو: {license}');
  final _min = TextEditingController(text: '10');
  final _max = TextEditingController(text: '13');
  final _cc = TextEditingController();
  DateTime _start = DateTime.now().add(const Duration(minutes: 2));
  Campaign? _campaign;
  Timer? _ticker;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = FlutterBackgroundService().on('update').listen((_) => _refresh());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _campaign?.running == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final c = await loadCampaign();
    if (mounted) setState(() => _campaign = c);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'csv'],
      withData: true,
    );
    if (res == null || res.files.single.bytes == null) return;
    final f = res.files.single;
    try {
      final list = parseContacts(f.bytes!, f.extension ?? '');
      setState(() {
        _recipients = list;
        _fileName = f.name;
      });
      if (list.isEmpty) _snack('لم يتم العثور على أرقام في العمود A');
    } catch (e) {
      _snack('تعذّرت قراءة الملف: $e');
    }
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (t == null) return;
    setState(() => _start = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _startCampaign() async {
    if (_recipients.isEmpty) return _snack('ارفع ملف الأرقام أولاً');
    if (_tpl.text.trim().isEmpty) return _snack('اكتب نص الرسالة');
    final mn = double.tryParse(_min.text.trim());
    final mx = double.tryParse(_max.text.trim());
    if (mn == null || mx == null || mn <= 0 || mx < mn) {
      return _snack('الفاصل الزمني غير صحيح (الأقصى ≥ الأدنى)');
    }
    final svc = FlutterBackgroundService();
    if (await svc.isRunning()) {
      return _snack('هناك حملة قيد التشغيل، أوقفها أولاً');
    }

    final sms = await Permission.sms.request();
    if (!sms.isGranted) return _snack('صلاحية إرسال SMS مطلوبة');
    await Permission.notification.request();

    final cc = _cc.text.trim().replaceAll('+', '');
    final list = _recipients
        .map((r) => Recipient(
            phone: normalizePhone(r.phone, cc), vars: Map.of(r.vars)))
        .where((r) => r.phone.replaceAll('+', '').length >= 7)
        .toList();
    if (list.isEmpty) return _snack('لا توجد أرقام صالحة');

    final c = Campaign(
      template: _tpl.text,
      minSec: (mn * 60).round(),
      maxSec: (mx * 60).round(),
      startMs: _start.millisecondsSinceEpoch,
      recipients: list,
      running: true,
    );
    await saveCampaign(c);
    await svc.startService();
    await _refresh();
  }

  void _stop() => FlutterBackgroundService().invoke('stop');

  String _fmt(DateTime d) => d.toString().substring(0, 16);

  @override
  Widget build(BuildContext context) {
    final c = _campaign;
    final running = c?.running == true;
    final preview = _recipients.isNotEmpty
        ? renderTemplate(_tpl.text, _recipients.first)
        : '';

    return Scaffold(
      appBar: AppBar(title: const Text('حملة رسائل SMS')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ١) الملف
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('١) ملف الأرقام (A = الهاتف، B = الترخيص)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: running ? null : _pickFile,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('رفع ملف Excel / CSV'),
                  ),
                  if (_fileName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('$_fileName — ${_recipients.length} رقم'),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _cc,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'رمز الدولة (اختياري، مثال: 966)',
                      helperText:
                          'يُضاف للأرقام التي لا تحتوي على + أو 00 في بدايتها',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ٢) القالب
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('٢) نص الرسالة',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _tpl,
                    maxLines: 4,
                    onChanged: (_) => setState(() {}),
                    decoration:
                        const InputDecoration(border: OutlineInputBorder()),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final v in ['{license}', '{B}', '{A}'])
                        ActionChip(
                          label: Text(v),
                          onPressed: () {
                            _tpl.text += v;
                            _tpl.selection = TextSelection.collapsed(
                                offset: _tpl.text.length);
                            setState(() {});
                          },
                        ),
                    ],
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('معاينة (أول عميل):',
                        style: Theme.of(context).textTheme.labelMedium),
                    Text(preview),
                  ],
                ],
              ),
            ),
          ),
          // ٣) الجدولة
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('٣) الجدولة',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: running ? null : _pickStart,
                    icon: const Icon(Icons.schedule),
                    label: Text('وقت البدء: ${_fmt(_start)}'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _min,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'أقل فاصل (دقيقة)',
                              border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _max,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'أعلى فاصل (دقيقة)',
                              border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'لفاصل ثابت اكتب نفس الرقم في الحقلين (مثلاً 10 و 10).',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: running ? null : _startCampaign,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('بدء الحملة'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: running ? _stop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('إيقاف'),
                ),
              ),
            ],
          ),
          // ٤) الحالة
          if (c != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(running ? 'الحملة تعمل' : 'الحملة متوقفة/منتهية',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: c.recipients.isEmpty
                          ? 0
                          : (c.sent + c.failed) / c.recipients.length,
                    ),
                    const SizedBox(height: 8),
                    Text(
                        'أُرسل: ${c.sent}   فشل: ${c.failed}   متبقي: ${c.pending}'),
                    if (running) _countdown(c),
                    const Divider(),
                    SizedBox(
                      height: 280,
                      child: ListView.builder(
                        itemCount: c.recipients.length,
                        itemBuilder: (_, i) {
                          final r = c.recipients[i];
                          return ListTile(
                            dense: true,
                            leading: _statusIcon(r.status),
                            title: Text(r.phone),
                            subtitle: Text(
                                r.status == 'failed' && r.error != null
                                    ? r.error!
                                    : _statusText(r.status)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _countdown(Campaign c) {
    final now = DateTime.now().millisecondsSinceEpoch;
    String mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    if (now < c.startMs) {
      return Text('يبدأ الإرسال بعد ${mmss(((c.startMs - now) / 1000).ceil())}');
    }
    if (c.nextSendMs > now) {
      return Text(
          'الرسالة التالية بعد ${mmss(((c.nextSendMs - now) / 1000).ceil())}');
    }
    return const SizedBox.shrink();
  }

  Icon _statusIcon(String s) => switch (s) {
        'sent' => const Icon(Icons.check_circle, color: Colors.green),
        'failed' => const Icon(Icons.error, color: Colors.red),
        'sending' => const Icon(Icons.sync, color: Colors.orange),
        _ => const Icon(Icons.hourglass_empty, color: Colors.grey),
      };

  String _statusText(String s) => switch (s) {
        'sent' => 'تم الإرسال',
        'failed' => 'فشل',
        'sending' => 'جاري الإرسال',
        _ => 'في الانتظار',
      };
}
