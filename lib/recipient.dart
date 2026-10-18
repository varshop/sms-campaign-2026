/// حالة إرسال رسالة واحدة.
enum SendStatus { pending, sending, sent, failed }

/// مستلم واحد مع قيم الأعمدة المستخدمة في المتغيرات ({A} و{B} و{license} ...).
class Recipient {
  Recipient({
    required this.phone,
    required this.vars,
    this.status = SendStatus.pending,
    this.error,
  });

  final String phone;
  final Map<String, String> vars;
  SendStatus status;
  String? error;

  Map<String, dynamic> toJson() => {
        'p': phone,
        'v': vars,
        's': status.name,
        'e': error,
      };

  factory Recipient.fromJson(Map<String, dynamic> json) => Recipient(
        phone: json['p'] as String,
        vars: Map<String, String>.from(json['v'] as Map),
        status: SendStatus.values.firstWhere(
          (s) => s.name == json['s'],
          orElse: () => SendStatus.pending,
        ),
        error: json['e'] as String?,
      );
}
