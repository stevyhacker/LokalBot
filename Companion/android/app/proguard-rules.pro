# kotlinx.serialization keeps generated serializers through its own rules.
# Record models are decoded by name from JSON produced on the Mac.
-keep,includedescriptorclasses class me.dotenv.lokalbot.companion.data.model.** { *; }
