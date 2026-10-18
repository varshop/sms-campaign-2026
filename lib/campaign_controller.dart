import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/recipient.dart';
import '../utils/text_utils.dart';
import 'sms_sender.dart';

enum CampaignState { idle, waiting, running, finished, stopped }

/// يدير الحملة: الانتظار حتى وقت البدء، الإرسال واحدةً واحدة بفاصل عشوائي،
/// وحفظ التقدم لاستئناف الحملة لو أُغلق التطبيق.
class CampaignController extends ChangeNotifier {
  CampaignController(this._sender);

  static const String _prefsKey = 'campaign_v2';

  final SmsSender _sender;
  final Random _rnd = Random();

  List<Recipient> recipients = [];
  String template = '';
  int minGapSec = 600;
  int maxGapSec = 780;
  DateTime? startAt;
  DateTime? nextSendAt;
  CampaignState state = CampaignState.idle;
  String? lastError;
  bool _stopRequested = false;

  bool get isActive =>
      state == CampaignState.waiting || state == CampaignState.running;

  int get total => recipients.length;
  int get sent => _count(SendStatus.sent);
  int get failed => _count(SendStatus.failed);
  int get pending => _count(SendStatus.pending);
  double get progress => total == 0 ? 0 : (sent + failed) / total;

  int _count(SendStatus s) => recipients.where((r) => r.status == s).length;

  Future<bool> requestSmsPermission() => _sender.requestPermission();

  /// بدء حملة جديدة. يكتمل الـ Future عند انتهاء الحملة أو إيقافها.
  Future<void> start({
    required List<Recipient> list,
    required String template,
    required int minGapSec,
    required int maxGapSec,
    DateTime? startAt,
  }) async {
    if (isActive) return;
    recipients = list;
    this.template = template;
    this.minGapSec = minGapSec;
    this.maxGapSec = maxGapSec < minGapSec ? minGapSec : maxGapSec;
    this.startAt = startAt;
    await _run();
  }

  /// استئناف الرسائل المتبقية (بدون انتظار وقت بدء).
  Future<void> resume() async {
    if (isActive || pending == 0) return;
    if (!await _sender.requestPermission()) {
      lastError = 'صلاحية إرسال الرسائل غير ممنوحة';
      notifyListeners();
      return;
    }
    startAt = null;
    await _run();
  }

  void stop() {
    if (isActive) _stopRequested = true;
  }

  Future<void> clear() async {
    if (isActive) return;
    recipients = [];
    state = CampaignState.idle;
    lastError = null;
    nextSendAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }

  Future<void> _run() async {
    _stopRequested = false;
    lastError = null;
    nextSendAt = null;
    state = CampaignState.waiting;
    notifyListeners();
    await WakelockPlus.enable();

    try {
      final at = startAt;
      if (at != null) await _waitUntil(at);

      state = CampaignState.running;
      notifyListeners();

      for (var i = 0; i < recipients.length; i++) {
        if (_stopRequested) break;
        final r = recipients[i];
        if (r.status != SendStatus.pending) continue;

        r.status = SendStatus.sending;
        r.error = null;
        nextSendAt = null;
        notifyListeners();
        await _persist();

        var fatal = false;
        try {
          await _sender.send(r.phone, renderTemplate(template, r.vars));
          r.status = SendStatus.sent;
        } on SmsSendException catch (e) {
          r.status = SendStatus.failed;
          r.error = e.message;
          if (e.fatal) {
            fatal = true;
            lastError = e.message;
          }
        } catch (e) {
          r.status = SendStatus.failed;
          r.error = 'خطأ غير متوقع';
        }
        notifyListeners();
        await _persist();

        if (fatal) {
          // الرسالة الحالية لم تُرسل بسبب خطأ عام: أعدها للانتظار لتُستأنف لاحقاً
          r.status = SendStatus.pending;
          r.error = null;
          break;
        }
        if (_stopRequested) break;

        final hasMore =
            recipients.skip(i + 1).any((x) => x.status == SendStatus.pending);
        if (hasMore) {
          final extra = maxGapSec > minGapSec
              ? _rnd.nextInt(maxGapSec - minGapSec + 1)
              : 0;
          final next = DateTime.now().add(Duration(seconds: minGapSec + extra));
          nextSendAt = next;
          notifyListeners();
          await _waitUntil(next);
        }
      }
    } catch (e) {
      lastError = 'توقفت الحملة بسبب خطأ غير متوقع';
    } finally {
      await WakelockPlus.disable();
      nextSendAt = null;
      state = (_stopRequested || pending > 0)
          ? CampaignState.stopped
          : CampaignState.finished;
      notifyListeners();
      await _persist();
    }
  }

  Future<void> _waitUntil(DateTime t) async {
    while (!_stopRequested && DateTime.now().isBefore(t)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        't': template,
        'min': minGapSec,
        'max': maxGapSec,
        'r': recipients.map((e) => e.toJson()).toList(),
      }),
    );
  }

  /// يحمّل آخر حملة محفوظة. يعيد true إن وُجدت.
  Future<bool> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return false;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      template = json['t'] as String? ?? '';
      minGapSec = json['min'] as int? ?? 600;
      maxGapSec = json['max'] as int? ?? 780;
      recipients = (json['r'] as List)
          .map((e) => Recipient.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      for (final r in recipients) {
        if (r.status == SendStatus.sending) {
          r.status = SendStatus.failed;
          r.error = 'لم يُؤكَّد الإرسال (أُغلق التطبيق أثناءه)';
        }
      }
      if (recipients.isEmpty) return false;
      state = pending > 0 ? CampaignState.stopped : CampaignState.finished;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}
