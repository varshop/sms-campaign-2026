import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/campaign_controller.dart';
import '../services/contacts_parser.dart';
import '../utils/text_utils.dart';
import '../widgets/progress_card.dart';
import '../widgets/section_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final CampaignController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _numbers = TextEditingController();
  final _countryCode = TextEditingController();
  final _template = TextEditingController(
    text: 'مرحباً، رقم ترخيص اشتراكك هو: {license}',
  );
  final _minGap = TextEditingController(text: '10');
  final _maxGap = TextEditingController(text: '13');

  ParseResult _parsed = const ParseResult([], 0);
  bool _startNow = true;
  DateTime? _startAt;

  CampaignController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // عند وجود حملة محفوظة: أعد تعبئة القالب والفواصل
    if (_c.recipients.isNotEmpty) {
      _template.text = _c.template;
      _minGap.text = _minutesText(_c.minGapSec);
      _maxGap.text = _minutesText(_c.maxGapSec);
    }
  }

  @override
  void dispose() {
    _numbers.dispose();
    _countryCode.dispose();
    _template.dispose();
    _minGap.dispose();
    _maxGap.dispose();
    super.dispose();
  }

  String _minutesText(int seconds) {
    final m = seconds / 60;
    return m == m.roundToDouble() ? m.round().toString() : m.toStringAsFixed(2);
  }

  double? _parseNumber(String s) => double.tryParse(
        toLatinDigits(s).replaceAll('٫', '.').replaceAll(',', '.').trim(),
      );

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _reparse() {
    setState(() {
      _parsed = parseRecipients(
        _numbers.text,
        countryCode: _countryCode.text,
      );
    });
  }

  Future<void> _importFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'csv'],
        withData: true,
      );
      final file = res?.files.single;
      if (file == null || file.bytes == null) return;
      final text = tableFileToText(file.bytes!, file.extension ?? '');
      _numbers.text = text;
      _reparse();
      if (!mounted) return;
      _snack('تم استيراد ${_parsed.recipients.length} رقم من ${file.name}');
    } catch (e) {
      if (!mounted) return;
      _snack('تعذّرت قراءة الملف. تأكد أنه xlsx أو csv صالح');
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (!mounted) return;
      _snack('الحافظة فارغة');
      return;
    }
    final current = _numbers.text.trimRight();
    _numbers.text = current.isEmpty ? text.trim() : '$current\n${text.trim()}';
    _reparse();
  }

  void _insertVariable(String v) {
    final sel = _template.selection;
    final start = sel.isValid ? sel.start : _template.text.length;
    final end = sel.isValid ? sel.end : _template.text.length;
    _template.value = _template.value.copyWith(
      text: _template.text.replaceRange(start, end, v),
      selection: TextSelection.collapsed(offset: start + v.length),
    );
    setState(() {});
  }

  Future<void> _pickStartTime() async {
    final base = _startAt ?? DateTime.now().add(const Duration(minutes: 5));
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    setState(() {
      _startAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _start() async {
    final list = _parsed.recipients;
    if (list.isEmpty) return _snack('أدخل أو استورد أرقاماً صالحة أولاً');
    if (_template.text.trim().isEmpty) return _snack('اكتب نص الرسالة');

    final mn = _parseNumber(_minGap.text);
    final mx = _parseNumber(_maxGap.text);
    if (mn == null || mx == null || mn <= 0 || mx < mn) {
      return _snack('الفاصل الزمني غير صحيح (الأقصى يجب أن يساوي الأدنى أو يزيد)');
    }
    final minSec = (mn * 60).round().clamp(1, 86400);
    final maxSec = (mx * 60).round().clamp(minSec, 86400);

    DateTime? startAt;
    if (!_startNow) {
      if (_startAt == null) return _snack('اختر وقت البدء');
      if (_startAt!.isAfter(DateTime.now())) startAt = _startAt;
    }

    final granted = await _c.requestSmsPermission();
    if (!mounted) return;
    if (!granted) {
      await _showPermissionDialog();
      return;
    }

    final avgSec = (minSec + maxSec) / 2;
    final estimate = Duration(seconds: (avgSec * (list.length - 1)).round());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('بدء الحملة؟'),
        content: Text(
          'سيتم إرسال ${list.length} رسالة.\n'
          'المدة التقريبية: ${formatDurationAr(estimate)}.\n\n'
          'أبقِ التطبيق مفتوحاً؛ ستبقى الشاشة مضاءة حتى انتهاء الحملة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ابدأ'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    unawaited(
      _c.start(
        list: list,
        template: _template.text,
        minGapSec: minSec,
        maxGapSec: maxSec,
        startAt: startAt,
      ),
    );
  }

  Future<void> _showPermissionDialog() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('صلاحية الرسائل مطلوبة'),
        content: const Text(
          'لم يتم منح صلاحية إرسال الرسائل. فعّلها من إعدادات التطبيق '
          '(الأذونات ← الرسائل القصيرة SMS) ثم أعد المحاولة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إغلاق'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('فتح الإعدادات'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final active = _c.isActive;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;

        final first =
            _parsed.recipients.isNotEmpty ? _parsed.recipients.first : null;
        final preview = first == null
            ? _template.text
            : renderTemplate(_template.text, first.vars);
        final len = smsLength(preview);

        return Scaffold(
          appBar: AppBar(title: const Text('حملات رسائل SMS')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ١) المستلمون
                SectionCard(
                  title: 'المستلمون',
                  icon: Icons.people_alt_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _numbers,
                        enabled: !active,
                        minLines: 5,
                        maxLines: 8,
                        keyboardType: TextInputType.multiline,
                        textDirection: TextDirection.ltr,
                        onChanged: (_) => _reparse(),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: '0501234567,ABC-123\n0507654321,XYZ-456',
                          helperText:
                              'رقم في كل سطر. القيمة بعد الفاصلة هي العمود B',
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: active ? null : _importFile,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('استيراد Excel / CSV'),
                          ),
                          OutlinedButton.icon(
                            onPressed: active ? null : _paste,
                            icon: const Icon(Icons.content_paste),
                            label: const Text('لصق'),
                          ),
                          TextButton.icon(
                            onPressed: active
                                ? null
                                : () {
                                    _numbers.clear();
                                    _reparse();
                                  },
                            icon: const Icon(Icons.clear),
                            label: const Text('مسح'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _countryCode,
                        enabled: !active,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => _reparse(),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'رمز الدولة (اختياري، مثال: 966)',
                          helperText:
                              'يُضاف للأرقام التي لا تبدأ بـ + أو 00',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_parsed.recipients.length} رقم صالح'
                        '${_parsed.invalid > 0 ? '  •  ${_parsed.invalid} سطر غير صالح' : ''}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _parsed.invalid > 0
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                // ٢) الرسالة
                SectionCard(
                  title: 'نص الرسالة',
                  icon: Icons.sms_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _template,
                        enabled: !active,
                        minLines: 3,
                        maxLines: 6,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'اكتب نص الرسالة هنا',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('إدراج متغير:'),
                          for (final v in const ['{license}', '{B}', '{A}'])
                            ActionChip(
                              label: Text(v),
                              onPressed: active ? null : () => _insertVariable(v),
                            ),
                        ],
                      ),
                      if (first != null) ...[
                        const SizedBox(height: 12),
                        Text('معاينة (أول مستلم):',
                            style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(preview),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '${len.chars} حرف  •  ≈ ${len.parts} رسالة لكل مستلم',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),

                // ٣) الجدولة
                SectionCard(
                  title: 'الجدولة والفاصل الزمني',
                  icon: Icons.schedule,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment<bool>(
                              value: true, label: Text('ابدأ الآن')),
                          ButtonSegment<bool>(
                              value: false, label: Text('وقت محدد')),
                        ],
                        selected: {_startNow},
                        onSelectionChanged: active
                            ? null
                            : (s) {
                                setState(() => _startNow = s.first);
                                if (!s.first && _startAt == null) {
                                  _pickStartTime();
                                }
                              },
                      ),
                      if (!_startNow) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: active ? null : _pickStartTime,
                          icon: const Icon(Icons.event),
                          label: Text(
                            _startAt == null
                                ? 'اختر وقت البدء'
                                : formatDateTime(_startAt!),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _minGap,
                              enabled: !active,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: 'أقل فاصل (دقيقة)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _maxGap,
                              enabled: !active,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: 'أعلى فاصل (دقيقة)',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'يُختار فاصل عشوائي بين الرقمين. لفاصل ثابت اكتب الرقم نفسه في الحقلين.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),

                // أزرار التحكم
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: active ? null : _start,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('بدء الحملة'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: active ? _c.stop : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('إيقاف'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ٤) التقدم
                ProgressCard(controller: _c),
              ],
            ),
          ),
        );
      },
    );
  }
}
