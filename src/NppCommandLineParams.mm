#import "NppCommandLineParams.h"
#include <ctype.h>
#include <stdlib.h>
#include <math.h>

@implementation NppCommandLineParams {
    NSMutableArray<NSString *> *_filePaths;
}

- (instancetype)initWithArgc:(int)argc argv:(const char **)argv {
    self = [super init];
    if (!self) return nil;

    _filePaths = [NSMutableArray array];
    _bytePosition = -1;
    _windowX = NAN;
    _windowY = NAN;

    // Convert argv to NSArray for easier processing (skip argv[0] = program path)
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if (arg) [args addObject:arg];
    }

    // Strip macOS-injected arguments (e.g. -NSDocumentRevisionsDebugMode,
    // -ApplePersistenceIgnoreState, process serial numbers from `open`)
    NSMutableArray<NSString *> *cleaned = [NSMutableArray array];
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        // Skip macOS system args that start with -NS, -Apple, or -psn_
        if ([a hasPrefix:@"-psn_"])
            continue;
        // Some system args take a value as next arg (e.g. -NSDocumentRevisionsDebugMode YES)
        if ([a hasPrefix:@"-NS"] || [a hasPrefix:@"-Apple"]) {
            if (i + 1 < args.count) i++; // skip value
            continue;
        }
        [cleaned addObject:a];
    }
    args = cleaned;

    // Process arguments
    NSUInteger i = 0;
    while (i < args.count) {
        NSString *arg = args[i];

        // ── Boolean flags ─────────────────────────────────────────────
        if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-help"]) {
            _showHelp = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-multiInst"] == NSOrderedSame) {
            _multiInstance = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-noPlugin"] == NSOrderedSame) {
            _noPlugin = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-nosession"] == NSOrderedSame) {
            _noSession = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-notabbar"] == NSOrderedSame) {
            _noTabBar = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-ro"] == NSOrderedSame) {
            _readOnly = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-fullReadOnly"] == NSOrderedSame) {
            _fullReadOnly = YES; _readOnly = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-fullReadOnlySavingForbidden"] == NSOrderedSame) {
            _fullReadOnlySavingForbidden = YES; _readOnly = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-monitor"] == NSOrderedSame) {
            _monitorFiles = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-alwaysOnTop"] == NSOrderedSame) {
            _alwaysOnTop = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-quickPrint"] == NSOrderedSame) {
            _quickPrint = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-loadingTime"] == NSOrderedSame) {
            _showLoadingTime = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-r"] == NSOrderedSame) {
            _recursive = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-openFoldersAsWorkspace"] == NSOrderedSame) {
            _openFoldersAsWorkspace = YES; i++; continue;
        }
        if ([arg caseInsensitiveCompare:@"-openSession"] == NSOrderedSame) {
            _isSessionFile = YES; i++; continue;
        }

        // ── Numeric params: -nNUMBER, -cNUMBER, -pNUMBER, -xNUMBER, -yNUMBER ─
        if (arg.length >= 3 && [arg characterAtIndex:0] == '-') {
            unichar flag = [arg characterAtIndex:1];
            NSString *numStr = [arg substringFromIndex:2];
            BOOL isNumeric = YES;
            for (NSUInteger k = 0; k < numStr.length; k++) {
                unichar c = [numStr characterAtIndex:k];
                if (!isdigit(c) && c != '-' && c != '+') { isNumeric = NO; break; }
            }
            if (isNumeric && numStr.length > 0) {
                long long val = [numStr longLongValue];
                switch (flag) {
                    case 'n': _lineNumber = (NSInteger)val; i++; continue;
                    case 'c': _columnNumber = (NSInteger)val; i++; continue;
                    case 'p': _bytePosition = (NSInteger)val; i++; continue;
                    case 'x': _windowX = (CGFloat)val; i++; continue;
                    case 'y': _windowY = (CGFloat)val; i++; continue;
                    default: break;
                }
            }
        }

        // ── Language: -lLANGUAGE or -l LANGUAGE ───────────────────────
        if ([arg hasPrefix:@"-l"] && ![arg hasPrefix:@"-lo"] && arg.length > 2) {
            _language = [arg substringFromIndex:2];
            i++; continue;
        }

        // ── Localization: -LLANGCODE ──────────────────────────────────
        if ([arg hasPrefix:@"-L"] && arg.length > 2 && isupper([arg characterAtIndex:1])) {
            _localization = [arg substringFromIndex:2];
            i++; continue;
        }

        // ── Key=Value params ──────────────────────────────────────────
        NSString *val;
        if ((val = [self extractValue:arg forKey:@"-udl"])) {
            _udlName = val; i++; continue;
        }
        if ((val = [self extractValue:arg forKey:@"-settingsDir"])) {
            _settingsDir = val; i++; continue;
        }
        if ((val = [self extractValue:arg forKey:@"-titleAdd"])) {
            _titleAdd = val; i++; continue;
        }

        // ── Anything else is a file path ──────────────────────────────
        if (![arg hasPrefix:@"-"]) {
            // Resolve relative paths to absolute
            NSString *path = arg;
            if (![path isAbsolutePath]) {
                NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
                path = [cwd stringByAppendingPathComponent:path];
            }
            path = [path stringByStandardizingPath];
            [_filePaths addObject:path];
        }
        i++;
    }

    // If -openSession flag is set, treat first file path as session file
    if (_isSessionFile && _filePaths.count > 0) {
        _sessionFile = _filePaths.firstObject;
    }

    return self;
}

/// Extract value from -key="value" or -key=value format
- (nullable NSString *)extractValue:(NSString *)arg forKey:(NSString *)key {
    if (![arg hasPrefix:key]) return nil;
    NSString *rest = [arg substringFromIndex:key.length];
    if (rest.length == 0) return nil;
    if ([rest characterAtIndex:0] == '=') rest = [rest substringFromIndex:1];
    // Strip surrounding quotes
    if (rest.length >= 2 && [rest characterAtIndex:0] == '"' &&
        [rest characterAtIndex:rest.length - 1] == '"') {
        rest = [rest substringWithRange:NSMakeRange(1, rest.length - 2)];
    }
    return rest.length > 0 ? rest : nil;
}

- (BOOL)hasArguments {
    return _showHelp || _multiInstance || _noPlugin || _noSession || _noTabBar ||
           _readOnly || _monitorFiles || _alwaysOnTop || _quickPrint || _showLoadingTime ||
           _recursive || _openFoldersAsWorkspace || _isSessionFile ||
           _lineNumber > 0 || _columnNumber > 0 || _bytePosition >= 0 ||
           !isnan(_windowX) || !isnan(_windowY) ||
           _language || _udlName || _localization || _settingsDir || _titleAdd ||
           _filePaths.count > 0;
}

- (NSArray<NSString *> *)filePaths {
    return [_filePaths copy];
}

@end
