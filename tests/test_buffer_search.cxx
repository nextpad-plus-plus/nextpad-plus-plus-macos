// SPDX-License-Identifier: MIT
//
// Headless tests for NppBufferSearch: the editor's Boost.Regex engine and
// search loops over a Scintilla Document, as Find/Replace in Files uses them.
// The flag sets below are the ones SearchCore builds for the loop operations
// (Find All, Count, Replace All, Find in Files).
//
// Run with ctest (see CMakeLists.txt). Exits non-zero on any failure.

#include <chrono>
#include <cstdio>
#include <atomic>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "Scintilla.h"
#include "BoostRegexSearch.h"
#include "NppBufferSearch.h"

using NppSearch::BufferSearch;
using NppSearch::Pos;

static int g_fail = 0;

static void check(const std::string &label, bool cond, const std::string &detail = "") {
    printf("[%s] %s %s\n", cond ? "PASS" : "FAIL", label.c_str(), detail.c_str());
    if (!cond) g_fail++;
}

static const int kLoop = SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH | SCFIND_REGEXP_SKIPCRLFASONE;
static const int kRegex = SCFIND_REGEXP | kLoop;
static const int kRegexCase = kRegex | SCFIND_MATCHCASE;
static const int kRegexDotAll = kRegexCase | SCFIND_REGEXP_DOTMATCHESNL;

using Hits = std::vector<std::pair<Pos, Pos>>;   // (start, end)

static Hits findAll(const std::string &text, const std::string &needle, int flags,
                    const char *wordChars = nullptr) {
    BufferSearch s(wordChars);
    s.SetSearch(needle, flags, "", false);
    s.SetText(text.data(), text.size());
    Hits hits;
    NppSearch::ForEachMatch(s, 0, s.Length(), [&](Pos a, Pos b) {
        hits.emplace_back(a, b);
        return true;
    });
    return hits;
}

static std::string replaceAll(const std::string &text, const std::string &needle, int flags,
                              const std::string &replacement, Pos *count = nullptr) {
    BufferSearch s;
    s.SetSearch(needle, flags, replacement, (flags & SCFIND_REGEXP) != 0);
    s.SetText(text.data(), text.size());
    const Pos n = NppSearch::ReplaceAll(s, 0, s.Length());
    if (count) *count = n;
    return s.Text();
}

static std::string show(const Hits &hits) {
    std::string out;
    for (const auto &h : hits)
        out += "[" + std::to_string(h.first) + "," + std::to_string(h.second) + ")";
    return out.empty() ? "<none>" : out;
}

static std::string esc(const std::string &s) {
    std::string out;
    for (char c : s) {
        if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else out += c;
    }
    return "'" + out + "'";
}

static void checkReplace(const std::string &label, const std::string &text, const std::string &needle,
                         int flags, const std::string &replacement, const std::string &expected) {
    const std::string got = replaceAll(text, needle, flags, replacement);
    check(label, got == expected, "got " + esc(got) + " want " + esc(expected));
}

