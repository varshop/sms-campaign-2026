import 'package:telephony_sms/telephony_sms.dart';

/// خطأ إرسال برسالة عربية مفهومة. [fatal] يعني إيقاف الحملة كلها (مثل غياب الصلاحية).
class SmsSendException implements Exception {
  const SmsSendException(this.message, {this.fatal = false});

  final String message;
  final bool fatal;

  @override
  String toString() => message;
}

/// طبقة رقيقة فوق حزمة telephony_sms.
class SmsSender {
  SmsSender() : _sms = TelephonySMS();

  final TelephonySMS _sms;

  /// يطلب صلاحية SEND_SMS، ويعيد true إن كانت ممنوحة.
  Future<bool> requestPermission() async {
    try {
      return await _sms.requestPermission();
    } on TelephonySmsException {
      return false;
    }
  }

  /// يرسل رسالة ويكتمل عند تأكيد الراديو للإرسال، أو يرمي [SmsSendException].
  Future<void> send(String phone, String message) async {
    try {
      await _sms.sendSMS(phone: phone, message: message);
    } on TelephonySmsException catch (e) {
      throw _map(e);
    }
  }

  SmsSendException _map(TelephonySmsException e) {
    switch (e.code) {
      case TelephonySmsErrorCode.permissionDenied:
      case TelephonySmsErrorCode.permissionNotDeclared:
        return const SmsSendException(
          'صلاحية إرسال الرسائل غير ممنوحة',
          fatal: true,
        );
      case TelephonySmsErrorCode.noTelephony:
        return const SmsSendException(
          'هذا الجهاز لا يدعم إرسال الرسائل',
          fatal: true,
        );
      case TelephonySmsErrorCode.noSmsSubscription:
        return const SmsSendException(
          'حدّد شريحة افتراضية للرسائل من إعدادات الهاتف ثم أعد المحاولة',
          fatal: true,
        );
      case TelephonySmsErrorCode.simAbsent:
        return const SmsSendException('لا توجد شريحة SIM', fatal: true);
      case TelephonySmsErrorCode.smsManagerUnavailable:
      case TelephonySmsErrorCode.receiverUnavailable:
        return const SmsSendException(
          'تعذّر تهيئة خدمة الرسائل على هذا الجهاز',
          fatal: true,
        );
      case TelephonySmsErrorCode.noService:
        return const SmsSendException('لا توجد تغطية شبكة');
      case TelephonySmsErrorCode.radioOff:
        return const SmsSendException('الراديو مغلق (وضع الطيران؟)');
      case TelephonySmsErrorCode.limitExceeded:
        return const SmsSendException('تجاوز حد الإرسال المسموح في أندرويد');
      case TelephonySmsErrorCode.invalidArguments:
        return const SmsSendException('رقم أو نص غير صالح');
      case TelephonySmsErrorCode.sendTimeout:
        return const SmsSendException('لم يُؤكَّد الإرسال (قد تكون أُرسلت)');
      default:
        return SmsSendException('تعذّر الإرسال (${e.code.name})');
    }
  }
}
