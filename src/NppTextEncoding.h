//  NppTextEncoding.h
//  Shared text-file encoding detection.
//
//  The editor (-[EditorView loadFileAtPath:error:]) and Find/Replace in Files
//  must agree on how a file's bytes become text, otherwise a file that opens
//  fine in a tab is silently skipped by Find in Files. These functions hold the
//  detection rules both paths use: BOM sniff (UTF-8, UTF-16 LE/BE), strict UTF-8
//  validation, then +[NSString stringEncodingForData:] (covers the CJK
//  encodings), then Windows-1252, then Latin-1.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decode bytes that are known NOT to be UTF-8: macOS's charset detector first
/// (only trusted when it decoded without lossy substitution), then Windows-1252,
/// then Latin-1. On success *outEncoding is the encoding that actually decoded
/// the bytes. It is the detector's own guess, not the canonical Encoding-menu
/// constant, so re-encoding with it reproduces the original bytes.
FOUNDATION_EXPORT NSString * _Nullable NppDecodeLegacyText(NSData *data,
                                                           NSStringEncoding * _Nullable outEncoding);

/// Decode a whole text file's bytes with the editor's detection rules.
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
