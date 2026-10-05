// SPDX-License-Identifier: MIT
//
// The two Platform hooks Scintilla's core calls, for the headless tests. The
// app gets them from scintilla/cocoa/PlatCocoa.mm.

#include <cstdio>

namespace Scintilla::Internal::Platform {
    void DebugPrintf(const char *, ...) noexcept {}
    void Assert(const char *c, const char *file, int line) noexcept {
        fprintf(stderr, "Assertion failed: %s at %s:%d\n", c, file, line);
    }
}
