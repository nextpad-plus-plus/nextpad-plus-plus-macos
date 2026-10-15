#pragma once

// C++ / Objective-C++ only (uses constexpr and static_assert).

// Scintilla marker and indicator numbers used by the host, plus the ranges
// handed out to plugins via NPPM_ALLOCATEMARKER / NPPM_ALLOCATEINDICATOR.
// Keep every host-owned number here so the plugin ranges can be checked
// against them at compile time (see the static_asserts at the bottom).
//
// The layout mirrors Windows Notepad++ (resource.h, SciLexer.h
// SCE_UNIVERSAL_*, ScintillaEditView.h MARK_*), so plugins ported from
// Windows that hard-code Windows numbers land in the same places here.
//
// Marker map (0-31, Scintilla MARKER_MAX = 31):
//    0         unused
//    1-14      plugins (NPPM_ALLOCATEMARKER), same as Windows MARKER_PLUGINS
//   15-17      git gutter: added / modified / deleted (macOS only)
//   18-19      hide-lines end / begin arrows (Windows MARK_HIDELINES*)
//   20         bookmark (Windows MARK_BOOKMARK, NPPM_GETBOOKMARKID)
//   21-24      Scintilla change history (SC_MARKNUM_HISTORY_*)
//   25-31      Scintilla fold markers (SC_MARKNUM_FOLDER*)
//
// A plugin whose NPPM_ALLOCATEMARKER request fails and then falls back to
// raw markers 0-15 (ComparePlus does this when asking for 16) overlaps
// git-added (15), but only while the git gutter is active.
//
// Indicator map (0-43, Scintilla INDICATOR_MAX = 43):
//    0-7       reserved for lexers (INDICATOR_CONTAINER = 8)
//    8         clickable links (Windows URL_INDIC)
//    9-20      plugins (NPPM_ALLOCATEINDICATOR), same as Windows
//   21-25      mark styles 5-1 (Windows SCE_UNIVERSAL_FOUND_STYLE_EXT5..EXT1)
//   26         git diff line highlight (Windows: tag attribute)
//   27         unused (Windows: tag match)
//   28         incremental search (Windows SCE_UNIVERSAL_FOUND_STYLE_INC)
//   29         smart highlight (Windows SCE_UNIVERSAL_FOUND_STYLE_SMART)
//   30         spell check (unused on Windows)
//   31         Find "Mark" results (Windows SCE_UNIVERSAL_FOUND_STYLE)
//   32-43      Scintilla IME and change history (INDICATOR_IME..INDICATOR_MAX)
//
// Plugins must not assume fixed numbers; they get theirs from the allocator.

// ── Host markers ──────────────────────────────────────────────────────────
static const int kGitMarkerAdded        = 15;
static const int kGitMarkerModified     = 16;
static const int kGitMarkerDeleted      = 17;
static const int kHideLinesEndMarker    = 18; // green ◀ arrow on line AFTER hidden range
static const int kHideLinesBeginMarker  = 19; // green ▶ arrow on line BEFORE hidden range
static const int kBookmarkMarker        = 20;

// ── Host indicators ───────────────────────────────────────────────────────
static const int kClickableLinkIndicator = 8;
static const int kMarkIndicatorCount     = 5;
static constexpr int kMarkStyleIndicators[kMarkIndicatorCount] = { 25, 24, 23, 22, 21 }; // styles 1-5
static const int kGitDiffIndicator       = 26;
static const int kIndicatorIncSearch     = 28;
static const int kHighlightIndicator     = 29; // smart highlight
static const int kSpellIndicator         = 30;
static const int kFindMarkIndicator      = 31;

// ── Plugin ranges: [first, limit) ─────────────────────────────────────────
static const int kPluginMarkerFirst     =  1;
static const int kPluginMarkerLimit     = 15;
static const int kPluginIndicatorFirst  =  9;
static const int kPluginIndicatorLimit  = 21;

// Plugin command IDs. FuncItem _cmdIDs are assigned from the first range at
// load time (Windows ID_PLUGINS_CMD..ID_PLUGINS_CMD_LIMIT, 22000-22999).
// Windows defines that limit but does not enforce it; here it is enforced so
// FuncItem IDs can never reach the second range. NPPM_ALLOCATECMDID hands
// out the second range, which matches Windows _dynamicIDAlloc
// (ID_PLUGINS_CMD_DYNAMIC, ID_PLUGINS_CMD_DYNAMIC_LIMIT), i.e. 23000-24998.
static const int kPluginCmdIDFirst        = 22000;
static const int kPluginCmdIDLimit        = 23000;
static const int kPluginDynamicCmdIDFirst = 23000;
static const int kPluginDynamicCmdIDLimit = 24999;

namespace NppScintillaIDsDetail {
constexpr bool outside(int id, int first, int limit) { return id < first || id >= limit; }
}
static_assert(NppScintillaIDsDetail::outside(kGitMarkerAdded,       kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kGitMarkerModified,    kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kGitMarkerDeleted,     kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kHideLinesEndMarker,   kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kHideLinesBeginMarker, kPluginMarkerFirst, kPluginMarkerLimit) &&
              NppScintillaIDsDetail::outside(kBookmarkMarker,       kPluginMarkerFirst, kPluginMarkerLimit),
              "host marker inside the plugin marker range");
static_assert(kPluginMarkerLimit <= 21, "plugin markers overlap Scintilla change-history markers (21-24)");
static_assert(NppScintillaIDsDetail::outside(kClickableLinkIndicator, kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kMarkStyleIndicators[0], kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kMarkStyleIndicators[1], kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kMarkStyleIndicators[2], kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kMarkStyleIndicators[3], kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kMarkStyleIndicators[4], kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kGitDiffIndicator,       kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kIndicatorIncSearch,     kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kHighlightIndicator,     kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kSpellIndicator,         kPluginIndicatorFirst, kPluginIndicatorLimit) &&
              NppScintillaIDsDetail::outside(kFindMarkIndicator,      kPluginIndicatorFirst, kPluginIndicatorLimit),
              "host indicator inside the plugin indicator range");
static_assert(kPluginIndicatorFirst >= 8 && kPluginIndicatorLimit <= 32,
              "plugin indicators overlap lexer (0-7) or IME/history (32+) indicators");
static_assert(kPluginCmdIDLimit <= kPluginDynamicCmdIDFirst, "plugin cmdID ranges overlap");
static_assert(kBookmarkMarker < 21 && kHideLinesBeginMarker < 21 && kGitMarkerDeleted < 21,
              "host markers overlap Scintilla change-history (21-24) or fold (25-31) markers");
static_assert(kFindMarkIndicator < 32 && kSpellIndicator < 32 && kHighlightIndicator < 32 &&
              kIndicatorIncSearch < 32 && kGitDiffIndicator < 32 && kClickableLinkIndicator >= 8,
              "host indicators overlap lexer (0-7) or IME/history (32+) indicators");
