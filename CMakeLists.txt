cmake_minimum_required(VERSION 3.20)
project(NotepadPlusPlusMac OBJCXX CXX C)

if(APPLE)
    set(CMAKE_AR /usr/bin/ar)
    set(CMAKE_RANLIB /usr/bin/ranlib)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

# Vendored Scintilla + Lexilla (copied from notepad-plus-plus upstream).
# RTL patches are applied in place; update by re-copying from upstream when needed.
set(SCI_ROOT "${CMAKE_SOURCE_DIR}/scintilla")
set(LEX_ROOT "${CMAKE_SOURCE_DIR}/lexilla")

# -----------------------------------------------------------------------------
# Scintilla core (platform-agnostic)
# -----------------------------------------------------------------------------
file(GLOB SCI_CORE_SRCS "${SCI_ROOT}/src/*.cxx")

set(SCI_COCOA_SRCS
    "${SCI_ROOT}/cocoa/PlatCocoa.mm"
    "${SCI_ROOT}/cocoa/ScintillaCocoa.mm"
    "${SCI_ROOT}/cocoa/ScintillaView.mm"
    "${SCI_ROOT}/cocoa/InfoBar.mm"
)

# regex/  is this repo's SCI_OWNREGEX implementation — see regex/NppRegexSearch.cxx.
# Mirrors Notepad++ Windows's `boostregex/` sibling-directory pattern. We compile
# BOTH backends and a small selector picks one at runtime (RegexBackendSelect.cxx):
#   * NppRegexSearch.cxx   — per-line std::regex (default, "Use Boost Regex" off)
#   * BoostRegExSearch.cxx — whole-buffer Boost.Regex (opt-in, Windows parity:
#                            multi-line, lookbehind, \K). Header-only Boost subset
#                            vendored under regex/boost/ (BOOST_REGEX_STANDALONE).
# With SCI_OWNREGEX defined, Scintilla's built-in CreateRegexSearch() compiles out
# and the linker picks up the selector's one.
set(NPP_REGEX_ROOT "${CMAKE_SOURCE_DIR}/regex")
set(NPP_REGEX_SRCS
    "${NPP_REGEX_ROOT}/NppRegexSearch.cxx"
    "${NPP_REGEX_ROOT}/BoostRegExSearch.cxx"
    "${NPP_REGEX_ROOT}/UTF8DocumentIterator.cxx"
    "${NPP_REGEX_ROOT}/RegexBackendSelect.cxx"
)

add_library(scintilla STATIC ${SCI_CORE_SRCS} ${SCI_COCOA_SRCS} ${NPP_REGEX_SRCS})

target_include_directories(scintilla PUBLIC
    "${SCI_ROOT}/include"
    "${SCI_ROOT}/src"
    "${SCI_ROOT}/cocoa"
)
target_include_directories(scintilla PRIVATE
    # contains boost/ — boost headers self-include as <boost/...>, so the root
    # (not boost/ itself) goes on the include path
    "${NPP_REGEX_ROOT}"
)

target_compile_definitions(scintilla PRIVATE
    SCI_NAMESPACE
    SCI_OWNREGEX
    SCINTILLA_QT=0
    BOOST_REGEX_STANDALONE
)

set_source_files_properties(${SCI_COCOA_SRCS} PROPERTIES
    COMPILE_FLAGS "-fobjc-arc"
)

# -----------------------------------------------------------------------------
# Lexilla (syntax highlighting)
# -----------------------------------------------------------------------------
file(GLOB LEX_SRCS
    "${LEX_ROOT}/src/*.cxx"
    "${LEX_ROOT}/lexers/*.cxx"
    "${LEX_ROOT}/lexlib/*.cxx"
)
# LexUser.cxx: use the macOS-compatible copy (windows.h replaced with standard headers)
list(FILTER LEX_SRCS EXCLUDE REGEX "LexUser\\.cxx$")
list(APPEND LEX_SRCS "${CMAKE_SOURCE_DIR}/src/LexUser.cxx")

add_library(lexilla STATIC ${LEX_SRCS})

target_include_directories(lexilla PUBLIC
    "${LEX_ROOT}/include"
    "${LEX_ROOT}/src"
    "${LEX_ROOT}/lexlib"
    "${LEX_ROOT}/access"
    "${SCI_ROOT}/include"
    "${SCI_ROOT}/src"
    "${CMAKE_SOURCE_DIR}/src"
)

