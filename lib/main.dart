import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common/theme.dart';
import 'desktop/receiver_page.dart';
import 'mobile/remote_page.dart';

/// Un solo proyecto, dos apps:
///  - en el teléfono (Android/iOS): el control remoto
///  - en la PC (Windows/macOS/Linux): el receptor que presiona las teclas
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (!desktop) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Pal.bg,
    ));
  }
  runApp(SlideRemoteApp(desktop: desktop));
}

class SlideRemoteApp extends StatelessWidget {
  const SlideRemoteApp({super.key, required this.desktop});
  final bool desktop;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Slide Remote',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: desktop ? const ReceiverPage() : const RemotePage(),
      );
}
