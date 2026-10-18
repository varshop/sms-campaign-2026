import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';
import 'services/campaign_controller.dart';
import 'services/sms_sender.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = CampaignController(SmsSender());
  await controller.restore(); // استرجاع حملة غير مكتملة إن وُجدت
  runApp(SmsCampaignApp(controller: controller));
}

class SmsCampaignApp extends StatelessWidget {
  const SmsCampaignApp({super.key, required this.controller});

  final CampaignController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'حملات SMS',
      // العربية + اتجاه RTL كاملاً
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        inputDecorationTheme: const InputDecorationTheme(
          alignLabelWithHint: true,
        ),
      ),
      home: HomeScreen(controller: controller),
    );
  }
}
