package dev.lgonzo.slide_native;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
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
 * Puente nativo de Slide Remote para Android:
 *  - captura de los botones de volumen (envolviendo el Window.Callback de la Activity)
 *  - teclado Bluetooth HID (BtHidKeyboard)
 *  - permisos de Bluetooth y "hacer visible"
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
        // Mantener presionado no repite: solo la primera pulsación cuenta
        if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) {
            Map<String, Object> ev = new HashMap<>();
            ev.put("type", "volume");
            ev.put("dir", code == KeyEvent.KEYCODE_VOLUME_UP ? "up" : "down");
            emit(ev);
        }
        return true;
    }

    // ================================================================ métodos

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "setVolumeCapture": {
                Boolean on = call.argument("enabled");
                captureVolume = on != null && on;
                result.success(null);
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
                    result.error("BAD_ARGS", "Faltan datos para convertir", null);
                    return;
                }
                PptxConverter.convert(activity, new java.io.File(in), new java.io.File(out),
                        error -> main.post(() -> {
                            if (error == null) result.success(null);
                            else result.error("CONVERT_FAILED", error, null);
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
        if (!hasPermissions()) { result.error("NO_PERMISSION", "Falta permiso de Bluetooth", null); return; }
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
