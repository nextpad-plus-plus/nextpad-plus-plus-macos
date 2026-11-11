//  NppTextEncoding.h
//  Shared text-file encoding detection.
//
//  The editor (-[EditorView loadFileAtPath:error:]) and Find/Replace in Files
//  must agree on how a file's bytes become text, otherwise a file that opens
//  fine in a tab is silently skipped by Find in Files. These functions hold the
//  detection rules both paths use: BOM sniff (UTF-8, UTF-16 LE/BE), strict UTF-8
//  validation, then UTF-8 with a few damaged bytes (NppIsDamagedUTF8), then
//  +[NSString stringEncodingForData:] (covers the CJK
//  encodings), then Windows-1252, then Latin-1.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How NppDecodeLegacyText uses macOS's charset detector.
typedef NS_ENUM(NSInteger, NppDetectorMode) {
    /// Run the detector over all of the data (the editor, small files).
    NppDetectorWholeData = 0,
    /// Run the detector over a bounded prefix (64 KB, cut at a line break),
    /// then decode the whole data once with its guess. The detector keeps
    /// temporaries many times the size of its input alive, so Find in Files
    /// must not feed it whole files.
    NppDetectorPrefix,
    /// Skip the detector: Windows-1252, then Latin-1 (large files).
    NppDetectorSkip,
};

/// Size above which a file is "large" (Preferences > Performance): the editor
/// opens it in large-file mode and Find in Files skips the charset detector.
/// NSUIntegerMax when the large-file restriction is disabled. Thread-safe.
FOUNDATION_EXPORT NSUInteger NppLargeFileThreshold(void);

/// YES when the bytes are UTF-8 that contains a few ill-formed sequences (a stray
/// 0xFF, a multibyte character cut in half, one GBK line in a Chinese log) but
/// are otherwise clearly UTF-8: at least one ill-formed sequence, and at least 8
/// well-formed multibyte sequences per ill-formed one. A truncated sequence
/// counts as one ill-formed unit. Strictly valid UTF-8 returns NO (check that
/// first). O(n), no allocation, may stop early.
FOUNDATION_EXPORT BOOL NppIsDamagedUTF8(const uint8_t *bytes, NSUInteger length);

/// Decode UTF-8 that NppIsDamagedUTF8 accepted: every ill-formed unit becomes
/// exactly one U+FFFD. Lossy, so it cannot be written back; callers that must
/// preserve bytes (the editor) pass the raw bytes on instead.
FOUNDATION_EXPORT NSString *NppDecodeDamagedUTF8(NSData *data);

/// Decode bytes that are known NOT to be UTF-8: macOS's charset detector first
/// (trusted when it decoded without lossy substitution, or when it names a
/// multibyte CJK encoding and only a little of the text does not fit it, e.g. a
/// GBK log with a few UTF-8 lines; those bytes become U+FFFD or decode as
/// whatever they spell in that encoding), then Windows-1252, then Latin-1. On success *outEncoding is the encoding that actually decoded
/// the bytes. It is the detector's own guess, not the canonical Encoding-menu
/// constant, so re-encoding with it reproduces the original bytes.
/// acceptDetected (optional) can veto the detector's result, in which case the
/// Windows-1252/Latin-1 fallback is used instead.
FOUNDATION_EXPORT NSString * _Nullable NppDecodeLegacyText(NSData *data,
                                                           NppDetectorMode mode,
                                                           NSStringEncoding * _Nullable outEncoding,
                                                           BOOL (^ _Nullable acceptDetected)(NSString *text));

/// Decode a whole text file's bytes with the editor's detection rules, for
/// Find/Replace in Files. Runs the detector on a prefix only, and not at all
/// above NppLargeFileThreshold().
/// When rejectBinary is YES, data that has no Unicode BOM, is not valid UTF-8,
/// and contains a NUL byte is treated as binary and nil is returned. (Valid
/// UTF-8 containing NULs is still accepted, matching the old UTF-8-only Find in
/// Files behaviour.) *outHasBOM is YES when a UTF-8/UTF-16 BOM was stripped.
FOUNDATION_EXPORT NSString * _Nullable NppDecodeTextData(NSData *data,
                                                         BOOL rejectBinary,
                                                         NSStringEncoding * _Nullable outEncoding,
                                                         BOOL * _Nullable outHasBOM);

/// Encode text for writing back to disk in `encoding`, prefixed with the BOM
/// for that encoding when hasBOM is YES. Returns nil if any character cannot be
/// represented in `encoding` (never substitutes).
FOUNDATION_EXPORT NSData * _Nullable NppEncodeTextData(NSString *text,
                                                       NSStringEncoding encoding,
                                                       BOOL hasBOM);

NS_ASSUME_NONNULL_END
