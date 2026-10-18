import 'dart:async';

import 'package:flutter/material.dart';

import '../models/recipient.dart';
import '../services/campaign_controller.dart';
import '../utils/text_utils.dart';
import 'section_card.dart';

/// شريط التقدم وحالة كل رقم.
class ProgressCard extends StatefulWidget {
  const ProgressCard({super.key, required this.controller});

  final CampaignController controller;

  @override
  State<ProgressCard> createState() => _ProgressCardState();
}

class _ProgressCardState extends State<ProgressCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // تحديث العدّاد التنازلي كل ثانية أثناء الحملة
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.isActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _stateLabel(CampaignState s) => switch (s) {
        CampaignState.idle => 'جاهزة',
        CampaignState.waiting => 'بانتظار وقت البدء',
        CampaignState.running => 'قيد الإرسال',
        CampaignState.finished => 'اكتملت',
        CampaignState.stopped => 'متوقفة',
      };

  String? _countdown(CampaignController c) {
    final now = DateTime.now();
    if (c.state == CampaignState.waiting && c.startAt != null) {
      return 'تبدأ الحملة بعد ${formatCountdown(c.startAt!.difference(now))}';
    }
    if (c.state == CampaignState.running && c.nextSendAt != null) {
      return 'الرسالة التالية بعد ${formatCountdown(c.nextSendAt!.difference(now))}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.recipients.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final countdown = _countdown(c);

        return SectionCard(
          title: 'حالة الحملة',
          icon: Icons.insights,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _stateLabel(c.state),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text('${(c.progress * 100).round()}%'),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: c.progress,
                minHeight: 10,
                borderRadius: BorderRadius.circular(8),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text('الإجمالي: ${c.total}'),
                  Text('أُرسلت: ${c.sent}'),
                  Text('فشلت: ${c.failed}'),
                  Text('المتبقية: ${c.pending}'),
                ],
              ),
              if (countdown != null) ...[
                const SizedBox(height: 8),
                Text(
                  countdown,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: scheme.primary),
                ),
              ],
              if (c.lastError != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    c.lastError!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
              if (!c.isActive) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (c.pending > 0)
                      FilledButton.icon(
                        onPressed: c.resume,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('استئناف المتبقي'),
                      ),
                    OutlinedButton.icon(
                      onPressed: c.clear,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('مسح السجل'),
                    ),
                  ],
                ),
              ],
              const Divider(height: 24),
              SizedBox(
                height: 300,
                child: ListView.builder(
                  itemCount: c.recipients.length,
                  itemBuilder: (context, i) {
                    final r = c.recipients[i];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: _statusIcon(r.status, scheme),
                      title: Text(
                        r.phone,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                      ),
                      subtitle: Text(
                        r.status == SendStatus.failed && r.error != null
                            ? r.error!
                            : _statusText(r.status),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Icon _statusIcon(SendStatus s, ColorScheme scheme) => switch (s) {
        SendStatus.sent => Icon(Icons.check_circle, color: scheme.primary),
        SendStatus.failed => Icon(Icons.error, color: scheme.error),
        SendStatus.sending => Icon(Icons.sync, color: scheme.tertiary),
        SendStatus.pending =>
          Icon(Icons.hourglass_empty, color: scheme.outline),
      };

  String _statusText(SendStatus s) => switch (s) {
        SendStatus.sent => 'تم الإرسال',
        SendStatus.failed => 'فشل',
        SendStatus.sending => 'جاري الإرسال...',
        SendStatus.pending => 'في الانتظار',
      };
}
