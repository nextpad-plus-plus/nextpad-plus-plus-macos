#!/bin/bash
# Build and run the editor regex harness (regex/test/test_npp_regex.cxx)
# against the real Scintilla core and the Boost backend. No CMake needed — we
# compile only the platform-agnostic Scintilla sources that Document depends
# on, plus the SCI_OWNREGEX backend, and stub out the Platform debug hooks in
# the test TU. The same harness also runs under ctest (see CMakeLists.txt).
#
# Usage:  bash regex/test/run.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
sci="$root/scintilla"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Scintilla core sources required to instantiate and edit a Document.
core=(Document CellBuffer CharClassify CharacterCategoryMap CharacterType \
      Decoration PerLine RunStyles UniConversion UniqueString CaseFolder \
      CaseConvert DBCS RESearch ChangeHistory UndoHistory Geometry)
srcs=()
for s in "${core[@]}"; do srcs+=("$sci/src/$s.cxx"); done

# BoostRegExSearch.cxx provides CreateRegexSearch() (SCI_OWNREGEX), the engine
# every editor Document uses.
clang++ -std=c++17 -stdlib=libc++ \
    -DSCI_NAMESPACE -DSCI_OWNREGEX -DSCINTILLA_QT=0 -DBOOST_REGEX_STANDALONE -DBOOST_HAS_THREADS= \
    -I"$sci/include" -I"$sci/src" -I"$root/regex" \
    "$here/test_npp_regex.cxx" \
    "$root/regex/BoostRegExSearch.cxx" "$root/regex/UTF8DocumentIterator.cxx" \
    "${srcs[@]}" \
    -o "$out/test_npp_regex"

"$out/test_npp_regex"
