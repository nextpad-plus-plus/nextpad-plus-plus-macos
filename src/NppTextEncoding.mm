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

// Strict UTF-8 walk shared by NppIsDamagedUTF8 and NppDecodeDamagedUTF8.
// Counts well-formed multibyte sequences (*good) and ill-formed units (*bad).
// A truncated sequence is ONE bad unit (Unicode "maximal subpart": the lead plus
// the continuation bytes that were valid so far); the walk then resynchronises
// at the next byte. Rejects overlongs, surrogates, > U+10FFFF and C0/C1/F5-FF.
// If `out` is non-nil the text is decoded into it, each bad unit becoming one
// U+FFFD. If bailEarly is YES the walk stops as soon as the 8:1 threshold of
// NppIsDamagedUTF8 can no longer be met (*good/*bad are then partial).
static const NSUInteger kDamagedUTF8GoodPerBad = 8;

static void NppWalkUTF8(const uint8_t *b, NSUInteger len, BOOL bailEarly,
                        NSUInteger *good, NSUInteger *bad, NSMutableString *out) {
    NSUInteger i = 0, runStart = 0;
    *good = 0; *bad = 0;
    while (i < len) {
        uint8_t c = b[i];
        if (c < 0x80) { i++; continue; }

        NSUInteger need = 0;           // continuation bytes required
        uint8_t lo = 0x80, hi = 0xBF;  // allowed range of the first continuation
        if (c >= 0xC2 && c <= 0xDF)      need = 1;
        else if (c >= 0xE0 && c <= 0xEF) {
            need = 2;
            if (c == 0xE0) lo = 0xA0;
            else if (c == 0xED) hi = 0x9F;
        } else if (c >= 0xF0 && c <= 0xF4) {
            need = 3;
            if (c == 0xF0) lo = 0x90;
            else if (c == 0xF4) hi = 0x8F;
        }

        NSUInteger matched = 0;
        while (matched < need && i + 1 + matched < len) {
            uint8_t t = b[i + 1 + matched];
            if (t < lo || t > hi) break;
            matched++;
            lo = 0x80; hi = 0xBF;
        }

        if (need > 0 && matched == need) {
            (*good)++;
            i += 1 + need;
            continue;
        }

        // Ill-formed unit: the lead plus whatever continuation bytes were valid.
        (*bad)++;
        if (out) {
            if (i > runStart) {
                NSString *run = [[NSString alloc] initWithBytes:b + runStart length:i - runStart
                                                       encoding:NSUTF8StringEncoding];
                if (run) [out appendString:run];
            }
            [out appendString:@"\uFFFD"];
        }
        i += 1 + matched;
        runStart = i;
        if (bailEarly && *bad * kDamagedUTF8GoodPerBad > *good + (len - i) / 2) return;
    }
    if (out && len > runStart) {
        NSString *run = [[NSString alloc] initWithBytes:b + runStart length:len - runStart
                                               encoding:NSUTF8StringEncoding];
        if (run) [out appendString:run];
    }
}

BOOL NppIsDamagedUTF8(const uint8_t *bytes, NSUInteger length) {
    NSUInteger good, bad;
    NppWalkUTF8(bytes, length, YES, &good, &bad, nil);
    // Real GBK/Big5/Shift-JIS/EUC/Latin text produces far more ill-formed than
    // well-formed sequences, so 8:1 leaves a wide margin while still tolerating
    // a UTF-8 log with occasional damage.
    return bad > 0 && good >= kDamagedUTF8GoodPerBad * bad;
}

NSString *NppDecodeDamagedUTF8(NSData *data) {
    NSUInteger good, bad;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length];
    NppWalkUTF8((const uint8_t *)data.bytes, data.length, NO, &good, &bad, out);
    return out;
}

// The multibyte CJK encodings the detector reports. Only these can decode
// "with damage"; a single-byte code page accepts any byte sequence.
static BOOL NppIsMultibyteCJKEncoding(NSStringEncoding encoding) {
    switch (CFStringConvertNSStringEncodingToEncoding(encoding)) {
        case kCFStringEncodingGB_18030_2000: case kCFStringEncodingGBK_95:
        case kCFStringEncodingGB_2312_80:    case kCFStringEncodingEUC_CN:
        case kCFStringEncodingDOSChineseSimplif:
        case kCFStringEncodingBig5:          case kCFStringEncodingBig5_HKSCS_1999:
        case kCFStringEncodingBig5_E:        case kCFStringEncodingDOSChineseTrad:
        case kCFStringEncodingShiftJIS:      case kCFStringEncodingShiftJIS_X0213:
        case kCFStringEncodingDOSJapanese:   case kCFStringEncodingEUC_JP:
        case kCFStringEncodingEUC_KR:        case kCFStringEncodingDOSKorean:
            return YES;
        default:
            return NO;
    }
}

