# Cocoa scrolling regression probes

Run on macOS with Xcode Command Line Tools, Python 3, and an existing successful
CMake build of `NotepadPlusPlusMac` using Ninja or Unix Makefiles:

```sh
python3 tests/cocoa/run-scroll-probes.py build
```

Replace `build` with your build directory. To run individual probes, append their
names, for example:

```sh
python3 tests/cocoa/run-scroll-probes.py build ScrollWorkProbe GestureTransitionProbe
```

The runner compiles native executables against the existing application objects
and Scintilla/Lexilla libraries. It assumes the Makefiles/Ninja CMake object layout;
Xcode generator builds are not supported. Executables, logs, and a disposable
configuration profile are written under `<build>/scroll-probes/`. Application
probes compile the original path helpers and set `CFFIXED_USER_HOME` before launch
so they use this profile. They create hidden windows with activation prohibited.

| Probe | Coverage |
| --- | --- |
| `ScrollProbe` | Precise and discrete wheel positions, partial lines, wrap, selection/hit testing, and dark-theme rendering during fast scrolling. |
| `EditorScrollProbe` | Link marking outside painting, coalescing, URL edits, indicator feedback, and timer cancellation on close. |
| `OverscrollProbe` | Solid document background above Y=0 during elastic scrolling, with document glyphs preserved. |
| `ScrollWorkProbe` | Avoiding selection/status/tab/map work during viewport changes; actual edits, lazy lexer styling, direct plugin style changes, language/UDL changes, and map document replacement. |
| `GestureTransitionProbe` | Residual clip geometry at both edges/axes, touch/momentum phases, late overscroll, cancellation, content insets, and diagonal momentum. |

The gesture fixture temporarily bypasses clip constraints to install an
out-of-range origin captured from a real elastic return, then restores native
constraints before sending events. It tests host geometry correction and state
transitions; it does **not** reproduce the complete native trackpad physics,
measure display FPS, or prove that a physical tap cancels an advancing animation.
Printed offscreen drawing times are diagnostic and are not display frame rates.

## Manual trackpad validation

Use a document with enough lines and long lines to allow momentum on either axis
without immediately reaching the other edge. Keep both native elasticities enabled.

1. Scroll slowly and quickly vertically; precise motion should retain partial lines.
2. Overscroll horizontally, release, then scroll vertically in both directions.
3. Overscroll vertically at the top/bottom, then scroll horizontally away from its edges.
4. Include small initial directional jitter and diagonal gestures near corners.
5. Tap the trackpad during momentum; normal AppKit touch-to-stop behavior should remain.
6. Check the top overscroll area for repeated line backgrounds or unpainted strips.

Repeat with word wrap, Document Map, and clickable links. Native momentum recovery,
elastic return, cancellation, and visual smoothness require these real-window checks.
