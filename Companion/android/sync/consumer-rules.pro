# JNA and the UniFFI bindings look classes and fields up by name at runtime.
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-keep class me.dotenv.lokalbot.sync.** { *; }
-dontwarn java.awt.**