// Decode `data` in a multibyte CJK `encoding` although a strict decode of the
// whole data fails: a GBK log in which a few lines (or parts of a line) were
// written in UTF-8 by another component. Works line by line (0x0A is never a
// trail byte in these encodings); a line that does not decode strictly is
// decoded character by character, each undecodable byte becoming one U+FFFD.
// Returns nil unless the result is clearly `encoding` with a little damage:
// at least 8 decoded non-ASCII characters per U+FFFD (the NppIsDamagedUTF8
// ratio). Foreign bytes that happen to form valid characters in `encoding`
// decode as such, as they do in any editor showing the file in one code page.
static NSString *NppDecodeDamagedMultibyte(NSData *data, NSStringEncoding encoding) {
    const uint8_t *b = (const uint8_t *)data.bytes;
    const NSUInteger len = data.length;
    NSMutableString *out = [NSMutableString stringWithCapacity:len];
    NSUInteger good = 0, bad = 0;

    for (NSUInteger start = 0; start < len; ) {
        NSUInteger end = start;
        NSUInteger high = 0;
        while (end < len && b[end] != '\n') { if (b[end] >= 0x80) high++; end++; }
        if (end < len) end++;                       // keep the LF with its line

        @autoreleasepool {
            NSString *line = [[NSString alloc] initWithBytes:b + start length:end - start encoding:encoding];
            if (line) {
                [out appendString:line];
                good += high / 2;                   // close enough for the ratio
            } else {
                NSUInteger i = start;
                while (i < end) {
                    NSUInteger run = i;
                    while (run < end && b[run] < 0x80) run++;
                    if (run > i) {
                        NSString *ascii = [[NSString alloc] initWithBytes:b + i length:run - i
                                                                 encoding:NSASCIIStringEncoding];
                        if (ascii) [out appendString:ascii];
                        i = run;
                        continue;
                    }
                    NSString *ch = nil;
                    NSUInteger n = 2;
                    for (; n <= 4 && i + n <= end; n++) {
                        ch = [[NSString alloc] initWithBytes:b + i length:n encoding:encoding];
                        if (ch.length > 0) break;
                        ch = nil;
                    }
                    if (ch) {
                        [out appendString:ch];
                        good++;
                        i += n;
                    } else {
                        [out appendString:@"\uFFFD"];
                        bad++;
                        i++;
                    }
                }
            }
        }
        // Hopeless: stop before walking the rest of a big file byte by byte.
        if (bad > 64 && bad * kDamagedUTF8GoodPerBad > good + (len - end) / 2) return nil;
        start = end;
    }
    if (bad == 0 || good < kDamagedUTF8GoodPerBad * bad) return nil;
    return out;
}

NSString *NppDecodeLegacyText(NSData *data, NppDetectorMode mode,
                              NSStringEncoding *outEncoding,
                              BOOL (^acceptDetected)(NSString *text)) {
    // macOS's heuristic charset detector covers the CJK encodings a plain
    // Win-1252/Latin-1 fallback turns into mojibake (GBK/GB18030, Big5,
    // Shift-JIS, EUC, ...). Trust a result that decoded *without* lossy
    // substitution. A lossy (or, in prefix mode, not whole-file) decode is
    // still accepted when the guess is a multibyte CJK encoding and only a
    // little of the text is damaged (NppDecodeDamagedMultibyte): a GBK log
    // with a few UTF-8 lines is a GBK file, not Latin-1. Anything else falls
    // through to Win-1252/Latin-1. The detector can also pick another
    // single-byte code page (e.g. Windows-1250, 1251 or 1254) for some
    // Western text; the editor sees the same guess.
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
        if (guess != 0 && guess != NSUTF8StringEncoding) {
            NSString *full = nil;
            if (detected && !detLossy) {
                // Prefix mode: decode the whole data once with the guess. A
                // guess that fails on the rest of the file falls through below.
                full = partial ? [[NSString alloc] initWithData:data encoding:guess] : detected;
                if (full && (!acceptDetected || acceptDetected(full))) {
                    if (outEncoding) *outEncoding = guess;
                    return full;
                }
            }
            // The right code page, but some bytes don't fit it.
            if (!full && NppIsMultibyteCJKEncoding(guess)) {
                NSString *damaged = NppDecodeDamagedMultibyte(data, guess);
                if (damaged && (!acceptDetected || acceptDetected(damaged))) {
                    if (outEncoding) *outEncoding = guess;
                    return damaged;
                }
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

    // UTF-8 with a few damaged bytes (stray 0xFF, cut-off character, one GBK
    // line): the legacy detector excludes UTF-8 and would turn every CJK
    // character into mojibake, so decode as UTF-8 with U+FFFD for bad units.
    if (NppIsDamagedUTF8(b, len)) {
        if (outEncoding) *outEncoding = NSUTF8StringEncoding;
        return NppDecodeDamagedUTF8(data);
    }

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