# -----------------------------------------------------------------------------
# Application
# -----------------------------------------------------------------------------
set(APP_SRCS
    src/main.mm
    src/NppApplication.mm
    src/NppThemeManager.mm
    src/NppCommandLineParams.mm
    src/NppPaths.mm
    src/ShortcutMapperWindowController.mm
    src/NppLocalizer.mm
    src/NppLangsManager.mm
    src/AppDelegate.mm
    src/MainWindowController.mm
    src/TahoeToolbarConfig.mm
    src/EditorView.mm
    src/TabManager.mm
    src/NppTabBar.mm
    src/MenuBuilder.mm
    src/FindReplacePanel.mm
    src/ColumnEditorPanel.mm
    src/PreferencesWindowController.mm
    # src/FindInFilesPanel.mm — removed, search goes through FindWindow
    src/SidePanelHost.mm
    src/PanelFrame.mm
    src/FloatingPanelWindow.mm
    src/DocumentListPanel.mm
    src/ClipboardHistoryPanel.mm
    src/FunctionListPanel.mm
    src/DocumentMapPanel.mm
    src/ProjectPanel.mm
    src/SearchEngine.mm
    src/NPPBatchRunner.mm
    src/NPPBatchDialog.mm
    src/SearchResultsPanel.mm
    src/FindWindow.mm
    src/StyleConfiguratorWindowController.mm
    src/IncrementalSearchBar.mm
    src/CommandPalettePanel.mm
    src/GitHelper.mm
    src/GitPanel.mm
    src/FolderTreePanel.mm
    src/CharacterPanel.mm
    src/UserDefineLangManager.mm
    src/UserDefineDialog.mm
    src/UDLStylerDialog.mm
    src/NppPluginManager.mm
    src/PluginsAdminWindowController.mm
    src/NppBuiltinLanguages.mm
)

set(APP_HEADERS
    src/NppPaths.h
    src/NppLocalizer.h
    src/NppLangsManager.h
    src/AppDelegate.h
    src/MainWindowController.h
    src/EditorView.h
    src/TabManager.h
    src/NppTabBar.h
    src/MenuBuilder.h
    src/FindReplacePanel.h
    src/ColumnEditorPanel.h
    src/PreferencesWindowController.h
    # src/FindInFilesPanel.h — removed
    src/SidePanelHost.h
    src/PanelFrame.h
    src/FloatingPanelWindow.h
    src/DocumentListPanel.h
    src/ClipboardHistoryPanel.h
    src/FunctionListPanel.h
    src/DocumentMapPanel.h
    src/ProjectPanel.h
    src/SearchEngine.h
    src/SearchResultsPanel.h
    src/FindWindow.h
    src/StyleConfiguratorWindowController.h
    src/IncrementalSearchBar.h
    src/CommandPalettePanel.h
    src/GitHelper.h
    src/GitPanel.h
    src/FolderTreePanel.h
    src/CharacterPanel.h
    src/UserDefineLangManager.h
    src/UserDefineDialog.h
    src/UDLStylerDialog.h
    src/NppPluginManager.h
    src/NppPluginInterfaceMac.h
    src/NppScintillaIDs.h
    src/PluginsAdminWindowController.h
    src/NppBuiltinLanguages.h
)

add_executable(NotepadPlusPlusMac MACOSX_BUNDLE ${APP_SRCS} ${APP_HEADERS})

# Copy icons at BUILD time so updated PNGs are picked up on every make.
# IMPORTANT: rsync -a (not `cmake -E copy_directory`) — copy_directory does NOT
# overwrite existing files in the destination, so a refreshed PNG sitting next
# to a stale copy in the bundle was silently skipped on incremental builds.
# rsync -a archive-mirrors the source tree, overwriting any older bundle copy.
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND /usr/bin/rsync -a
        "${CMAKE_SOURCE_DIR}/resources/icons/"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/icons/"
    COMMENT "Syncing icons into app bundle")

add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    # Force-copy so an updated icns is always written (copy_if_different can miss timestamp ties)
    COMMAND ${CMAKE_COMMAND} -E copy
        "${CMAKE_SOURCE_DIR}/resources/npp.icns"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/npp.icns"
    # Touch the bundle so macOS knows the icon changed, then re-register with LaunchServices
    COMMAND touch "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>"
    COMMAND /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
            -f "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>"
    COMMENT "Copying app icon and refreshing macOS icon cache")

