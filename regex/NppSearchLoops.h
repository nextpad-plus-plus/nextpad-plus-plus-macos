// SPDX-License-Identifier: MIT
//
// The Find All / Count / Mark All and Replace All loops, written once and used
// by both the editor (SearchEngine.mm drives a ScintillaView) and Find/Replace
// in Files (NppBufferSearch drives a headless Scintilla Document). Both sides
// pass the same SCFIND_* flags to the same Boost backend, so a pattern finds
// and replaces the same text whether the file is open in a tab or not.
//
// Plain C++17, no Scintilla or Cocoa types, so ObjC++ and C++ can include it.

#ifndef NPP_SEARCH_LOOPS_H
#define NPP_SEARCH_LOOPS_H

#include <cstdint>
#include <functional>

namespace NppSearch {

using Pos = std::intptr_t;

/// A text buffer the loops can search and edit.
class Target {
public:
    virtual ~Target() = default;
    /// Search for the needle in [start, end). Returns the match start and sets
    /// *matchEnd, or returns a negative value when nothing matched (or the
    /// pattern is invalid).
    virtual Pos Find(Pos start, Pos end, Pos *matchEnd) = 0;
    /// Replace [start, end), the match Find just returned, with the replacement
    /// text (expanded against that match in regex mode). Returns the number of
    /// bytes inserted.
    virtual Pos Replace(Pos start, Pos end) = 0;
};

// Both loops follow Windows Notepad++ (FindReplaceDlg::processRange): the next
// search starts right at the end of the previous match (or of its
// replacement), and the loop ends after a match that reaches the end of the
// range. An empty match does not repeat at the same place because the regex
// flags carry SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH: the backend rejects an
// empty match where the previous match ended and steps one character on
// (a CRLF counts as one with SCFIND_REGEXP_SKIPCRLFASONE). So `$` -> ";" puts
// one ";" on every line, the last empty one included, and `x*` finds the three
// empty matches in "ab". If a backend ever returned the same empty match
// twice, the loops stop instead of spinning.

/// Visit every match in [start, end) from left to right, the way Find All,
/// Count and Mark All walk a document. onMatch(matchStart, matchEnd) returns
/// false to stop early. Returns the number of matches visited.
template <typename OnMatch>
inline Pos ForEachMatch(Target &target, Pos start, Pos end, OnMatch &&onMatch) {
    Pos count = 0;
    Pos pos = start;
    Pos lastEmpty = -1;
    for (;;) {
        Pos matchEnd = 0;
        const Pos found = target.Find(pos, end, &matchEnd);
        if (found < 0 || matchEnd > end) break;
        if (found == matchEnd) {
            if (found == lastEmpty) break;
            lastEmpty = found;
        } else {
            lastEmpty = -1;
        }
        count++;
        if (!onMatch(found, matchEnd)) break;
        if (matchEnd == end) break;
        pos = matchEnd;
    }
    return count;
}

/// Replace every match in [start, end). shouldStop (optional) is polled
/// between replacements; returning true ends the loop early. Returns the
/// number of replacements made.
inline Pos ReplaceAll(Target &target, Pos start, Pos end,
                      const std::function<bool()> &shouldStop = nullptr) {
    Pos count = 0;
    Pos pos = start;
    Pos lastEmpty = -1;
    for (;;) {
        if (shouldStop && (count & 0xFF) == 0xFF && shouldStop()) break;
        Pos matchEnd = 0;
        const Pos found = target.Find(pos, end, &matchEnd);
        if (found < 0 || matchEnd > end) break;
        if (found == matchEnd) {
            if (found == lastEmpty) break;
            lastEmpty = found;
        } else {
            lastEmpty = -1;
        }
        const Pos inserted = target.Replace(found, matchEnd);
        count++;
        if (matchEnd == end) break;
        const Pos delta = inserted - (matchEnd - found);
        end += delta;
        pos = found + inserted;
    }
    return count;
}

} // namespace NppSearch

#endif // NPP_SEARCH_LOOPS_H
