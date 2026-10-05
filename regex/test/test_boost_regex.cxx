// SPDX-License-Identifier: MIT
//
// Standalone harness for the Boost.Regex backend (BoostRegExSearch.cxx + the
// UTF-32-ported UTF8DocumentIterator), the editor's only regex engine. It calls
// CreateBoostRegexSearch() directly against a real Scintilla Document and
// focuses on what the old per-line std::regex backend could not do: multi-line
// / cross-line matching (DOTMATCHESNL), Boost-only dialect (lookbehind, \K),
// Unicode-aware classes and case folding, and UTF-8 correctness through the
// 32-bit-wchar_t iterator.
//
// Build & run:  ctest (target test_boost_regex) or bash regex/test/run_boost.sh
// (exits non-zero on any failure).

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <array>
#include <forward_list>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "ScintillaTypes.h"
#include "ILoader.h"
#include "ILexer.h"
#include "Debugging.h"
#include "CharacterType.h"
#include "CharacterCategoryMap.h"
#include "Position.h"
#include "UniqueString.h"
#include "SplitVector.h"
#include "Partitioning.h"
#include "RunStyles.h"
#include "CellBuffer.h"
#include "PerLine.h"
#include "CharClassify.h"
#include "CaseFolder.h"
#include "Decoration.h"
#include "Document.h"

using namespace Scintilla;
using namespace Scintilla::Internal;

// The named factory from BoostRegExSearch.cxx.
namespace Scintilla::Internal {
    RegexSearchBase *CreateBoostRegexSearch(CharClassify *charClassTable);
}

// SCFIND_REGEXP_DOTMATCHESNL — make '.' span line ends (Boost match_default).
static const int DOTMATCHESNL = 0x10000000;
#ifndef SC_CP_UTF8
#define SC_CP_UTF8 65001
#endif

// Minimal platform-layer stubs so we can link the platform-agnostic core.
namespace Scintilla::Internal::Platform {
    void DebugPrintf(const char *, ...) noexcept {}
    void Assert(const char *c, const char *file, int line) noexcept {
        fprintf(stderr, "Assertion failed: %s at %s:%d\n", c, file, line);
    }
}

static int g_fail = 0;

struct Eng {
    Document doc{DocumentOption::Default};
    CharClassify cc;
    RegexSearchBase *re;
    Eng(const std::string &text) {
        doc.SetDBCSCodePage(SC_CP_UTF8);   // exercise the UTF-8 (wchar_t) path
        doc.InsertString(0, text.data(), (Sci::Position)text.size());
        re = CreateBoostRegexSearch(&cc);
    }
    ~Eng() { delete re; }
    Sci::Position find(const char *pat, Sci::Position minPos, Sci::Position maxPos,
                       int flags, Sci::Position *len, bool caseSens = true) {
        return re->FindText(&doc, minPos, maxPos, pat, caseSens, false, false,
                            static_cast<Scintilla::FindOption>(flags), len);
    }
};

static void check(const char *label, bool cond, const std::string &detail = "") {
    printf("[%s] %s %s\n", cond ? "PASS" : "FAIL", label, detail.c_str());
    if (!cond) g_fail++;
}

