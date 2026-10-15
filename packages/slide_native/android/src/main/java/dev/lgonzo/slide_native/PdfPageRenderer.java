package dev.lgonzo.slide_native;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.os.ParcelFileDescriptor;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Dibuja una página del PDF del modo Navegador como imagen (para la vista de dibujo del
 * teléfono). Usa el PdfRenderer de Android: no hace falta ninguna biblioteca extra.
 * PdfRenderer no es seguro entre hilos, así que todo pasa en un solo hilo.
 */
final class PdfPageRenderer {

    interface Callback {
        void done(Map<String, Object> result, String error);
    }

    private static final ExecutorService worker = Executors.newSingleThreadExecutor();
    private static PdfRenderer renderer;
    private static ParcelFileDescriptor fd;
    private static String openPath;
    private static long openStamp;

    /** [page] empieza en 1. [width] en píxeles. */
    static void render(String path, int page, int width, Callback cb) {
        worker.execute(() -> {
            try {
                PdfRenderer r = open(path);
                int count = r.getPageCount();
                if (count == 0) throw new IllegalStateException("PDF vacío");
                int index = Math.max(0, Math.min(page - 1, count - 1));
                PdfRenderer.Page p = r.openPage(index);
                try {
                    int w = Math.max(64, Math.min(width, 2400));
                    int h = Math.max(1, Math.round(w * (float) p.getHeight() / p.getWidth()));
                    Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                    bmp.eraseColor(Color.WHITE);
                    p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    bmp.compress(Bitmap.CompressFormat.JPEG, 90, out);
                    bmp.recycle();
                    Map<String, Object> m = new HashMap<>();
                    m.put("bytes", out.toByteArray());
                    m.put("width", w);
                    m.put("height", h);
                    m.put("pages", count);
                    cb.done(m, null);
                } finally {
                    p.close();
                }
            } catch (Throwable t) {
                close();
                cb.done(null, t.getMessage() != null ? t.getMessage() : t.toString());
            }
        });
    }

    private static PdfRenderer open(String path) throws Exception {
        File f = new File(path);
        long stamp = f.lastModified() ^ f.length();
        if (renderer != null && path.equals(openPath) && stamp == openStamp) return renderer;
        close();
        fd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
        renderer = new PdfRenderer(fd);
        openPath = path;
        openStamp = stamp;
        return renderer;
    }

    private static void close() {
        try { if (renderer != null) renderer.close(); } catch (Throwable ignored) { }
        try { if (fd != null) fd.close(); } catch (Throwable ignored) { }
        renderer = null;
        fd = null;
        openPath = null;
    }

    private PdfPageRenderer() { }
}
