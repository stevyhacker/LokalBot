# kotlinx.serialization keeps generated serializers through its own rules.
# Record models are decoded by name from JSON produced on the Mac.
-keep,includedescriptorclasses class me.dotenv.lokalbot.companion.data.model.** { *; }

# ML Kit finds its component registrars by name and calls their empty constructors.
# The rule firebase-components ships keeps the classes only, so R8 removed the
# constructors and opening the QR scanner crashed.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