int main() {
    // 1) Cross-line match WITH dot-matches-newline — the headline capability.
    {
        std::string t = "<head id=\"x\">\n  <title>Hi</title>\n</head>\nbody";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("<head.*</head>", 0, (Sci::Position)t.size(), DOTMATCHESNL, &len);
        std::string got = (p >= 0) ? t.substr(p, len) : "<none>";
        bool ok = (p == 0) && (len == (Sci::Position)t.find("</head>") + 7 - 0);
        check("multiline dotall <head>..</head>", ok,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 2) Without DOTMATCHESNL, '.' must NOT cross the newline (no full match).
    {
        std::string t = "<head>\n</head>";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("<head>.*</head>", 0, (Sci::Position)t.size(), 0, &len);
        check("no-dotall does not span newline", p < 0,
              "pos=" + std::to_string(p));
    }

    // 3) Explicit cross-line via \n in the pattern (always allowed).
    {
        std::string t = "alpha\nbeta";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("alpha\\nbeta", 0, (Sci::Position)t.size(), 0, &len);
        check("explicit \\n bridges two lines", p == 0 && len == 10,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 4) Boost-only dialect: lookbehind (libc++ std::regex lacks this).
    {
        std::string t = "foobar baz qux";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("(?<=foo)bar", 0, (Sci::Position)t.size(), 0, &len);
        check("lookbehind (?<=foo)bar", p == 3 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 5) Within-line basic sanity + case-insensitive.
    {
        std::string t = "Hello WORLD";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("world", 0, (Sci::Position)t.size(), 0, &len, false);
        check("case-insensitive within line", p == 6 && len == 5,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 6) UTF-8 / multi-byte: '.' counts whole code points, and an astral char.
    {
        // "café" then an emoji (U+1F600, 4 UTF-8 bytes) then "!"
        std::string t = "caf\xC3\xA9\xF0\x9F\x98\x80!";
        Eng e(t);
        Sci::Position len = 0;
        // match the 'é' (2-byte) followed by the emoji (one astral code point)
        Sci::Position p = e.find("\xC3\xA9.", 0, (Sci::Position)t.size(), 0, &len);
        // Expect: starts at byte 3 (the 'é'), spans é(2)+emoji(4) = 6 bytes.
        check("utf8 dot spans astral code point", p == 3 && len == 6,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 7) Substitution with a backreference (SubstituteByPosition path).
    {
        std::string t = "John Smith";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("(\\w+) (\\w+)", 0, (Sci::Position)t.size(), 0, &len);
        bool found = (p == 0 && len == 10);
        Sci::Position subLen = 0;
        const char *sub = e.re->SubstituteByPosition(&e.doc, "\\2, \\1", &subLen);
        std::string got = sub ? std::string(sub, subLen) : "<null>";
        check("substitute backrefs \\2, \\1", found && got == "Smith, John",
              "got='" + got + "'");
    }

    // 8) \K resets the match start (Boost-only).
    {
        std::string t = "price: 42 EUR";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("price: \\K\\d+", 0, (Sci::Position)t.size(), 0, &len);
        check("\\K keeps only the digits", p == 7 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 9) Unicode-aware case folding and classes (UTF-8 regex locale).
    {
        std::string t = "CAF\xC3\x89 \xD0\x94\xD0\x90";   // "CAFÉ ДА"
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("caf\xC3\xA9", 0, (Sci::Position)t.size(), 0, &len, false);
        check("icase folds \u00C9 to \u00E9", p == 0 && len == 5,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        len = 0;
        p = e.find("\xD0\xB4\xD0\xB0", 0, (Sci::Position)t.size(), 0, &len, false);
        check("icase folds Cyrillic", p == 6 && len == 4,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        len = 0;
        p = e.find("\\b\\w+$", 0, (Sci::Position)t.size(), 0, &len);
        check("\\w matches Cyrillic letters", p == 6 && len == 4,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 10) $ at the end of a search range that stops mid-line matches, as on
    //     Windows (no match_not_eol since 7.9.1); ^ looks before the range.
    {
        std::string t = "foobar\nfoo";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("foo$", 0, 3, 0, &len);
        check("foo$ in [0,3) of 'foobar' matches at the range end", p == 0 && len == 3,
              "pos=" + std::to_string(p));
        len = 0;
        p = e.find("^bar", 3, 6, 0, &len);
        check("^bar in [3,6) does not match mid-line", p < 0, "pos=" + std::to_string(p));
        len = 0;
        p = e.find("foo$", 0, (Sci::Position)t.size(), 0, &len);
        check("foo$ matches the real line end", p == 7 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // 11) Bytes 0xF8-0xFF never start UTF-8; each is one (invalid) character.
    //     0xFE/0xFF used to read past the lead-byte mask table (ASan).
    {
        std::string t = "a\xFE\xFF" "b\xF8z";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("a..b", 0, (Sci::Position)t.size(), 0, &len);
        check("0xFE and 0xFF are one character each", p == 0 && len == 4,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        len = 0;
        p = e.find("b.z", 0, (Sci::Position)t.size(), 0, &len);
        check("0xF8 is one character", p == 3 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    printf("\n%s (%d failure%s)\n", g_fail ? "FAILURES" : "ALL PASS",
           g_fail, g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
