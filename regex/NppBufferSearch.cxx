// SPDX-License-Identifier: MIT
//
// NppBufferSearch: the editor's search engine over a headless Scintilla
// Document. See NppBufferSearch.h.

// Document.h uses std::map/optional/etc. without including them.
#include <cstddef>
#include <cstdint>
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
#include "CaseConvert.h"
#include "Decoration.h"
#include "Document.h"
#include "BoostRegexSearch.h"

#include "NppBufferSearch.h"

using namespace Scintilla;
using namespace Scintilla::Internal;

namespace NppSearch {

namespace {
constexpr int kCodePageUTF8 = 65001;   // SC_CP_UTF8, as ScintillaCocoa sets for every editor
}

struct BufferSearch::Impl {
    // No style bytes: nothing is ever lexed here.
    Document doc{DocumentOption::StylesNone};
};

BufferSearch::BufferSearch(const char *wordChars) : impl(std::make_unique<Impl>()) {
    Document &doc = impl->doc;
    doc.SetDBCSCodePage(kCodePageUTF8);
    doc.SetUndoCollection(false);
    // The editor's case folder for UTF-8 (ScintillaCocoa::CaseFolderForEncoding).
    doc.SetCaseFolder(std::make_unique<CaseFolderUnicode>());
    if (wordChars) {
        // Same as SCI_SETWORDCHARS.
        doc.SetDefaultCharClasses(false);
        doc.SetCharClasses(reinterpret_cast<const unsigned char *>(wordChars), CharacterClass::word);
    }
}

BufferSearch::~BufferSearch() = default;

void BufferSearch::SetText(const char *utf8, size_t length) {
    Document &doc = impl->doc;
    if (doc.Length() > 0)
        doc.DeleteChars(0, doc.Length());
    if (length > 0)
        doc.InsertString(0, utf8, static_cast<Sci::Position>(length));
    status = Status::Ok;
    errorMessage.clear();
}

std::string BufferSearch::Text() const {
    const Document &doc = impl->doc;
    std::string text(static_cast<size_t>(doc.Length()), '\0');
    if (!text.empty())
        doc.GetCharRange(text.data(), 0, doc.Length());
    return text;
}

Pos BufferSearch::Length() const {
    return impl->doc.Length();
}

Pos BufferSearch::LineFromPosition(Pos pos) const {
    return impl->doc.SciLineFromPosition(pos);
}

Pos BufferSearch::LineStart(Pos line) const {
    return impl->doc.LineStart(line);
}

Pos BufferSearch::LineEnd(Pos line) const {
    return impl->doc.LineEnd(line);
}

void BufferSearch::SetSearch(const std::string &needle_, int searchFlags_,
                             const std::string &replacement_, bool regexReplace_) {
    needle = needle_;
    searchFlags = searchFlags_;
    replacement = replacement_;
    regexReplace = regexReplace_;
    status = Status::Ok;
    errorMessage.clear();
}

Pos BufferSearch::Find(Pos start, Pos end, Pos *matchEnd) {
    if (needle.empty() || status != Status::Ok)
        return -1;
    // As Editor::SearchInTarget: *length is the needle length on input and the
    // match length on output.
    Sci::Position length = static_cast<Sci::Position>(needle.size());
    const Sci::Position found = impl->doc.FindText(start, end, needle.c_str(),
                                                   static_cast<FindOption>(searchFlags), &length);
    if (found >= 0) {
        *matchEnd = found + length;
        return found;
    }
    // The Boost backend reports -2 for a regex_error (bad pattern, or Boost's
    // complexity limit while matching) and -3 for any other failure.
    if (found == -2 || found == -3) {
        status = (found == -2) ? Status::InvalidRegex : Status::RegexFailed;
        errorMessage = g_exceptionMessage;
    }
    return -1;
}

Pos BufferSearch::Replace(Pos start, Pos end) {
    // As Editor::ReplaceTarget (SCI_REPLACETARGET / SCI_REPLACETARGETRE).
    Document &doc = impl->doc;
    std::string text;
    if (regexReplace) {
        Sci::Position length = static_cast<Sci::Position>(replacement.size());
        const char *substituted = doc.SubstituteByPosition(replacement.c_str(), &length);
        if (!substituted)
            return 0;
        text.assign(substituted, static_cast<size_t>(length));
    } else {
        text = replacement;
    }
    if (end > start)
        doc.DeleteChars(start, end - start);
    return doc.InsertString(start, text.data(), static_cast<Sci::Position>(text.size()));
}

void PrepareForBackgroundUse() {
    ConverterFor(CaseConversion::fold);
    ConverterFor(CaseConversion::upper);
    ConverterFor(CaseConversion::lower);
}

} // namespace NppSearch
