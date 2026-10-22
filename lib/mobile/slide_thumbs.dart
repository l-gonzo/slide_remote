import 'package:flutter/foundation.dart';

import 'native_bridge.dart';

/// Miniaturas de las páginas del PDF que se está transmitiendo (la "siguiente" de las notas).
/// Usa el mismo PDF que la vista de dibujo: el del teléfono o el que se descargó de la PC.
class SlideThumbs extends ChangeNotifier {
  String? _path;
  final Map<int, PdfPageImage> _images = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};

  PdfPageImage? image(String path, int page) => path == _path ? _images[page] : null;

  bool failed(String path, int page) => path == _path && _failed.contains(page);

  /// Pedir la página [page] (empieza en 1) de [path] con [widthPx] píxeles de ancho.
  void request(String path, int page, int widthPx) {
    if (path != _path) {
      _path = path; // otro PDF
      _images.clear();
      _loading.clear();
      _failed.clear();
    }
    if (page < 1 || _images.containsKey(page) || _loading.contains(page) || _failed.contains(page)) return;
    _loading.add(page);
    NativeBridge.renderPdfPage(path, page, widthPx).then((img) {
      if (path != _path) return;
      _loading.remove(page);
      if (img == null) {
        _failed.add(page);
      } else {
        _images[page] = img;
        // Solo hacen falta las cercanas a la actual
        if (_images.length > 4) {
          final far = _images.keys.toList()..sort((a, b) => (a - page).abs().compareTo((b - page).abs()));
          for (final k in far.skip(4)) {
            _images.remove(k);
          }
        }
      }
      notifyListeners();
    });
  }
}
