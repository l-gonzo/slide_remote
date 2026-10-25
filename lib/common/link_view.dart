import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'i18n.dart';

/// Enlaces de la diapositiva abiertos dentro de la presentación (un panel encima de ella, en la
/// misma pestaña), manejables desde el teléfono.
///
/// - Videos de YouTube: su reproductor para insertar, controlado con su API de mensajes
///   (reproducir, pausar, adelantar, silenciar).
/// - Las demás páginas: las descarga quien sirve la presentación (la PC o el teléfono) y las
///   entrega como propias en `/link?u=…`. Así la presentación puede desplazarlas, seguir sus
///   enlaces y regresar, aunque el sitio no se deje mostrar dentro de otra página. Se muestran
///   sin sus scripts (como una vista de lectura): no pueden tocar la presentación.
///
/// [kind]: 'video' o 'page' ('mail' para mailto:, que abre el programa de correo).
({String url, String kind}) linkTarget(String url) {
  final yt = _youtubeEmbed(url);
  if (yt != null) return (url: yt, kind: 'video');
  if (url.toLowerCase().startsWith('mailto:')) return (url: url, kind: 'mail');
  return (url: url, kind: 'page');
}

String? _youtubeEmbed(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null;
  final host = u.host.toLowerCase().replaceFirst('www.', '').replaceFirst('m.', '');
  String? id;
  if (host == 'youtu.be' && u.pathSegments.isNotEmpty) {
    id = u.pathSegments.first;
  } else if (host == 'youtube.com' || host == 'youtube-nocookie.com') {
    final s = u.pathSegments;
    if (s.isNotEmpty && s.first == 'watch') id = u.queryParameters['v'];
    if (s.length > 1 && ['shorts', 'embed', 'live', 'v'].contains(s.first)) id = s[1];
  }
  if (id == null || !RegExp(r'^[\w-]{6,}$').hasMatch(id)) return null;
  final start = u.queryParameters['t'] ?? u.queryParameters['start'];
  final secs = start == null ? null : int.tryParse(start.replaceAll('s', ''));
  // La página agrega enablejsapi y origin (los necesita para controlarlo)
  return 'https://www.youtube.com/embed/$id?autoplay=1&rel=0&playsinline=1${secs != null ? '&start=$secs' : ''}';
}

const _maxBytes = 12 * 1024 * 1024;

/// `/link?u=<url>`: la página [u] servida como propia, con `<base>` apuntando al sitio original
/// (imágenes y estilos se cargan de allá) y sin scripts.
Future<void> serveLinkProxy(HttpRequest req) async {
  final res = req.response;
  final target = Uri.tryParse(req.uri.queryParameters['u'] ?? '');
  if (target == null || !(target.scheme == 'http' || target.scheme == 'https') || target.host.isEmpty || _local(target.host)) {
    await _message(res, HttpStatus.badRequest, t('Enlace no válido', 'Invalid link'));
    return;
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..userAgent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
  try {
    final up = await client.getUrl(target).timeout(const Duration(seconds: 8));
    up.followRedirects = true;
    up.maxRedirects = 8;
    up.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,*/*;q=0.8');
    final lang = req.headers.value(HttpHeaders.acceptLanguageHeader);
    up.headers.set(HttpHeaders.acceptLanguageHeader, lang ?? 'es,en;q=0.8');
    final r = await up.close().timeout(const Duration(seconds: 12));
    // Dirección final (después de redirecciones): de ella se resuelven las rutas relativas
    var finalUrl = target;
    for (final redirect in r.redirects) {
      finalUrl = finalUrl.resolveUri(redirect.location);
    }
    final type = r.headers.contentType;
    final bytes = await _read(r);
    res.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      // Aunque alguien la abra fuera del panel, sin scripts ni marcos
      ..set('Content-Security-Policy', "script-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'")
      ..set('X-Zlide-Url', finalUrl.toString());
    if (type == null || type.subType == 'html' || type.subType == 'xhtml+xml') {
      final html = _rewrite(_decode(bytes, type?.charset), finalUrl);
      final out = utf8.encode(html);
      res.headers
        ..contentType = ContentType('text', 'html', charset: 'utf-8')
        ..contentLength = out.length;
      res.add(out);
    } else {
      res.headers
        ..contentType = type
        ..contentLength = bytes.length;
      res.add(bytes);
    }
    await res.close();
  } catch (e) {
    await _message(res, HttpStatus.badGateway, '${t('No se pudo abrir la página', 'Could not open the page')}: $e');
  } finally {
    client.close(force: true);
  }
}

bool _local(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final ip = InternetAddress.tryParse(h.replaceAll('[', '').replaceAll(']', ''));
  return ip != null && (ip.isLoopback || ip.isLinkLocal);
}

Future<Uint8List> _read(HttpClientResponse r) async {
  final b = BytesBuilder(copy: false);
  await for (final chunk in r) {
    b.add(chunk);
    if (b.length > _maxBytes) throw HttpException(t('la página es demasiado grande', 'the page is too large'));
  }
  return b.takeBytes();
}

String _decode(Uint8List bytes, String? charset) {
  var cs = charset?.toLowerCase();
  if (cs == null) {
    // <meta charset="…"> al inicio del documento
    final head = latin1.decode(bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes);
    cs = RegExp(r'''<meta[^>]+charset\s*=\s*["']?([\w-]+)''', caseSensitive: false).firstMatch(head)?.group(1)?.toLowerCase();
  }
  if (cs == 'iso-8859-1' || cs == 'latin1' || cs == 'windows-1252' || cs == 'us-ascii') return latin1.decode(bytes);
  return utf8.decode(bytes, allowMalformed: true);
}

String _rewrite(String html, Uri base) {
  // Su propio <base> (resuelto contra la dirección original) o la dirección original
  var baseHref = base;
  final own = RegExp(r'''<base\s[^>]*href\s*=\s*["']([^"']*)["'][^>]*>''', caseSensitive: false);
  final m = own.firstMatch(html);
  if (m != null) {
    baseHref = base.resolve(m.group(1)!.trim());
    html = html.replaceAll(own, '');
  }
  // Fuera lo que estorba: su CSP (bloquearía la página así servida) y redirecciones automáticas
  html = html.replaceAll(
      RegExp(r'''<meta[^>]+http-equiv\s*=\s*["']?(content-security-policy|refresh)[^>]*>''', caseSensitive: false), '');
  final tag = '<base href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(baseHref.toString())}">'
      '<meta charset="utf-8">';
  final head = RegExp(r'<head(\s[^>]*)?>', caseSensitive: false).firstMatch(html);
  if (head != null) return html.replaceRange(head.end, head.end, tag);
  final htmlTag = RegExp(r'<html(\s[^>]*)?>', caseSensitive: false).firstMatch(html);
  if (htmlTag != null) return html.replaceRange(htmlTag.end, htmlTag.end, '<head>$tag</head>');
  return '<head>$tag</head>$html';
}

Future<void> _message(HttpResponse res, int status, String text) async {
  try {
    final body = utf8.encode('<!doctype html><meta charset="utf-8"><body style="font:16px system-ui;'
        'display:grid;place-items:center;height:90vh;margin:0;color:#444">'
        '<p>${const HtmlEscape().convert(text)}</p></body>');
    res
      ..statusCode = status
      ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
      ..headers.contentLength = body.length
      ..add(body);
    await res.close();
  } catch (_) {}
}
