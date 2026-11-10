import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'screens/subscription_screen.dart';

void main() {
  runApp(const OksanaVpnApp());
}

class OksanaVpnApp extends StatelessWidget {
  const OksanaVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oksana VPN',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const SubscriptionScreen(),
    );
  }
}
