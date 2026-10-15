import PDFKit
import UIKit
import WebKit

/// Convierte .pptx / .key / .ppt a PDF dentro del iPhone usando el visor de documentos de iOS
/// (el mismo que usan Archivos y Mail), sin internet.
///
/// 1. Carga la presentación en un WKWebView fuera de pantalla: iOS la muestra como una página
///    con las diapositivas una debajo de otra.
/// 2. Ubica cada diapositiva en la página (elementos grandes con la proporción del .pptx).
/// 3. Genera un PDF por diapositiva con `createPDF(configuration:)` y los une con PDFKit.
final class PresentationConverter: NSObject, WKNavigationDelegate {

    enum Failure: LocalizedError {
        case load(String), notFound, pdf(String), timeout
        var errorDescription: String? {
            switch self {
            case .load(let m): return SlideLang.t("iOS no pudo abrir la presentación (\(m)).", "iOS could not open the presentation (\(m)).")
            case .notFound: return SlideLang.t("No se encontraron las diapositivas en la vista previa de iOS.", "No slides were found in the iOS preview.")
            case .pdf(let m): return SlideLang.t("No se pudo generar el PDF (\(m)).", "Could not create the PDF (\(m)).")
            case .timeout: return SlideLang.t("La conversión tardó demasiado.", "The conversion took too long.")
            }
        }
    }

    private var webView: WKWebView?
    private var output: URL?
    private var aspect: Double?
    private var expected: Int?
    private var completion: ((Result<Int, Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    /// - Parameters:
    ///   - aspect: ancho/alto de las diapositivas si se conoce (del .pptx); ayuda a encontrarlas.
    ///   - expected: número de diapositivas esperado (para el plan B si no se encuentran).
    func convert(input: URL, output: URL, aspect: Double?, expected: Int?,
                 completion: @escaping (Result<Int, Error>) -> Void) {
        self.output = output
        self.aspect = aspect
        self.expected = expected
        self.completion = completion

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 960), configuration: config)
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.alpha = 0.01
        // Debe estar en una ventana para que WebKit haga el diseño de la página
        if let window = SlideNativePlugin.keyWindow() {
            wv.frame.origin = CGPoint(x: -4000, y: 0)
            window.addSubview(wv)
        }
        webView = wv

        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.timeout)) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)

        wv.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // La vista previa de Office termina de acomodarse un poco después de "didFinish"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.locateSlides() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(Failure.load(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(Failure.load(error.localizedDescription)))
    }

    // MARK: - Ubicar diapositivas

    private func locateSlides() {
        guard let wv = webView else { return }
        let aspectJS = aspect.map { String($0) } ?? "null"
        let js = """
        (function(aspect) {
          const doc = document.documentElement;
          const W = Math.max(doc.scrollWidth, document.body ? document.body.scrollWidth : 0);
          const all = Array.from(document.querySelectorAll('body *'));
          let c = [];
          for (const e of all) {
            const r = e.getBoundingClientRect();
            if (r.width < W * 0.5 || r.height < 80) continue;
            const a = r.width / r.height;
            if (aspect ? Math.abs(a - aspect) / aspect > 0.04 : (a < 1.2 || a > 1.9)) continue;
            c.push({ e, x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height });
          }
          // Quedarse con los de más afuera (una diapositiva y no sus partes internas)
          c = c.filter(k => !c.some(o => o !== k && o.e.contains(k.e)));
          // Sin proporción conocida: el tamaño que más se repite es el de las diapositivas
          if (!aspect && c.length > 1) {
            const key = k => Math.round(k.w / 8) + 'x' + Math.round(k.h / 8);
            const n = {};
            c.forEach(k => n[key(k)] = (n[key(k)] || 0) + 1);
            const best = Object.keys(n).sort((p, q) => n[q] - n[p])[0];
            c = c.filter(k => key(k) === best);
          }
          c.sort((p, q) => p.y - q.y);
          return JSON.stringify({ W: W, H: doc.scrollHeight, rects: c.map(k => [k.x, k.y, k.w, k.h]) });
        })(\(aspectJS));
        """
        wv.evaluateJavaScript(js) { [weak self] value, error in
            guard let self = self else { return }
            var rects: [CGRect] = []
            var contentHeight: CGFloat = 0
            var contentWidth: CGFloat = 0
            if let s = value as? String, let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                contentWidth = CGFloat((obj["W"] as? Double) ?? 0)
                contentHeight = CGFloat((obj["H"] as? Double) ?? 0)
                for r in (obj["rects"] as? [[Double]]) ?? [] where r.count == 4 {
                    rects.append(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
                }
            }
            // Plan B: si no se reconocen, dividir la página en partes iguales
            if rects.isEmpty, let n = self.expected, n > 0, contentHeight > 0 {
                let h = contentHeight / CGFloat(n)
                rects = (0..<n).map { CGRect(x: 0, y: CGFloat($0) * h, width: contentWidth, height: h) }
            }
            if rects.isEmpty {
                self.finish(.failure(Failure.notFound))
                return
            }
            self.capture(rects, index: 0, into: PDFDocument())
        }
    }

    // MARK: - PDF

    private func capture(_ rects: [CGRect], index: Int, into result: PDFDocument) {
        guard let wv = webView else { return }
        if index >= rects.count {
            guard let out = output, result.write(to: out) else {
                finish(.failure(Failure.pdf(SlideLang.t("no se pudo guardar", "could not save"))))
                return
            }
            finish(.success(result.pageCount))
            return
        }
        let config = WKPDFConfiguration()
        config.rect = rects[index]
        wv.createPDF(configuration: config) { [weak self] res in
            guard let self = self else { return }
            switch res {
            case .success(let data):
                if let page = PDFDocument(data: data)?.page(at: 0) {
                    result.insert(page, at: result.pageCount)
                }
                self.capture(rects, index: index + 1, into: result)
            case .failure(let e):
                self.finish(.failure(Failure.pdf(e.localizedDescription)))
            }
        }
    }

    private func finish(_ r: Result<Int, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        let done = completion
        completion = nil
        done?(r)
    }
}
