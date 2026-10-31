# Cocoa ruler clipping regression probe

On macOS with Xcode Command Line Tools and CMake, build the Scintilla library:

```sh
cmake -S . -B build
cmake --build build --target scintilla
```

From the repository root, compile and run the probe:

```sh
clang++ -std=c++17 -fobjc-arc -O2 \
  -I scintilla/cocoa -I scintilla/include \
  tests/cocoa/MarginClippingProbe.mm build/libscintilla.a \
  -framework Cocoa -framework QuartzCore -o build/MarginClippingProbe
build/MarginClippingProbe
```

These paths assume the default Unix Makefiles or Ninja CMake layout. The probe
needs a logged-in macOS GUI session but creates only a hidden window with
activation prohibited. It uses no application configuration or user documents.
Building only `scintilla` avoids needing the host application target.

The probe paints the real ruler through AppKit into a bitmap surrounded by a
sentinel color. It checks that drawing leaves all pixels outside the ruler
unchanged and that visible number glyphs remain inside. It covers 1x/2x bitmap
scales, buffered drawing enabled/disabled, and several partial-line positions.

This checks the ruler's drawing boundary, not native invalidation scheduling,
a physical Retina display, or trackpad physics. For manual validation, scroll
until the first line is partly visible, then move the caret between lines.
Numbers must remain inside the ruler and must not paint over the tab bar.