int main() {
    // ---- Regex syntax the old per-line std::regex engine lacked ------------
    {
        Hits h = findAll("foobar xbar", "(?<=foo)bar", kRegexCase);
        check("lookbehind (?<=foo)bar", h == Hits{{3, 6}}, show(h));
        h = findAll("foobar xbar", "(?<!foo)bar", kRegexCase);
        check("negative lookbehind (?<!foo)bar", h == Hits{{8, 11}}, show(h));
        h = findAll("price: 42 EUR", "price: \\K\\d+", kRegexCase);
        check("\\K drops the prefix from the match", h == Hits{{7, 9}}, show(h));
        checkReplace("\\K replace keeps the prefix", "key=old\nkey=old2", "key=\\K\\w+", kRegexCase,
                     "new", "key=new\nkey=new");
        h = findAll("ab12cd", "(?i)AB\\d+", kRegexCase);
        check("inline (?i) modifier", h == Hits{{0, 4}}, show(h));
        h = findAll("aaa", "a{2}+", kRegexCase);
        check("possessive quantifier", h == Hits{{0, 2}}, show(h));
    }

    // ---- Whole-buffer matching: patterns can span lines ---------------------
    {
        Hits h = findAll("foo\r\nbar\nbaz", "foo\\r\\nbar", kRegexCase);
        check("explicit CRLF spans lines", h == Hits{{0, 8}}, show(h));
        h = findAll("<p>\none\n</p>", "<p>.*</p>", kRegexCase);
        check("'.' does not cross line ends by default", h.empty(), show(h));
        h = findAll("<p>\none\n</p>", "<p>.*</p>", kRegexDotAll);
        check("'. matches newline' spans lines", h == Hits{{0, 12}}, show(h));
        h = findAll("a\nb\nc", "\\n", kRegexCase);
        check("\\n finds every LF (#208)", h == Hits{{1, 2}, {3, 4}}, show(h));
        h = findAll("one\ntwo\n", "^\\w+$", kRegexCase);
        check("^ and $ are line anchors", h == Hits{{0, 3}, {4, 7}}, show(h));
        h = findAll("one\ntwo", "\\Aone|two\\z", kRegexCase);
        check("\\A and \\z are buffer anchors", h == Hits{{0, 3}, {4, 7}}, show(h));
    }

    // ---- Several hits on one line --------------------------------------------
    {
        Hits h = findAll("ab ab ab\nab", "ab", kRegexCase);
        check("every hit on a line is found", h.size() == 4, show(h));
        h = findAll("ab ab ab\nab", "ab", SCFIND_MATCHCASE);
        check("normal mode: every hit on a line", h.size() == 4, show(h));
    }

    // ---- Replacement format (Boost format_all, as SCI_REPLACETARGETRE) ------
    {
        const std::string t = "John Smith\nJane Doe";
        const char *pat = "(\\w+) (\\w+)";
        checkReplace("$2, $1", t, pat, kRegexCase, "$2, $1", "Smith, John\nDoe, Jane");
        checkReplace("\\2, \\1", t, pat, kRegexCase, "\\2, \\1", "Smith, John\nDoe, Jane");
        checkReplace("$0 and $& are the whole match", "ab", "ab", kRegexCase, "[$0|$&]", "[ab|ab]");
        checkReplace("$+{name} named groups", t, "(?<first>\\w+) (?<last>\\w+)", kRegexCase,
                     "$+{last} $+{first}", "Smith John\nDoe Jane");
        checkReplace("${1} numbered group in braces", "ab", "(a)", kRegexCase, "${1}1", "a1b");
        checkReplace("?1 conditional", "a b", "(a)|(b)", kRegexCase, "(?1A:B)", "A B");
        checkReplace("\\n and \\t escapes in the replacement", "a,b", ",", kRegexCase, "\\n\\t", "a\n\tb");
        checkReplace("\\u \\U \\E case conversion", "foo bar", "(\\w+) (\\w+)", kRegexCase,
                     "\\u$1 \\U$2\\E!", "Foo BAR!");
        checkReplace("\\$ and \\\\ are literal", "x", "x", kRegexCase, "\\$1\\\\", "$1\\");
        checkReplace("normal mode replacement is literal", "a.b a.b", "a.b", SCFIND_MATCHCASE, "$1\\n",
                     "$1\\n $1\\n");
    }

    // ---- Line-end replacements (#360, #151) ----------------------------------
    {
        checkReplace("replace \\n (#360)", "a\nb\nc", "\\n", kRegexCase, ",", "a,b,c");
        checkReplace("replace \\r\\n", "a\r\nb\r\nc", "\\r\\n", kRegexCase, " ", "a b c");
        checkReplace("join lines with \\R", "a\r\nb\nc\rd", "\\R", kRegexCase, "|", "a|b|c|d");
        Pos n = 0;
        std::string got = replaceAll("a\nb\n", "$", kRegexCase, ";", &n);
        check("$ -> ; on 'a\\nb\\n' terminates, once per line (#151)", got == "a;\nb;\n;" && n == 3,
              "got " + esc(got) + " n=" + std::to_string(n));
        checkReplace("^ -> '> ' on CRLF text", "a\r\nb", "^", kRegexCase, "> ", "> a\r\n> b");
        checkReplace("empty-line removal ^\\r?\\n", "a\n\n\nb\n", "^\\r?\\n", kRegexCase, "", "a\nb\n");
    }

    // ---- Empty matches: one per position, CRLF counted once -------------------
    {
        Hits h = findAll("foo\r\nbar\r\nbaz", "^", kRegexCase);
        check("^ count on CRLF text == 3", h.size() == 3, show(h));
        h = findAll("foo\r\nbar\r\nbaz", "$", kRegexCase);
        check("$ count on CRLF text == 3", h.size() == 3, show(h));
        h = findAll("ab", "x*", kRegexCase);
        check("x* on 'ab' gives the 3 empty matches", h.size() == 3, show(h));
    }

    // ---- Normal mode, match case, whole word ---------------------------------
    {
        Hits h = findAll("foo Foo fOO", "FOO", 0);
        check("normal: case-insensitive", h.size() == 3, show(h));
        h = findAll("foo Foo fOO", "FOO", SCFIND_MATCHCASE);
        check("normal: match case", h.empty(), show(h));
        h = findAll("foo food foo_ foo. xfoo", "foo", SCFIND_WHOLEWORD);
        check("normal: whole word", h == Hits{{0, 3}, {14, 17}}, show(h));
        h = findAll("caf\xC3\xA9 CAF\xC3\x89", "caf\xC3\xA9", 0);
        check("normal: non-ASCII case folding", h.size() == 2, show(h));
        h = findAll("a.b axb", "a.b", SCFIND_MATCHCASE);
        check("normal: '.' is literal", h == Hits{{0, 3}}, show(h));
        // Custom word characters (SCI_SETWORDCHARS): '-' joins words.
        const char *wordChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";
        h = findAll("foo-bar foo", "foo", SCFIND_WHOLEWORD);
        check("whole word, default word chars", h.size() == 2, show(h));
        h = findAll("foo-bar foo", "foo", SCFIND_WHOLEWORD, wordChars);
        check("whole word, '-' as a word char", h == Hits{{8, 11}}, show(h));
        h = findAll("foo\tbar", "o\tb", SCFIND_MATCHCASE);
        check("extended: expanded \\t matches a tab", h == Hits{{2, 5}}, show(h));
    }

    // ---- UTF-8 ----------------------------------------------------------------
    {
        // "日本語 テキスト": '.' and \w work on code points, offsets are bytes.
        const std::string t = "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E \xF0\x9F\x98\x80!";
        Hits h = findAll(t, "\\w+", kRegexCase);
        check("\\w+ matches CJK as one word", !h.empty() && h[0] == std::make_pair(Pos(0), Pos(9)), show(h));
        h = findAll(t, " .!", kRegexCase);
        check("'.' spans an astral code point", h == Hits{{9, 15}}, show(h));
    }

    // ---- Errors ---------------------------------------------------------------
    {
        BufferSearch s;
        s.SetSearch("(unclosed", kRegexCase, "", true);
        s.SetText("text", 4);
        Pos end = 0;
        const Pos found = s.Find(0, 4, &end);
        check("invalid regex: no match, InvalidRegex status",
              found < 0 && s.LastStatus() == NppSearch::Status::InvalidRegex,
              "msg=" + s.ErrorMessage());

        // Catastrophic backtracking: Boost gives up (regex_error "complexity
        // exceeded", reported like an invalid pattern) instead of hanging.
        std::string many(5000, 'a');
        BufferSearch c;
        c.SetSearch("(a|aa)*c", kRegexCase, "", true);
        c.SetText(many.data(), many.size());
        const auto t0 = std::chrono::steady_clock::now();
        const Pos f = c.Find(0, c.Length(), &end);
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        check("catastrophic pattern stops with an error in bounded time",
              f < 0 && c.LastStatus() != NppSearch::Status::Ok && secs < 120.0,   // generous: sanitizer builds are slow
              "status=" + std::to_string((int)c.LastStatus()) + " secs=" + std::to_string(secs));
    }

    // ---- Lines ------------------------------------------------------------------
    {
        BufferSearch s;
        const std::string t = "a\rb\r\nc\nd";
        s.SetText(t.data(), t.size());
        check("CR, CRLF and LF all end lines",
              s.LineFromPosition(2) == 1 && s.LineFromPosition(5) == 2 && s.LineFromPosition(7) == 3
              && s.LineEnd(1) == 3 && s.LineStart(2) == 5);
    }

    // ---- Concurrency: searches on several threads at once ---------------------
    // Find in Files runs on a background queue while the editor searches on
    // the main thread. Each thread compiles its own (different, case-folded)
    // regexes, which goes through Boost's shared traits cache, and runs
    // Normal-mode case-insensitive searches through Scintilla's case tables.
    // Build with -DNPP_TEST_SANITIZER=thread to have TSan check this.
    {
        NppSearch::PrepareForBackgroundUse();
        std::string text;
        for (int i = 0; i < 200; i++) text += "Alpha beta GAMMA delta \xC3\x89t\xC3\xA9 caf\xC3\xA9\n";
        std::atomic<int> bad{0};
        std::vector<std::thread> threads;
        for (int t = 0; t < 8; t++) {
            threads.emplace_back([&, t] {
                for (int round = 0; round < 20; round++) {
                    const std::string reps = "{" + std::to_string(1 + round % 3) + ",}";
                    const std::string pattern = t % 2 ? "\\b[[:alpha:]]" + reps + "a\\b"
                                                      : "(?<=\\s)\\w" + reps;
                    BufferSearch s;
                    s.SetSearch(pattern, kRegex, "<$0>", true);
                    s.SetText(text.data(), text.size());
                    Pos n = NppSearch::ForEachMatch(s, 0, s.Length(), [](Pos, Pos) { return true; });
                    if (n <= 0 || s.LastStatus() != NppSearch::Status::Ok) bad++;
                    BufferSearch plain;
                    plain.SetSearch("\xC3\xA9T\xC3\x89", 0, "x", false);
                    plain.SetText(text.data(), text.size());
                    if (NppSearch::ReplaceAll(plain, 0, plain.Length()) != 200) bad++;
                }
            });
        }
        for (auto &th : threads) th.join();
        check("8 threads searching and replacing at once", bad == 0, "bad=" + std::to_string(bad.load()));
    }

    // ---- Reuse: one BufferSearch for several buffers ----------------------------
    {
        BufferSearch s;
        s.SetSearch("x+", kRegexCase, "", true);
        int total = 0;
        for (const std::string t : {"x xx", "", "y", "xxx\nx"}) {
            s.SetText(t.data(), t.size());
            total += (int)NppSearch::ForEachMatch(s, 0, s.Length(), [](Pos, Pos) { return true; });
        }
        check("one BufferSearch over several buffers", total == 4, std::to_string(total));
    }

    printf("\n%s (%d failure%s)\n", g_fail ? "FAILURES" : "ALL PASS", g_fail, g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
