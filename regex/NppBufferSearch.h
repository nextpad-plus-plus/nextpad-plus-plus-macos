// SPDX-License-Identifier: MIT
//
// Search and replace over a UTF-8 buffer with exactly the editor's engine.
//
// Find/Replace in Files and Find in Projects load each file into a headless
// Scintilla Document (no view, no styles, no undo) and run the same
// Document::FindText + Boost.Regex backend + SubstituteByPosition the editor
// uses, through the shared loops in NppSearchLoops.h. Windows Notepad++ does
// the same with a hidden Scintilla buffer. So Normal, Extended and Regular
// expression modes, match case, whole word, ". matches newline", multi-line
// matches, lookbehind, \K, empty-match rules and the replacement format all
// behave identically in a tab and in Find in Files.
//
// The public interface has no Scintilla types, so ObjC++ code can use it
// without the Scintilla internal headers.

#ifndef NPP_BUFFER_SEARCH_H
#define NPP_BUFFER_SEARCH_H

#include <cstddef>
#include <memory>
#include <string>

#include "NppSearchLoops.h"

namespace NppSearch {

enum class Status {
    Ok = 0,
    // The backend threw a regex_error: the pattern did not compile, or (as on
    // Windows, where both show "Invalid regular expression") matching hit
    // Boost's complexity limit (catastrophic backtracking).
    InvalidRegex,
    RegexFailed,    // any other failure while matching (e.g. out of memory)
};

class BufferSearch final : public Target {
public:
    /// wordChars: the bytes that count as word characters for whole-word
    /// matching (SCI_SETWORDCHARS); nullptr keeps Scintilla's default set.
    explicit BufferSearch(const char *wordChars = nullptr);
    ~BufferSearch() override;
    BufferSearch(const BufferSearch &) = delete;
    BufferSearch &operator=(const BufferSearch &) = delete;

    /// Replace the buffer contents. The Document (and its compiled regex) is
    /// reused, so one BufferSearch can serve a whole Find in Files run.
    void SetText(const char *utf8, size_t length);
    std::string Text() const;
    Pos Length() const;

    /// Line helpers with the Document's line rules (CR, LF and CRLF all end a
    /// line). Lines are 0-based; LineEnd is the position before the EOL.
    Pos LineFromPosition(Pos pos) const;
    Pos LineStart(Pos line) const;
    Pos LineEnd(Pos line) const;

    /// needle: the search text after Extended expansion (UTF-8).
    /// searchFlags: SCFIND_* flags, built exactly as for the editor
    /// (+[SearchEngine loopFlagsForOptions:]).
    /// replacement: the Replace with text; expanded with the regex match
    /// (Boost format_all, as SCI_REPLACETARGETRE does) when regexReplace.
    void SetSearch(const std::string &needle, int searchFlags,
                   const std::string &replacement, bool regexReplace);

    /// Status of the last Find. InvalidRegex/RegexFailed also end the loops
    /// (Find returns -1); ErrorMessage() has Boost's text.
    Status LastStatus() const { return status; }
    const std::string &ErrorMessage() const { return errorMessage; }

    // Target
    Pos Find(Pos start, Pos end, Pos *matchEnd) override;
    Pos Replace(Pos start, Pos end) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
    std::string needle;
    std::string replacement;
    int searchFlags = 0;
    bool regexReplace = false;
    Status status = Status::Ok;
    std::string errorMessage;
};

/// Scintilla's case-conversion tables are built lazily and without locking.
/// Call this once on the main thread before searching on a background queue,
/// so the editor and a background search never build them at the same time.
void PrepareForBackgroundUse();

} // namespace NppSearch

#endif // NPP_BUFFER_SEARCH_H