add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/stylers.model.xml"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/stylers.model.xml"
    COMMENT "Copying stylers.model.xml into bundle")

# DMG installer background: bundled inside the app so the release DMG can
# point Finder at Nextpad++.app:Contents:Resources:dmg-background.tiff
# without needing a visible .background/ folder in the DMG root.
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/dmg-background.tiff"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/dmg-background.tiff"
    COMMENT "Copying DMG installer background into bundle")

add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/langs.model.xml"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/langs.model.xml"
    COMMENT "Copying langs.model.xml into bundle")

add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND /usr/bin/rsync -a
        "${CMAKE_SOURCE_DIR}/resources/themes/"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/themes/"
    COMMENT "Copying theme XML files into bundle")

# Bundle localization XML files (Windows NPP format, unmodified).
# These live in resources/localization/ inside this repo.
# Users can also drop additional XML files into
#   ~/Library/Application Support/Nextpad++/localization/
# to add languages without touching the app bundle.
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND /usr/bin/rsync -a
        "${CMAKE_SOURCE_DIR}/resources/localization/"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/localization/"
    COMMENT "Copying localization XML files into bundle")

# Function List parser definitions (XML, same format as Windows NPP)
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND /usr/bin/rsync -a
        "${CMAKE_SOURCE_DIR}/resources/functionList/"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/functionList/"
    COMMENT "Copying function list parser XMLs into bundle")

# Pre-installed User Defined Language files
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND /usr/bin/rsync -a
        "${CMAKE_SOURCE_DIR}/resources/userDefineLangs/"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/userDefineLangs/"
    COMMENT "Copying pre-installed UDL files into bundle")

# Default shortcuts.xml (copied to ~/Library/Application Support/Nextpad++/ on first run if missing)
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/shortcuts.xml"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/shortcuts.xml"
    COMMENT "Copying default shortcuts.xml into bundle")

# Default tabContextMenu.xml (copied to ~/Library/Application Support/Nextpad++/ on first run)
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/tabContextMenu.xml"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/tabContextMenu.xml"
    COMMENT "Copying default tabContextMenu.xml into bundle")

# Default contextMenu.xml (copied to ~/Library/Application Support/Nextpad++/ on first run)
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/contextMenu.xml"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/contextMenu.xml"
    COMMENT "Copying default contextMenu.xml into bundle")

# Default toolbarButtonsConf.xml (copied as _example to ~/Library/Application Support/Nextpad++/ on first run)
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/resources/toolbarButtonsConf.xml"
        "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/toolbarButtonsConf.xml"
    COMMENT "Copying default toolbarButtonsConf.xml into bundle")

