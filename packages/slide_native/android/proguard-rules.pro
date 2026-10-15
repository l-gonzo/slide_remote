# LibreOfficeKit: el código nativo llama a estas clases y métodos por nombre (JNI).
-keep class org.libreoffice.kit.** { *; }
-keepclassmembers class org.libreoffice.kit.** {
    native <methods>;
    private void messageRetrieved(int, java.lang.String);
    private void messageRetrievedLOKit(int, java.lang.String);
}
-dontwarn org.libreoffice.kit.**
