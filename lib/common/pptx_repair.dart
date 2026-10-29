import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Arreglos de un .pptx para que LibreOffice lo pueda abrir. Nunca toca el archivo original:
/// recibe sus bytes y devuelve una copia corregida.
///
/// Gráficas sin `<c:ptCount>` en sus datos guardados (`strCache`, `numCache`,
/// `multiLvlStrCache`): algunos editores las guardan así y LibreOffice rechaza la presentación
/// entera ("source file could not be loaded"). Se agrega la cuenta de puntos que falta.
abstract final class PptxRepair {
  /// La copia corregida, o null si no hacía falta nada (o no se entiende el archivo).
  static Future<Uint8List?> repair(Uint8List bytes) => Isolate.run(() {
        try {
          return _repairSync(bytes);
        } catch (_) {
          return null;
        }
      });

  static Uint8List? _repairSync(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    final out = Archive();
    var changed = false;
    for (final f in zip.files) {
      if (f.isFile && RegExp(r'^ppt/charts/[^/]+\.xml$').hasMatch(f.name)) {
        final fixed = _fixChart(f.content as List<int>);
        if (fixed != null) {
          out.addFile(ArchiveFile(f.name, fixed.length, fixed));
          changed = true;
          continue;
        }
      }
      // Las entradas sin comprimir van en memoria: si no, el ZIP las escribe con "data descriptor"
      // (tamaños al final), y LibreOffice no abre entradas así
      out.addFile(f.isFile && !f.isCompressed ? ArchiveFile.noCompress(f.name, f.size, f.content as List<int>) : f);
    }
    if (!changed) return null;
    // archive 3 puede devolver null; archive 4 no
    // ignore: unnecessary_nullable_for_final_variable_declarations
    final List<int>? encoded = ZipEncoder().encode(out);
    return encoded == null ? null : Uint8List.fromList(encoded);
  }

  /// La gráfica con los `ptCount` que faltaban, o null si estaba bien.
  static List<int>? _fixChart(List<int> data) {
    final start = (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) ? 3 : 0;
    final doc = XmlDocument.parse(const Utf8Decoder(allowMalformed: true).convert(data, start));
    var changed = false;
    for (final cache in doc.descendantElements.toList()) {
      final kind = cache.name.local;
      if (kind != 'strCache' && kind != 'numCache' && kind != 'multiLvlStrCache') continue;
      if (cache.childElements.any((e) => e.name.local == 'ptCount')) continue;
      // Puntos: hijos directos, o dentro de cada <c:lvl> en las categorías de varios niveles
      final pts = kind == 'multiLvlStrCache'
          ? cache.childElements.where((e) => e.name.local == 'lvl').expand((l) => l.childElements)
          : cache.childElements;
      var count = 0;
      for (final pt in pts.where((e) => e.name.local == 'pt')) {
        final idx = int.tryParse(pt.getAttribute('idx') ?? '');
        if (idx != null && idx + 1 > count) count = idx + 1;
      }
      final prefix = cache.name.prefix;
      final ptCount = XmlDocumentFragment.parse('<${prefix == null ? '' : '$prefix:'}ptCount val="$count"/>').firstChild!.copy();
      // En numCache va después de <c:formatCode>; en los demás, primero
      final format = cache.childElements.where((e) => e.name.local == 'formatCode').firstOrNull;
      cache.children.insert(format == null ? 0 : cache.children.indexOf(format) + 1, ptCount);
      changed = true;
    }
    return changed ? utf8.encode(doc.toXmlString()) : null;
  }
}
