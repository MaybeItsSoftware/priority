
# The Rust core's UniFFI bindings (uniffi.takt_core) reach native code through
# JNA, which finds its classes, fields and callbacks by reflection. R8 cannot
# see those uses, so it would rename or strip them and the first call into the
# core would fail at runtime in a minified build only.
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-keep class uniffi.takt_core.** { *; }
-dontwarn java.awt.**
