# Keep the JNA-loaded native binding intact for consumers that enable R8/ProGuard.
-keep class com.sun.jna.** { *; }
-keep class uniffi.** { *; }
-keepclassmembers class uniffi.** { *; }
