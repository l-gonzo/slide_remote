import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'common/i18n.dart';
import 'common/theme.dart';
import 'desktop/receiver_page.dart';
import 'mobile/remote_page.dart';

/// Un solo proyecto, dos apps:
///  - en el teléfono (Android/iOS): el control remoto
///  - en la PC (Windows/macOS/Linux): el receptor que presiona las teclas
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await I18n.load();
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

class SlideRemoteApp extends StatefulWidget {
  const SlideRemoteApp({super.key, required this.desktop});
  final bool desktop;

  @override
  State<SlideRemoteApp> createState() => _SlideRemoteAppState();
}

class _SlideRemoteAppState extends State<SlideRemoteApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) => I18n.systemChanged();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: I18n.current,
        builder: (context, lang, _) => MaterialApp(
          title: 'Slide Remote',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          // Textos propios de Flutter (menús, "copiar", accesibilidad) en el mismo idioma
          locale: Locale(lang),
          supportedLocales: const [Locale('es'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: widget.desktop ? const ReceiverPage() : const RemotePage(),
        ),
      );
}