# Localized display name + per-language stubs (issue #35).
# We ship resources/localization/<name>.xml for ~135 NPP-style translations,
# but macOS only registers a localization if a corresponding
# <bcp47>.lproj/InfoPlist.strings exists in the bundle. Without those:
#   • [NSBundle preferredLocalizations] returns only ["en"], so VoiceOver
#     pronounces every UI element with an English voice regardless of the
#     active NppLocalizer language.
#   • The system-supplied App menu items (About / Hide / Quit / Services /
#     Window) stay English even when the rest of the UI is translated.
# Fix: at configure time, generate stub <bcp47>.lproj/InfoPlist.strings files
# (using the same template as resources/en.lproj/InfoPlist.strings) under
# resources/lproj/. At build time, copy each into the bundle.
# The list maps every NppLocalizer language file we ship to a BCP-47 code.
# Skipped: english_customizable (variant of English) and piglatin (joke).
set(NPP_BUNDLE_LANGUAGES
    ab          # abkhazian
    af          # afrikaans
    sq          # albanian
    am          # amharic
    ar          # arabic
    an          # aragonese
    oc-aranes   # aranese
    hy          # armenian
    as          # assamese
    ay          # aymara
    az          # azerbaijani
    bm          # bambara
    eu          # basque
    be          # belarusian
    bn          # bengali
    bho         # bhojpuri
    bs          # bosnian
    pt-BR       # brazilian_portuguese
    br          # breton
    bg          # bulgarian
    ca          # catalan
    ceb         # cebuano
    ny          # chichewa
    zh-Hans     # chineseSimplified
    co          # corsican
    hr          # croatian
    cs          # czech
    da          # danish
    dv          # dhivehi
    doi         # dogri
    nl          # dutch
    en          # english
    eo          # esperanto
    et          # estonian
    ee          # ewe
    ext         # extremaduran
    fa          # farsi
    fi          # finnish
    fr          # french
    fur         # friulian
    gl          # galician
    ka          # georgian
    de          # german
    el          # greek
    gn          # guarani
    gu          # gujarati
    ha          # hausa
    haw         # hawaiian
    he          # hebrew
    hi          # hindi
    hmn         # hmong
    yue         # hongKongCantonese
    hu          # hungarian
    ig          # igbo
    ilo         # ilocano
    id          # indonesian
    ga          # irish
    it          # italian
    ja          # japanese
    jv          # javanese
    kab         # kabyle
    kn          # kannada
    kk          # kazakh
    rw          # kinyarwanda
    kok         # konkani
    ko          # korean
    kri         # krio
    ku          # kurdish
    ky          # kyrgyz
    lo          # lao
    lv          # latvian
    lij         # ligurian
    ln          # lingala
    lt          # lithuanian
    lb          # luxembourgish
    mk          # macedonian
    mai         # maithili
    mg          # malagasy
    ms          # malay
    ml          # malayalam
    mr          # marathi
    lus         # mizo
    mn          # mongolian
    my          # myanmar
    ne          # nepali
    nb          # norwegian (Bokmål)
    nn          # nynorsk
    oc          # occitan
    or          # odia
    ps          # pashto
    pl          # polish
    pt-PT       # portuguese
    pa          # punjabi
    qu          # quechua
    ro          # romanian
    ru          # russian
    sgs         # samogitian
    sc          # sardinian
    nso         # sepedi
    sr-Latn     # serbian
    sr-Cyrl     # serbianCyrillic
    st          # sesotho
    sn          # shona
    si          # sinhala
    sk          # slovak
    sl          # slovenian
    so          # somali
    es          # spanish
    es-AR       # spanish_ar
    su          # sundanese
    sw          # swahili
    sv          # swedish
    tl          # tagalog
    zh-Hant     # taiwaneseMandarin
    tg-Cyrl     # tajikCyrillic
    ta          # tamil
    tt          # tatar
    te          # telugu
    th          # thai
    ti          # tigrinya
    ts          # tsonga
    tr          # turkish
    tk          # turkmen
    tw          # twi
    uk          # ukrainian
    ur          # urdu
    ug          # uyghur
    uz-Latn     # uzbek
    uz-Cyrl     # uzbekCyrillic
    vec         # venetian
    vi          # vietnamese
    cy          # welsh
    xh          # xhosa
    yo          # yoruba
    zu          # zulu
)

# Materialise each lproj directly into the bundle at build time, using the
# existing resources/en.lproj/InfoPlist.strings as the single source of truth.
# No intermediate source-tree mirror — the only checked-in file is the
# template (which we already had).
foreach(_lang IN LISTS NPP_BUNDLE_LANGUAGES)
    add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/${_lang}.lproj"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_SOURCE_DIR}/resources/en.lproj/InfoPlist.strings"
            "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>/Contents/Resources/${_lang}.lproj/InfoPlist.strings")
endforeach()

# Ad-hoc code signing — gives the app a stable identity so macOS can
# remember TCC permission grants (Downloads, Desktop, Documents) across launches.
# Strip extended attributes first (resource forks / Finder info break codesign).
add_custom_command(TARGET NotepadPlusPlusMac POST_BUILD
    COMMAND xattr -cr "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>"
    COMMAND codesign --force --deep --sign - "$<TARGET_BUNDLE_DIR:NotepadPlusPlusMac>"
    COMMENT "Ad-hoc code signing the app bundle")

set_target_properties(NotepadPlusPlusMac PROPERTIES
    OUTPUT_NAME "Nextpad++"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/resources/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "Nextpad++"
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.nextpadplusplus.mac"
    MACOSX_BUNDLE_BUNDLE_VERSION "1.0.8"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.8"
)

target_include_directories(NotepadPlusPlusMac PRIVATE
    src
    "${SCI_ROOT}/include"
    "${SCI_ROOT}/cocoa"
    "${LEX_ROOT}/include"
)

target_link_libraries(NotepadPlusPlusMac PRIVATE
    scintilla
    lexilla
    "-framework Cocoa"
    "-framework QuartzCore"
    "-framework UniformTypeIdentifiers"
)

set_source_files_properties(${APP_SRCS} PROPERTIES
    COMPILE_FLAGS "-fobjc-arc"
)
