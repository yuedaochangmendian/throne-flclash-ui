# JNI entry points live in libcore.so and must survive shrinking.
-keep class io.throne.bbox.core.** { native <methods>; }
-keep interface io.throne.bbox.core.** { *; }
