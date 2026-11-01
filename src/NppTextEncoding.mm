//  NppTextEncoding.mm
//  Shared text-file encoding detection. See NppTextEncoding.h.

#import "NppTextEncoding.h"
#import "PreferencesWindowController.h"

// Detector sample size for NppDetectorPrefix. Large enough for the detector
// to see plenty of non-ASCII text, small enough that its temporaries (many
// times the input size) stay bounded no matter how big the file is.
static const NSUInteger kDetectorPrefixBytes = 64 * 1024;

NSUInteger NppLargeFileThreshold(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kPrefLargeFileEnabled]) return NSUIntegerMax;
    NSInteger mb = [ud integerForKey:kPrefLargeFileSizeMB];
    if (mb < 1)    mb = 1;
    if (mb > 2046) mb = 2046;
    return (NSUInteger)mb * 1024UL * 1024UL;
}

NSString *NppDecodeLegacyText(NSData *data, NppDetectorMode mode,
                              NSStringEncoding *outEncoding,
                              BOOL (^acceptDetected)(NSString *text)) {
    // macOS's heuristic charset detector covers the CJK encodings a plain
    // Win-1252/Latin-1 fallback turns into mojibake (GBK/GB18030, Big5,
    // Shift-JIS, EUC, ...). Only trust a result that decoded *without* lossy
    // substitution; anything else falls through to Win-1252/Latin-1. The
    // detector can also pick another single-byte code page (e.g. Windows-1250,
    // 1251 or 1254) for some Western text; the editor sees the same guess.
    if (mode != NppDetectorSkip) {
        NSData *sample = data;
        BOOL partial = NO;
        if (mode == NppDetectorPrefix && data.length > kDetectorPrefixBytes) {
            // Cut the sample at its last LF. 0x0A is never a trail byte in the
            // multibyte encodings the detector reports (Shift-JIS, GBK/GB18030,
            // Big5, EUC), so the cut can't split a character. A window with no
            // LF is used as is; if that splits a character the detector reports
            // a lossy decode and we fall through to Win-1252/Latin-1.
            const uint8_t *b = (const uint8_t *)data.bytes;
            NSUInteger cut = kDetectorPrefixBytes;
            while (cut > 0 && b[cut - 1] != '\n') cut--;
            if (cut == 0) cut = kDetectorPrefixBytes;
            sample = [data subdataWithRange:NSMakeRange(0, cut)];
            partial = YES;
        }

        NSString *detected = nil;
        BOOL detLossy = NO;
        NSStringEncoding guess = 0;
        @autoreleasepool {
            // Drain the detector's temporaries right away; `detected` is a
            // strong local, so the result itself survives the pool.
            guess = [NSString stringEncodingForData:sample
                                    encodingOptions:nil
                                    convertedString:&detected
                                usedLossyConversion:&detLossy];
        }
        if (detected && guess != 0 && !detLossy && guess != NSUTF8StringEncoding) {
            // Prefix mode: decode the whole data once with the guess. A guess
            // that fails on the rest of the file falls through below.
            NSString *full = partial ? [[NSString alloc] initWithData:data encoding:guess] : detected;
            if (full && (!acceptDetected || acceptDetected(full))) {
                if (outEncoding) *outEncoding = guess;
                return full;
            }
        }
    }

    NSStringEncoding win1252 = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin1);
    NSString *content = [[NSString alloc] initWithData:data encoding:win1252];
    if (content) {
        if (outEncoding) *outEncoding = win1252;
        return content;
    }
    content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (content && outEncoding) *outEncoding = NSISOLatin1StringEncoding;
    return content;
}

NSString *NppDecodeTextData(NSData *data, BOOL rejectBinary,
                            NSStringEncoding *outEncoding, BOOL *outHasBOM) {
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;
    if (outHasBOM) *outHasBOM = NO;

    // BOM detection (matches NPP Utf8_16.cpp k_Boms and EditorView).
    NSStringEncoding bomEnc = 0;
    NSUInteger bomLen = 0;
    if (len >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
        bomEnc = NSUTF8StringEncoding;              bomLen = 3;
    } else if (len >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        bomEnc = NSUTF16LittleEndianStringEncoding; bomLen = 2;
    } else if (len >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        bomEnc = NSUTF16BigEndianStringEncoding;    bomLen = 2;
    }
    if (bomEnc) {
        NSData *body = [data subdataWithRange:NSMakeRange(bomLen, len - bomLen)];
        NSString *s = [[NSString alloc] initWithData:body encoding:bomEnc];
        if (s) {
            if (outEncoding) *outEncoding = bomEnc;
            if (outHasBOM) *outHasBOM = YES;
            return s;
        }
        // BOM-looking prefix that doesn't decode: fall through and treat the
        // bytes as BOM-less, as the editor does.
    }

    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) {
        if (outEncoding) *outEncoding = NSUTF8StringEncoding;
        return utf8;
    }

    // Not Unicode. A NUL byte here means binary: no legacy text encoding we
    // fall back to uses 0x00 for text, and Latin-1 would otherwise accept any
    // byte sequence and turn every image/archive into searchable "text".
    if (rejectBinary && len > 0 && memchr(b, 0, len) != NULL) return nil;

    // Large files skip the detector entirely (as the editor does); smaller
    // ones only show it a prefix. Replace in Files' round-trip check still
    // guards any write made with a prefix-based guess.
    NppDetectorMode mode = (len > NppLargeFileThreshold()) ? NppDetectorSkip : NppDetectorPrefix;
    return NppDecodeLegacyText(data, mode, outEncoding, nil);
}

NSData *NppEncodeTextData(NSString *text, NSStringEncoding encoding, BOOL hasBOM) {
    NSData *body = [text dataUsingEncoding:encoding allowLossyConversion:NO];
    if (!body) return nil;
    if (!hasBOM) return body;

    NSMutableData *out = [NSMutableData dataWithCapacity:body.length + 3];
    if (encoding == NSUTF8StringEncoding) {
        const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
        [out appendBytes:bom length:3];
    } else if (encoding == NSUTF16LittleEndianStringEncoding) {
        const uint8_t bom[] = {0xFF, 0xFE};
        [out appendBytes:bom length:2];
    } else if (encoding == NSUTF16BigEndianStringEncoding) {
        const uint8_t bom[] = {0xFE, 0xFF};
        [out appendBytes:bom length:2];
    }
    [out appendData:body];
    return out;
}
