// SPDX-License-Identifier: MIT
//
// Standalone unit harness for the editor's regex search (CreateRegexSearch(),
// i.e. the Boost.Regex backend in regex/BoostRegExSearch.cxx) against a real
// Scintilla Document. Reproduces macOS issue #167 (regex can't find "\r\n") and
// guards the ^/$ anchoring + empty-match machinery (#151) against regression.
// These cases were written for the old per-line std::regex backend and kept
// when Boost became the only engine; the few places where Boost (like Windows
// Notepad++) differs are noted inline.
//
// Build & run:  ctest (target test_npp_regex) or regex/test/run.sh. Exits
// non-zero if any case fails.

// STL first — Scintilla's Document.h/PerLine.h use std::map/forward_list/etc.
// without including them, expecting the TU to have done so (see NppRegexSearch.cxx).
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <array>
#include <chrono>
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
#include "BoostRegexSearch.h"

using namespace Scintilla;
using namespace Scintilla::Internal;

// Minimal platform-layer stubs so we can link the platform-agnostic Scintilla
// core without the Cocoa layer.
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
        doc.InsertString(0, text.data(), (Sci::Position)text.size());
        re = CreateRegexSearch(&cc);
    }
    ~Eng() { delete re; }
    // Forward find from minPos to end.
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

// Count all forward matches like a Replace-All / Count loop op would.
static int countAll(const std::string &text, const char *pat, int flags) {
    Eng e(text);
    int n = 0;
    Sci::Position pos = 0, end = (Sci::Position)text.size();
    for (int guard = 0; guard < 100000; ++guard) {
        Sci::Position len = 0;
        Sci::Position p = e.find(pat, pos, end, flags, &len);
        if (p < 0) break;
        n++;
        // advance like a non-replacing loop (Count/MarkAll): step past match,
        // at least one position to guarantee progress on empty matches.
        pos = (len > 0) ? p + len : p + 1;
        if (pos > end) break;
    }
    return n;
}

