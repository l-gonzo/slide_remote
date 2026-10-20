package dev.lgonzo.slide_native;

import android.app.Activity;
import android.content.res.AssetManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;

import org.libreoffice.kit.Document;
import org.libreoffice.kit.LibreOfficeKit;
import org.libreoffice.kit.Office;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;

/**
 * Convierte presentaciones (.pptx, .ppt, .odp) a PDF dentro del teléfono con LibreOffice
 * (LibreOfficeKit). Las bibliotecas nativas las agrega tool/build_libreoffice_android.sh;
 * si no están, {@link #isAvailable()} devuelve false y la app lo indica.
 *
 * LibreOfficeKit exige que todas las llamadas ocurran en el mismo hilo, por eso hay un
 * HandlerThread dedicado.
 */
final class PptxConverter {

    interface Callback {
        void done(String error); // null = éxito
    }

    private static final String TAG = "Zlide/LO";

    private static Boolean available;
    private static String unavailableReason;
    private static HandlerThread thread;
    private static Handler handler;
    private static Office office;

    /** true si las bibliotecas de LibreOffice vienen incluidas en esta compilación. */
    static synchronized boolean isAvailable() {
        if (available == null) {
            try {
                LibreOfficeKit.initializeLibrary(); // dispara la carga de las .so
                available = true;
                Log.w(TAG, "LibreOffice cargado");
            } catch (Throwable t) {
                Log.w(TAG, "LibreOffice no se pudo cargar", t);
                Throwable root = t;
                while (root.getCause() != null && root.getCause() != root) root = root.getCause();
                unavailableReason = root.getClass().getSimpleName() + ": " + root.getMessage();
                available = false;
            }
        }
        return available;
    }

    /** Motivo por el que no está disponible (null si sí lo está). */
    static synchronized String unavailableReason() {
        isAvailable();
        return unavailableReason;
    }

    private static synchronized Handler handler() {
        if (handler == null) {
            thread = new HandlerThread("libreoffice");
            thread.start();
            handler = new Handler(thread.getLooper());
        }
        return handler;
    }

    /**
     * Convierte [input] a PDF en [output]. [callback] se llama en el hilo de LibreOffice;
     * quien lo use debe regresar al hilo principal.
     */
    static void convert(final Activity activity, final File input, final File output, final Callback callback) {
        if (!isAvailable()) {
            callback.done(Lang.t("LibreOffice no está disponible: ", "LibreOffice is not available: ") + unavailableReason);
            return;
        }
        handler().post(() -> {
            File work = null;
            Document doc = null;
            try {
                if (office == null) {
                    // Igual que la app oficial de LibreOffice: antes de arrancar hay que copiar
                    // assets/unpack/ (tipos UNO *.rdb, configuración de fuentes…) a la carpeta de
                    // datos de la app. Sin esto LibreOffice aborta con DeploymentException.
                    unpackAssets(activity);
                    LibreOfficeKit.putenv("SAL_LOG=+WARN");
                    LibreOfficeKit.putenv("SAL_LOK_OPTIONS=compact_fonts");
                    // La primera vez desempaca archivos de LibreOffice (tarda unos segundos)
                    LibreOfficeKit.init(activity);
                    ByteBuffer h = LibreOfficeKit.getLibreOfficeKitHandle();
                    if (h == null) throw new IllegalStateException(Lang.t("No se pudo iniciar LibreOffice", "Could not start LibreOffice"));
                    office = new Office(h);
                }

                // Copiar a un nombre simple: evita problemas con espacios y acentos en la URL
                File dir = new File(activity.getCacheDir(), "lo-convert");
                if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException(Lang.t("Sin espacio temporal", "No temporary space"));
                String name = input.getName().toLowerCase();
                String ext = name.contains(".") ? name.substring(name.lastIndexOf('.')) : ".pptx";
                work = new File(dir, "entrada" + ext);
                copy(input, work);
                File tmpOut = new File(dir, "salida.pdf");
                if (tmpOut.exists()) tmpOut.delete();

                doc = office.documentLoad("file://" + work.getAbsolutePath());
                if (doc == null) {
                    String err = office.getError();
                    throw new IllegalStateException(Lang.t("No se pudo abrir la presentación", "Could not open the presentation")
                            + (err != null && !err.isEmpty() ? ": " + err : ""));
                }
                doc.saveAs("file://" + tmpOut.getAbsolutePath(), "pdf", "");
                if (!tmpOut.exists() || tmpOut.length() == 0) {
                    throw new IllegalStateException(Lang.t("LibreOffice no generó el PDF", "LibreOffice did not produce the PDF"));
                }
                copy(tmpOut, output);
                tmpOut.delete();
                callback.done(null);
            } catch (Throwable t) {
                Log.e(TAG, "Conversión fallida", t);
                String msg = t.getMessage();
                callback.done(msg != null ? msg : t.toString());
            } finally {
                if (doc != null) {
                    try { doc.destroy(); } catch (Throwable ignored) { }
                }
                if (work != null) work.delete();
            }
        });
    }

    /**
     * Copia assets/unpack/ → /data/data/&lt;app&gt;/ una vez por instalación (se repite si la app
     * se actualiza, para no quedarse con archivos de otra versión de LibreOffice).
     */
    private static void unpackAssets(Activity activity) throws Exception {
        File dataDir = new File(activity.getApplicationInfo().dataDir);
        long stamp = activity.getPackageManager()
                .getPackageInfo(activity.getPackageName(), 0).lastUpdateTime;
        File marker = new File(dataDir, ".lo-unpacked");
        String want = Long.toString(stamp);
        if (marker.exists()) {
            try (InputStream in = new FileInputStream(marker)) {
                byte[] b = new byte[64];
                int n = in.read(b);
                if (n > 0 && new String(b, 0, n, "UTF-8").trim().equals(want)) return;
            }
        }
        long t0 = System.currentTimeMillis();
        AssetManager am = activity.getAssets();
        String[] top = am.list("unpack");
        if (top == null || top.length == 0) {
            throw new IllegalStateException(Lang.t("Faltan los archivos de LibreOffice (assets/unpack) en el APK", "LibreOffice files (assets/unpack) are missing from the APK"));
        }
        int n = copyAssetTree(am, "unpack", dataDir);
        try (OutputStream out = new FileOutputStream(marker)) {
            out.write(want.getBytes("UTF-8"));
        }
        Log.w(TAG, "Archivos de LibreOffice desempacados: " + n + " en "
                + (System.currentTimeMillis() - t0) + " ms");
    }

    private static int copyAssetTree(AssetManager am, String path, File target) throws java.io.IOException {
        String[] children = am.list(path);
        if (children == null || children.length == 0) {
            // Es un archivo
            File parent = target.getParentFile();
            if (parent != null && !parent.exists()) parent.mkdirs();
            try (InputStream in = am.open(path); OutputStream out = new FileOutputStream(target)) {
                byte[] buf = new byte[64 * 1024];
                int r;
                while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
            }
            return 1;
        }
        if (!target.exists()) target.mkdirs();
        int count = 0;
        for (String c : children) {
            count += copyAssetTree(am, path + "/" + c, new File(target, c));
        }
        return count;
    }

    private static void copy(File from, File to) throws java.io.IOException {
        try (InputStream in = new FileInputStream(from); OutputStream out = new FileOutputStream(to)) {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        }
    }
}
