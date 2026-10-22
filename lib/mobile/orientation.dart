import 'dart:ui';

import 'package:flutter/services.dart';

import '../common/theme.dart';

/// Tableta: el lado corto de la pantalla mide al menos [Bp.medium].
bool get isTablet {
  final v = PlatformDispatcher.instance.views.first;
  return v.physicalSize.shortestSide / v.devicePixelRatio >= Bp.medium;
}

/// Orientación normal de la app: el teléfono siempre en vertical (el pulgar y los botones de
/// volumen caen igual); la tableta, como se sostenga.
Future<void> defaultOrientations() =>
    SystemChrome.setPreferredOrientations(isTablet ? const [] : const [DeviceOrientation.portraitUp]);
