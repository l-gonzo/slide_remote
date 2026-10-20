# LibreOfficeKit: el código nativo llama a estas clases y métodos por nombre (JNI).
-keep class org.libreoffice.kit.** { *; }
-keepclassmembers class org.libreoffice.kit.** {
    native <methods>;
    private void messageRetrieved(int, java.lang.String);
    private void messageRetrievedLOKit(int, java.lang.String);
}
-dontwarn org.libreoffice.kit.**

# shared_preferences (Android) y otros plugins que llaman a Kotlin/Java desde Dart con JNI
# (package:jni). R8 no ve esas llamadas y quitaba o renombraba los métodos en la versión
# release: la app se quedaba cargando con "NoSuchMethodError ... SharedPreferencesApiRegistrar".
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlinx.coroutines.** { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**
-dontwarn com.github.dart_lang.jni.**
