package dev.lgonzo.slide_native;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.NotificationManager;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.media.AudioAttributes;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;
import android.provider.Settings;
import android.view.KeyEvent;
import android.view.Window;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Puente nativo de Zlide para Android:
 *  - captura de los botones de volumen (envolviendo el Window.Callback de la Activity)
 *  - teclado Bluetooth HID (BtHidKeyboard)
 *  - permisos de Bluetooth y "hacer visible"
 *  - "No molestar" mientras se presenta
 *  - giroscopio para apuntar moviendo el teléfono
 *
 * Canal de métodos: "slide_native". Canal de eventos: "slide_native/events".
 */
@SuppressLint("MissingPermission")
public class SlideNativePlugin implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler, PluginRegistry.RequestPermissionsResultListener,
        PluginRegistry.ActivityResultListener {

    private static final int REQ_PERMS = 47101;
    private static final int REQ_DISCOVERABLE = 47102;

    private MethodChannel channel;
    private EventChannel events;
    private EventChannel.EventSink sink;
    private Context appContext;
    private Activity activity;
    private ActivityPluginBinding activityBinding;
    private final Handler main = new Handler(Looper.getMainLooper());

    private Object hid; // BtHidKeyboard; Object para no cargar la clase en Android < 9
    private boolean captureVolume = false;
    private Window.Callback originalCallback;
    private Window.Callback proxyCallback;
    private MethodChannel.Result pendingPermissionResult;

    // ================================================================ FlutterPlugin

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        appContext = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "slide_native");
        channel.setMethodCallHandler(this);
        events = new EventChannel(binding.getBinaryMessenger(), "slide_native/events");
        events.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        events.setStreamHandler(null);
        if (hid != null) ((BtHidKeyboard) hid).stop();
        hid = null;
        setLowLatencyWifi(false);
        setMotion(false);
    }

    // ================================================================ ActivityAware

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activityBinding = binding;
        activity = binding.getActivity();
        binding.addRequestPermissionsResultListener(this);
        binding.addActivityResultListener(this);
        installKeyInterceptor();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() { onDetachedFromActivity(); }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) { onAttachedToActivity(binding); }

    @Override
    public void onDetachedFromActivity() {
        removeKeyInterceptor();
        if (activityBinding != null) {
            activityBinding.removeRequestPermissionsResultListener(this);
            activityBinding.removeActivityResultListener(this);
        }
        activityBinding = null;
        activity = null;
    }

    // ================================================================ eventos

    @Override
    public void onListen(Object arguments, EventChannel.EventSink eventSink) { sink = eventSink; }

    @Override
    public void onCancel(Object arguments) { sink = null; }

    private void emit(Map<String, Object> event) {
        main.post(() -> { if (sink != null) sink.success(event); });
    }

    // ================================================================ botones de volumen

    private void installKeyInterceptor() {
        if (activity == null) return;
        final Window window = activity.getWindow();
        final Window.Callback current = window.getCallback();
        if (current == null || current == proxyCallback) return;
        originalCallback = current;
        proxyCallback = (Window.Callback) Proxy.newProxyInstance(
                Window.Callback.class.getClassLoader(),
                new Class<?>[]{Window.Callback.class},
                (proxy, method, args) -> {
                    if ("dispatchKeyEvent".equals(method.getName()) && args != null && args.length == 1
                            && args[0] instanceof KeyEvent && handleKey((KeyEvent) args[0])) {
                        return Boolean.TRUE;
                    }
                    try {
                        return method.invoke(current, args);
                    } catch (InvocationTargetException e) {
                        throw e.getCause() != null ? e.getCause() : e;
                    }
                });
        window.setCallback(proxyCallback);
    }

    private void removeKeyInterceptor() {
        if (activity != null && proxyCallback != null && activity.getWindow().getCallback() == proxyCallback) {
            activity.getWindow().setCallback(originalCallback);
        }
        proxyCallback = null;
        originalCallback = null;
    }

    /** true = el evento se consume (el volumen no cambia). */
    private boolean handleKey(KeyEvent e) {
        if (!captureVolume) return false;
        int code = e.getKeyCode();
        if (code != KeyEvent.KEYCODE_VOLUME_UP && code != KeyEvent.KEYCODE_VOLUME_DOWN) return false;
        // Mantener presionado no repite: se avisa al presionar (phase down) y al soltar (phase up);
        // cuánto se mantuvo lo decide Dart (acción configurable al mantener presionado)
        boolean down = e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0;
        if (down || e.getAction() == KeyEvent.ACTION_UP) {
            Map<String, Object> ev = new HashMap<>();
            ev.put("type", "volume");
            ev.put("dir", code == KeyEvent.KEYCODE_VOLUME_UP ? "up" : "down");
            ev.put("phase", down ? "down" : "up");
            emit(ev);
        }
        return true;
    }

    // ================================================================ giroscopio

    private SensorEventListener motionListener;

    /** Arriba (contrario a la gravedad) en coordenadas del teléfono, normalizado. */
    private final float[] up = {0, 0, 1};

    /**
     * Mientras se apunta: manda {type: motion, wx, wy, wz (rad/s), ux, uy, uz (arriba), dt (s)}.
     * Devuelve false si el teléfono no tiene giroscopio.
     */
    private boolean setMotion(boolean on) {
        SensorManager sm = (SensorManager) appContext.getSystemService(Context.SENSOR_SERVICE);
        if (sm == null) return false;
        if (motionListener != null) {
            sm.unregisterListener(motionListener);
            motionListener = null;
        }
        if (!on) return true;
        Sensor gyro = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        if (gyro == null) return false;
        Sensor gravity = sm.getDefaultSensor(Sensor.TYPE_GRAVITY);
        if (gravity == null) gravity = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        motionListener = new SensorEventListener() {
            long last = 0;

            @Override
            public void onSensorChanged(SensorEvent e) {
                if (e.sensor.getType() != Sensor.TYPE_GYROSCOPE) {
                    // Gravedad o acelerómetro: el sensor marca hacia arriba (la reacción al peso)
                    float[] v = e.values;
                    double n = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
                    if (n < 1) return;
                    for (int i = 0; i < 3; i++) up[i] = (float) (v[i] / n);
                    return;
                }
                long t = e.timestamp;
                double dt = last == 0 ? 0 : (t - last) / 1e9;
                last = t;
                if (dt <= 0 || dt > 0.2) return;
                Map<String, Object> m = new HashMap<>();
                m.put("type", "motion");
                m.put("wx", (double) e.values[0]);
                m.put("wy", (double) e.values[1]);
                m.put("wz", (double) e.values[2]);
                m.put("ux", (double) up[0]);
                m.put("uy", (double) up[1]);
                m.put("uz", (double) up[2]);
                m.put("dt", dt);
                emit(m);
            }

            @Override
            public void onAccuracyChanged(Sensor sensor, int accuracy) {}
        };
        sm.registerListener(motionListener, gyro, SensorManager.SENSOR_DELAY_GAME);
        if (gravity != null) sm.registerListener(motionListener, gravity, SensorManager.SENSOR_DELAY_GAME);
        return true;
    }

    // ================================================================ métodos

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "setLanguage": {
                Lang.es = "es".equals(call.argument("lang"));
                result.success(null);
                return;
            }
            case "setVolumeCapture": {
                Boolean on = call.argument("enabled");
                captureVolume = on != null && on;
                result.success(null);
                return;
            }
            case "setVolumeHold": {
                // Android avisa al soltar el botón: no hace falta nada (iOS sí lo necesita)
                result.success(null);
                return;
            }
            case "setMotion": {
                Boolean on = call.argument("enabled");
                result.success(setMotion(on != null && on));
                return;
            }
            case "vibrate": {
                Integer count = call.argument("count");
                Integer ms = call.argument("ms");
                Double strength = call.argument("strength");
                vibrate(count == null ? 1 : count, ms == null ? 550 : ms, strength == null ? 1 : strength);
                result.success(null);
                return;
            }
            case "setLowLatencyWifi": {
                Boolean on = call.argument("enabled");
                setLowLatencyWifi(on != null && on);
                result.success(null);
                return;
            }
            case "dndStatus":
                result.success(dndStatus());
                return;
            case "setDnd": {
                Boolean on = call.argument("enabled");
                result.success(setDnd(on != null && on));
                return;
            }
            case "openDndSettings": {
                boolean ok = false;
                if (activity != null && Build.VERSION.SDK_INT >= 23) {
                    try {
                        activity.startActivity(new Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS));
                        ok = true;
                    } catch (RuntimeException e) {
                        android.util.Log.w("slide_native", "openDndSettings: " + e);
                    }
                }
                result.success(ok);
                return;
            }
            case "hidSupported":
                result.success(Build.VERSION.SDK_INT >= 28 && BluetoothAdapter.getDefaultAdapter() != null);
                return;
            case "btEnabled": {
                BluetoothAdapter a = BluetoothAdapter.getDefaultAdapter();
                result.success(a != null && a.isEnabled());
                return;
            }
            case "requestBtPermissions":
                requestPermissions(result);
                return;
            case "converterAvailable":
                result.success(PptxConverter.isAvailable());
                return;
            case "converterStatus": {
                Map<String, Object> st = new HashMap<>();
                st.put("available", PptxConverter.isAvailable());
                st.put("reason", PptxConverter.unavailableReason());
                result.success(st);
                return;
            }
            case "convertToPdf": {
                String in = call.argument("input");
                String out = call.argument("output");
                if (activity == null || in == null || out == null) {
                    result.error("BAD_ARGS", Lang.t("Faltan datos para convertir", "Missing conversion data"), null);
                    return;
                }
                String svg = call.argument("svgOutput");
                PptxConverter.convert(activity, new java.io.File(in), new java.io.File(out),
                        svg != null ? new java.io.File(svg) : null,
                        error -> main.post(() -> {
                            if (error == null) result.success(null);
                            else result.error("CONVERT_FAILED", error, null);
                        }));
                return;
            }
            case "renderPdfPage": {
                String path = call.argument("path");
                Integer page = call.argument("page");
                Integer width = call.argument("width");
                if (path == null) { result.error("BAD_ARGS", "path", null); return; }
                PdfPageRenderer.render(path, page != null ? page : 1, width != null ? width : 1280,
                        (m, error) -> main.post(() -> {
                            if (error == null) result.success(m);
                            else result.error("RENDER_FAILED", error, null);
                        }));
                return;
            }
            case "makeDiscoverable":
                if (activity == null) { result.success(false); return; }
                Intent i = new Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                        .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120);
                activity.startActivityForResult(i, REQ_DISCOVERABLE);
                result.success(true);
                return;
            default:
                break;
        }

        // ---- teclado HID (Android 9+)
        if (!call.method.startsWith("hid")) { result.notImplemented(); return; }
        if (Build.VERSION.SDK_INT < 28) { result.success(null); return; }
        if (!hasPermissions()) { result.error("NO_PERMISSION", Lang.t("Falta permiso de Bluetooth", "Bluetooth permission missing"), null); return; }
        BtHidKeyboard kb = keyboard();
        switch (call.method) {
            case "hidStart": {
                String addr = call.argument("address");
                kb.start(kb.deviceFor(addr));
                result.success(null);
                break;
            }
            case "hidPause":
                kb.pause();
                result.success(null);
                break;
            case "hidConnect": {
                BluetoothDevice d = kb.deviceFor(call.argument("address"));
                if (d != null) kb.connect(d);
                result.success(d != null);
                break;
            }
            case "hidDisconnect":
                kb.disconnect();
                result.success(null);
                break;
            case "hidReconnect":
                result.success(kb.reconnect());
                break;
            case "hidBonded": {
                List<Map<String, Object>> out = new ArrayList<>();
                for (BluetoothDevice d : kb.bondedDevices()) {
                    Map<String, Object> m = new HashMap<>();
                    m.put("name", BtHidKeyboard.label(d));
                    m.put("address", d.getAddress());
                    out.add(m);
                }
                result.success(out);
                break;
            }
            case "hidSend": {
                Integer key = call.argument("key");
                result.success(key != null && kb.tap((byte) (int) key));
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private WifiManager.WifiLock wifiLock;

    /**
     * Vista de dibujo: sin el ahorro de energía del WiFi, que junta los paquetes y los manda
     * cada ~100 ms (el trazo llega a tirones a la PC).
     */
    @SuppressWarnings("deprecation")
    private void setLowLatencyWifi(boolean on) {
        try {
            if (on) {
                if (wifiLock == null) {
                    if (appContext == null) return;
                    WifiManager wm = (WifiManager) appContext.getSystemService(Context.WIFI_SERVICE);
                    if (wm == null) return;
                    int mode = Build.VERSION.SDK_INT >= 29
                            ? WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                            : WifiManager.WIFI_MODE_FULL_HIGH_PERF;
                    wifiLock = wm.createWifiLock(mode, "zlide:draw");
                    wifiLock.setReferenceCounted(false);
                }
                wifiLock.acquire();
            } else if (wifiLock != null && wifiLock.isHeld()) {
                wifiLock.release();
            }
        } catch (RuntimeException e) {
            android.util.Log.w("slide_native", "setLowLatencyWifi: " + e);
        }
    }

    /** Aviso discreto del cronómetro: [count] pulsos de [ms] con intensidad [strength] (0–1). */
    @SuppressWarnings("deprecation")
    private void vibrate(int count, int ms, double strength) {
        if (appContext == null || count < 1) return;
        Vibrator v;
        if (Build.VERSION.SDK_INT >= 31) {
            VibratorManager vm = (VibratorManager) appContext.getSystemService(Context.VIBRATOR_MANAGER_SERVICE);
            v = vm == null ? null : vm.getDefaultVibrator();
        } else {
            v = (Vibrator) appContext.getSystemService(Context.VIBRATOR_SERVICE);
        }
        if (v == null || !v.hasVibrator()) return;
        long[] pattern = new long[count * 2];
        int[] amps = new int[count * 2];
        for (int i = 0; i < count; i++) {
            pattern[i * 2] = i == 0 ? 0 : 250; // pausa
            pattern[i * 2 + 1] = Math.max(20, ms); // pulso
            amps[i * 2 + 1] = (int) Math.max(1, Math.min(255, Math.round(strength * 255)));
        }
        // Como alarma: sin uso declarado, Android trata los patrones cortos como vibración táctil
        // (su propia intensidad, a veces muy baja) y los largos de otra forma, así que un aviso
        // "suave" podía sentirse más fuerte que uno "fuerte". Además suena aunque esté en No molestar.
        if (Build.VERSION.SDK_INT >= 26) {
            VibrationEffect effect = v.hasAmplitudeControl()
                    ? VibrationEffect.createWaveform(pattern, amps, -1)
                    : VibrationEffect.createWaveform(pattern, -1);
            if (Build.VERSION.SDK_INT >= 33) {
                v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM));
            } else {
                v.vibrate(effect, new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build());
            }
        } else {
            v.vibrate(pattern, -1);
        }
    }

    // ================================================================ No molestar

    private static final String DND_PREFS = "zlide_native";
    private static final String DND_PREV = "dnd_prev"; // filtro que había antes de presentar

    private NotificationManager notifications() {
        return appContext == null ? null : (NotificationManager) appContext.getSystemService(Context.NOTIFICATION_SERVICE);
    }

    /** "granted", "denied" (falta el acceso a No molestar) o "unsupported". */
    private String dndStatus() {
        NotificationManager nm = notifications();
        if (nm == null || Build.VERSION.SDK_INT < 23) return "unsupported";
        return nm.isNotificationPolicyAccessGranted() ? "granted" : "denied";
    }

    /**
     * Activar: solo pasan las alarmas (los avisos del cronómetro vibran como alarma). Se guarda
     * el modo anterior, también en disco: si la app se cierra de golpe, se restaura al volver.
     * Desactivar: se regresa al modo anterior, salvo que el usuario lo haya cambiado mientras tanto.
     * Devuelve "on", "off" o el estado de [dndStatus] si no se pudo.
     */
    private String setDnd(boolean on) {
        String st = dndStatus();
        if (!"granted".equals(st)) return st;
        NotificationManager nm = notifications();
        SharedPreferences prefs = appContext.getSharedPreferences(DND_PREFS, Context.MODE_PRIVATE);
        try {
            int current = nm.getCurrentInterruptionFilter();
            if (on) {
                if (!prefs.contains(DND_PREV)) prefs.edit().putInt(DND_PREV, current).apply();
                if (current != NotificationManager.INTERRUPTION_FILTER_ALARMS) {
                    nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALARMS);
                }
                return "on";
            }
            if (prefs.contains(DND_PREV)) {
                int prev = prefs.getInt(DND_PREV, NotificationManager.INTERRUPTION_FILTER_ALL);
                prefs.edit().remove(DND_PREV).apply();
                if (current == NotificationManager.INTERRUPTION_FILTER_ALARMS && prev != current) {
                    nm.setInterruptionFilter(prev);
                }
            }
            return "off";
        } catch (RuntimeException e) {
            android.util.Log.w("slide_native", "setDnd: " + e);
            return "denied";
        }
    }

    private BtHidKeyboard keyboard() {
        if (hid == null) {
            hid = new BtHidKeyboard(appContext, (state, device, message) -> {
                Map<String, Object> ev = new HashMap<>();
                ev.put("type", "hid");
                ev.put("state", state.name());
                if (device != null) {
                    ev.put("name", BtHidKeyboard.label(device));
                    ev.put("address", device.getAddress());
                }
                if (message != null) ev.put("message", message);
                emit(ev);
            });
        }
        return (BtHidKeyboard) hid;
    }

    // ================================================================ permisos

    private String[] neededPermissions() {
        if (Build.VERSION.SDK_INT >= 31) {
            return new String[]{Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE};
        }
        return new String[0];
    }

    private boolean hasPermissions() {
        if (Build.VERSION.SDK_INT < 23) return true;
        for (String p : neededPermissions()) {
            if (appContext.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) return false;
        }
        return true;
    }

    private void requestPermissions(MethodChannel.Result result) {
        if (hasPermissions()) { result.success(true); return; }
        if (activity == null || Build.VERSION.SDK_INT < 23) { result.success(false); return; }
        if (pendingPermissionResult != null) pendingPermissionResult.success(false);
        pendingPermissionResult = result;
        activity.requestPermissions(neededPermissions(), REQ_PERMS);
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != REQ_PERMS) return false;
        boolean ok = grantResults.length > 0;
        for (int g : grantResults) ok &= g == PackageManager.PERMISSION_GRANTED;
        if (pendingPermissionResult != null) {
            pendingPermissionResult.success(ok);
            pendingPermissionResult = null;
        }
        return true;
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQ_DISCOVERABLE) return false;
        Map<String, Object> ev = new HashMap<>();
        ev.put("type", "discoverable");
        ev.put("ok", resultCode != Activity.RESULT_CANCELED);
        emit(ev);
        return true;
    }
}
