import 'package:flutter/services.dart';

/// Huella de la página web de la presentación (assets/web/index.html): cambia con cada versión
/// de la app. Va en la página (`<html data-build>`) y en el saludo del WebSocket (`build`); una
/// pestaña que se quedó abierta con la página anterior lo nota al reconectarse y se recarga sola.
Future<String> webPageBuild() => _build ??= rootBundle.load('assets/web/index.html').then((d) {
      var h = 0;
      for (final b in d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)) {
        h = (h * 31 + b) & 0x3fffffff;
      }
      return h.toRadixString(36);
    });

Future<String>? _build;