int main() {
    const int LOOP  = SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH | SCFIND_REGEXP_SKIPCRLFASONE;
    const int FINDN = SCFIND_REGEXP_EMPTYMATCH_ALL | SCFIND_REGEXP_SKIPCRLFASONE;

    // ---- Issue #167: literal CRLF -------------------------------------------
    {
        std::string t = "alpha\r\nbeta\r\ngamma";   // 2 CRLFs
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("\\r\\n", 0, (Sci::Position)t.size(), FINDN, &len);
        check("#167 find \\r\\n returns a match", p >= 0,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        check("#167 \\r\\n match has length 2", len == 2, "len=" + std::to_string(len));
        check("#167 \\r\\n first match at pos 5", p == 5, "pos=" + std::to_string(p));
        check("#167 count of \\r\\n == 2", countAll(t, "\\r\\n", LOOP) == 2,
              "got " + std::to_string(countAll(t, "\\r\\n", LOOP)));
        check("#167 count of \\n == 2", countAll(t, "\\n", LOOP) == 2,
              "got " + std::to_string(countAll(t, "\\n", LOOP)));
    }

    // ---- Regression: $ / ^ anchors on a CRLF buffer -------------------------
    {
        std::string t = "foo\r\nbar\r\nbaz";   // 3 lines
        // "foo$" should match exactly the "foo" at content end of line 0.
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("foo$", 0, (Sci::Position)t.size(), FINDN, &len);
        check("foo$ matches at 0 len 3", p == 0 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // "^bar" should match the bar at start of line 1 (pos 5).
        Sci::Position p2 = e.find("^bar", 0, (Sci::Position)t.size(), FINDN, &len);
        check("^bar matches at 5 len 3", p2 == 5 && len == 3,
              "pos=" + std::to_string(p2) + " len=" + std::to_string(len));
        // Count of "^" should be one per line (3), NOT doubled by CRLF interior.
        int caretCount = countAll(t, "^", LOOP);
        check("^ count == 3 (one per line, no CRLF interior over-fire)", caretCount == 3,
              "got " + std::to_string(caretCount));
        // Count of "$" should be one per line (3).
        int dollarCount = countAll(t, "$", LOOP);
        check("$ count == 3 (one per line, no CRLF interior over-fire)", dollarCount == 3,
              "got " + std::to_string(dollarCount));
    }

    // ---- Regression: word search still finds content ------------------------
    {
        std::string t = "foo\r\nbar\r\nbaz";
        check("count of \\w+ == 3", countAll(t, "\\w+", LOOP) == 3,
              "got " + std::to_string(countAll(t, "\\w+", LOOP)));
        check("literal 'bar' found once", countAll(t, "bar", LOOP) == 1,
              "got " + std::to_string(countAll(t, "bar", LOOP)));
    }

    // ---- Regression: empty-match termination on file ending in \n (#151) ----
    {
        std::string t = "x\n";
        // Replace-All-style loop with NOTAFTERMATCH must terminate and not blow
        // the 100k guard. We just ensure countAll returns a small finite number.
        int n = countAll(t, "$", LOOP);
        check("$ on 'x\\n' terminates with small count", n >= 1 && n <= 3,
              "got " + std::to_string(n));
    }

    // ---- EOL literal variants & terminator-extending patterns ---------------
    {
        std::string t = "foo\r\nbar\r\nbaz";
        Eng e(t);
        Sci::Position len = 0;
        // "foo\r\n" should match the whole "foo\r\n" (len 5) at pos 0.
        Sci::Position p = e.find("foo\\r\\n", 0, (Sci::Position)t.size(), FINDN, &len);
        check("foo\\r\\n matches at 0 len 5", p == 0 && len == 5,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // "o\r" should match "o\r" (offset 2 len 2).
        len = 0; p = e.find("o\\r", 0, (Sci::Position)t.size(), FINDN, &len);
        check("o\\r matches at 2 len 2", p == 2 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // "\r" alone matches at offset 3 len 1.
        len = 0; p = e.find("\\r", 0, (Sci::Position)t.size(), FINDN, &len);
        check("\\r matches at 3 len 1", p == 3 && len == 1,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // ".$" matches the last content char before EOL ("o" at offset 2), NOT
        // anything in the terminator (. excludes line terminators).
        len = 0; p = e.find(".$", 0, (Sci::Position)t.size(), FINDN, &len);
        check(".$ matches at 2 len 1", p == 2 && len == 1,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // Greedy `\r?` takes the CR, as Perl and Windows Notepad++ do. (The old
        // per-line std::regex backend could only return "foo" here.)
        len = 0; p = e.find("foo\\r?", 0, (Sci::Position)t.size(), FINDN, &len);
        check("foo\\r? is greedy: 'foo\\r' (len 4)", p == 0 && len == 4,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // ---- Capture-group integrity --------------------------------------------
    {
        // Realistic replace pattern: (\w+) before a CRLF. The content pass cannot
        // match (needs \r\n), so the terminator pass wins outright and group 1
        // must capture the word — this is what `\1` in a replacement relies on.
        std::string t = "foo\r\nbar\r\nbaz";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("(\\w+)\\r\\n", 0, (Sci::Position)t.size(), FINDN, &len);
        check("(\\w+)\\r\\n matches foo\\r\\n at 0 len 5", p == 0 && len == 5,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // Verify group 1 spans exactly "foo" [0,3) via SubstituteByPosition(\1).
        std::string repl = "\\1";
        Sci::Position rlen = (Sci::Position)repl.size();
        const char *sub = e.re->SubstituteByPosition(&e.doc, repl.data(), &rlen);
        std::string got(sub, sub + rlen);
        check("(\\w+)\\r\\n group 1 == 'foo'", got == "foo", "got '" + got + "'");
    }

    // ---- Anchored-branch-before-EOL-branch alternation ----------------------
    {
        // `(foo$)|(foo\r\n)`: a hypothetical correct engine ($ at line-content
        // end) tries alt 1 first and matches "foo" with group 1 set.
        // The content pass reproduces exactly that, and the conservative tie rule
        // keeps it — so group 1 (not group 2) is the one that participates, and
        // \1/\2 in a replacement stay correct.
        std::string t = "foo\r\nbar";
        Eng e(t);
        Sci::Position len = 0;
        Sci::Position p = e.find("(foo$)|(foo\\r\\n)", 0, (Sci::Position)t.size(), FINDN, &len);
        check("(foo$)|(foo\\r\\n) picks alt 1 'foo' (len 3), not the CRLF branch",
              p == 0 && len == 3, "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        std::string g1 = "\\1", g2 = "\\2";
        Sci::Position l1 = (Sci::Position)g1.size();
        const char *s1 = e.re->SubstituteByPosition(&e.doc, g1.data(), &l1);
        std::string got1(s1, s1 + l1);
        check("(foo$)|(foo\\r\\n) group 1 == 'foo' (capture not corrupted)",
              got1 == "foo", "got '" + got1 + "'");
    }

    // ---- Empty line: CRLF on a blank line is matchable ----------------------
    {
        std::string t = "a\r\n\r\nb";   // line1 "a", line2 "" (blank), line3 "b"
        // count of \r\n == 2
        check("blank-line buffer: count \\r\\n == 2", countAll(t, "\\r\\n", LOOP) == 2,
              "got " + std::to_string(countAll(t, "\\r\\n", LOOP)));
        // ^$ (empty line) should match once (the blank line).
        check("^$ matches blank line exactly once", countAll(t, "^$", LOOP) == 1,
              "got " + std::to_string(countAll(t, "^$", LOOP)));
    }

    // ---- LF-only buffer (Unix EOL) ------------------------------------------
    {
        std::string t = "foo\nbar\nbaz";
        check("LF buffer: count \\n == 2", countAll(t, "\\n", LOOP) == 2,
              "got " + std::to_string(countAll(t, "\\n", LOOP)));
        check("LF buffer: foo$ count 1", countAll(t, "foo$", LOOP) == 1,
              "got " + std::to_string(countAll(t, "foo$", LOOP)));
        check("LF buffer: ^ count 3", countAll(t, "^", LOOP) == 3,
              "got " + std::to_string(countAll(t, "^", LOOP)));
    }

    // ---- Find within a selection that ends mid-line: $ must NOT match -------
    {
        std::string t = "foobar";   // single line, no EOL
        Eng e(t);
        Sci::Position len = 0;
        // Search range [0,3): "foo". $ should NOT match at 3 (range truncated
        // mid-line; not the real line end) -> match_not_eol.
        Sci::Position p = e.find("foo$", 0, 3, FINDN, &len);
        check("foo$ does NOT match when range ends mid-line", p < 0,
              "pos=" + std::to_string(p));
    }

    // ---- Clean clamp: maxPos before a CRLF (not splitting it) excludes it ----
    {
        std::string t = "foobar\r\nx";   // CRLF at 6
        Eng e(t);
        Sci::Position len = 0;
        // [0,6) ends exactly at the \r (pos 6 is a clean boundary, not snapped).
        // The CRLF is outside the range, so \r\n must NOT be found.
        Sci::Position p = e.find("\\r\\n", 0, 6, FINDN, &len);
        check("\\r\\n in [0,6) excludes the CRLF at 6 (no overshoot)", p < 0,
              "pos=" + std::to_string(p));
    }

    // ---- Backward search (Find Previous) ------------------------------------
    {
        std::string t = "foo\r\nbar\r\nbaz";   // CRLFs at 3 and 8
        Eng e(t);
        Sci::Position len = 0;
        // Backward find of \r\n from end: minPos>maxPos signals reverse.
        Sci::Position p = e.find("\\r\\n", (Sci::Position)t.size(), 0, FINDN, &len);
        check("backward \\r\\n finds LAST one at 8", p == 8 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // Backward find of "bar".
        len = 0; p = e.find("bar", (Sci::Position)t.size(), 0, FINDN, &len);
        check("backward 'bar' at 5", p == 5 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // Backward find of foo$ -> matches foo at 0.
        len = 0; p = e.find("foo$", (Sci::Position)t.size(), 0, FINDN, &len);
        check("backward foo$ at 0", p == 0 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // ---- UTF-8 path (multibyte content + CRLF) ------------------------------
    {
        // "héllo\r\nwörld"  (é, ö are 2-byte UTF-8). Bytes:
        // h(1) é(2) l l o = 6 bytes content, then \r\n, then w ö r l d.
        std::string t = "h\xC3\xA9llo\r\nw\xC3\xB6rld";
        Document doc{DocumentOption::Default};
        doc.SetDBCSCodePage(65001);   // SC_CP_UTF8 -> exercises UTF8Iterator path
        doc.InsertString(0, t.data(), (Sci::Position)t.size());
        CharClassify cc; RegexSearchBase *re = CreateRegexSearch(&cc);
        Sci::Position len = 0;
        Sci::Position crlf = (Sci::Position)t.find('\r');
        Sci::Position p = re->FindText(&doc, 0, (Sci::Position)t.size(), "\\r\\n",
                                       true, false, false,
                                       static_cast<Scintilla::FindOption>(FINDN), &len);
        check("UTF-8: \\r\\n found at the CRLF byte offset", p == crlf && len == 2,
              "pos=" + std::to_string(p) + " expected=" + std::to_string(crlf) +
              " len=" + std::to_string(len));
        // Anchored match still works on the UTF-8 path.
        len = 0;
        p = re->FindText(&doc, 0, (Sci::Position)t.size(), "llo$", true, false, false,
                         static_cast<Scintilla::FindOption>(FINDN), &len);
        check("UTF-8: llo$ matches end of first line", p == crlf - 3 && len == 3,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        delete re;
    }

    // ---- Selection-clamped ranges (Find in Selection) ----------------------
    {
        std::string t = "foo\r\nbar\r\nbaz";   // CRLFs at 3 and 8
        Eng e(t);
        Sci::Position len = 0;
        // Forward search restricted to [0,8): should find the FIRST \r\n (at 3)
        // and must NOT reach the second CRLF at 8 (outside the range).
        Sci::Position p = e.find("\\r\\n", 0, 8, FINDN, &len);
        check("clamped fwd \\r\\n in [0,8) finds 3", p == 3 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // A maxPos that falls BETWEEN \r and \n (here 4) is not widened: the
        // Boost backend (as on Windows) only moves range ends out of multi-byte
        // characters, so the CRLF is not inside [0,4) and cannot match. The UI
        // never produces such a range (the caret can't sit inside a CRLF).
        len = 0; p = e.find("\\r\\n", 0, 4, FINDN, &len);
        check("fwd \\r\\n with maxPos splitting CRLF finds nothing (range not widened)",
              p < 0, "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        len = 0; p = e.find("\\r\\n", 6, (Sci::Position)t.size(), FINDN, &len);
        check("clamped fwd \\r\\n from mid-line 6 finds 8", p == 8 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    // ---- Backward search with clamped ranges --------------------------------
    {
        std::string t = "foo\r\nbar\r\nbaz";
        Eng e(t);
        Sci::Position len = 0;
        // Backward within [10..3] (start high=10, end low=3): the only \r\n fully
        // inside is at 3 (the one at 8 is inside too). Rightmost is 8.
        Sci::Position p = e.find("\\r\\n", 10, 3, FINDN, &len);
        check("clamped bwd \\r\\n in (3,10] finds rightmost 8", p == 8 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // Backward starting from 7 (mid second 'bar' line, before the 2nd CRLF):
        // rightmost \r\n at or below start is the first one at 3.
        len = 0; p = e.find("\\r\\n", 7, 0, FINDN, &len);
        check("clamped bwd \\r\\n from 7 finds 3", p == 3 && len == 2,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
        // Backward find of \n.
        len = 0; p = e.find("\\n", (Sci::Position)t.size(), 0, FINDN, &len);
        check("bwd \\n finds rightmost at 9", p == 9 && len == 1,
              "pos=" + std::to_string(p) + " len=" + std::to_string(len));
    }

    printf("\n%s (%d failure%s)\n", g_fail ? "FAILURES" : "ALL PASS",
           g_fail, g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
