# JNI entry points live in libcore.so and must survive shrinking.
-keep class io.flrone.core.** { native <methods>; }
-keep interface io.flrone.core.** { *; }
