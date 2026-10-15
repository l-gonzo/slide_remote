package dev.lgonzo.slide_native;

/** Idioma de los mensajes nativos; lo fija la app con el método "setLanguage" ('es' o 'en'). */
final class Lang {
    static volatile boolean es = false;

    static String t(String spanish, String english) {
        return es ? spanish : english;
    }

    private Lang() { }
}
