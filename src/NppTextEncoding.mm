//  NppTextEncoding.mm
//  Shared text-file encoding detection. See NppTextEncoding.h.

#import "NppTextEncoding.h"

NSString *NppDecodeLegacyText(NSData *data, NSStringEncoding *outEncoding) {
    // macOS's heuristic charset detector covers the CJK encodings a plain
    // Win-1252/Latin-1 fallback turns into mojibake (GBK/GB18030, Big5,
    // Shift-JIS, EUC, ...). Only trust a result that decoded *without* lossy
    // substitution; anything else falls through to Win-1252/Latin-1, so
    // Western files never regress.
    NSString *detected = nil;
    BOOL detLossy = NO;
    NSStringEncoding guess = [NSString stringEncodingForData:data
                                            encodingOptions:nil
                                            convertedString:&detected
                                        usedLossyConversion:&detLossy];
    if (detected && guess != 0 && !detLossy && guess != NSUTF8StringEncoding) {
        if (outEncoding) *outEncoding = guess;
        return detected;
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

    return NppDecodeLegacyText(data, outEncoding);
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
