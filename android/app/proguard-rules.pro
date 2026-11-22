# The app exposes no JavaScript bridge and has no reflective application API.

# Names form the private JNI ABI; the engine exports no HarfBuzz symbols.
-keep class app.smallthingz.dict.EgyptianNative { native <methods>; }
