#import "NPPBatchRunner.h"
#import "MainWindowController.h"
#import "TabManager.h"
#import "EditorView.h"

@implementation NPPBatchRunResult
@end

@implementation NPPBatchOptions
- (instancetype)init {
    if ((self = [super init])) {
        _filePaths = @[];
        _macroActions = @[];
        _saveAfter = YES;
        _closeAfter = YES;
        _closePreExistingTabs = NO;
        _maxFileSizeBytes = 0;
        _errorPolicy = NPPBatchErrorPolicySkip;
    }
    return self;
}
@end

@implementation NPPBatchRunner {
    __weak MainWindowController *_mwc;
    NPPBatchOptions *_options;
    BOOL _cancelled;
}

+ (instancetype)runnerForWindow:(MainWindowController *)mwc options:(NPPBatchOptions *)opts {
    NPPBatchRunner *r = [self new];
    r->_mwc = mwc;
    r->_options = opts;
    return r;
}

- (void)cancel {
    _cancelled = YES;
}

// Peek for an Esc keystroke and consume it if found. Non-Esc keystrokes are
// left in the queue so they dispatch normally to whatever window is currently
// key (the batch may run for minutes; the user is free to type elsewhere).
// Returns YES iff an Esc was consumed.
- (BOOL)_pollEscKey {
    NSEvent *evt = [NSApp nextEventMatchingMask:NSEventMaskKeyDown
                                      untilDate:[NSDate distantPast]
                                         inMode:NSDefaultRunLoopMode
                                        dequeue:NO];
    if (!evt || evt.keyCode != 53) return NO;
    // Esc — dequeue to claim it, then signal cancel.
    [NSApp nextEventMatchingMask:NSEventMaskKeyDown
                       untilDate:[NSDate distantPast]
                          inMode:NSDefaultRunLoopMode
                         dequeue:YES];
    return YES;
}

// Find the active TabManager via KVC. Same pattern NppPluginManager uses to
// reach the same ivar without widening the public header. Falls back to
// using -currentEditor's parent if direct lookup fails.
- (TabManager *)_primaryTabManager {
    MainWindowController *mwc = _mwc;
    if (!mwc) return nil;
    @try {
        TabManager *tm = [mwc valueForKey:@"_tabManager"];
        if ([tm isKindOfClass:[TabManager class]]) return tm;
    } @catch (NSException *) { /* ignore */ }
    return nil;
}

// Detect whether a given absolute path is already represented by an open tab.
// Used to avoid closing tabs the user had open before the batch (unless they
// opted in via closePreExistingTabs).
- (BOOL)_isPathAlreadyOpen:(NSString *)path {
    TabManager *tm = [self _primaryTabManager];
    NSString *target = path.stringByStandardizingPath;
    for (EditorView *ed in tm.allEditors) {
        if ([ed.filePath.stringByStandardizingPath isEqualToString:target]) return YES;
    }
    return NO;
}

- (NPPBatchRunResult *)_resultFor:(NSString *)path outcome:(NPPBatchOutcome)oc message:(NSString *)msg {
    NPPBatchRunResult *r = [NPPBatchRunResult new];
    r.filePath     = path;
    r.outcome      = oc;
    r.errorMessage = msg;
    return r;
}

- (void)runWithProgress:(void(^)(NSInteger, NSInteger, NSString *, NSInteger, NSInteger, NSInteger))progress
             completion:(void(^)(NSArray<NPPBatchRunResult *> *, BOOL))completion {
    NSArray<NSString *> *files = _options.filePaths ?: @[];
    NSArray<NSDictionary *> *macroActions = _options.macroActions ?: @[];
    const NSInteger total = (NSInteger)files.count;

    NSMutableArray<NPPBatchRunResult *> *results = [NSMutableArray arrayWithCapacity:total];
    NSInteger ok = 0, skipped = 0, failed = 0;

    TabManager *tm = [self _primaryTabManager];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (!tm || total == 0 || macroActions.count == 0) {
        if (completion) completion(results, NO);
        return;
    }

    for (NSInteger i = 0; i < total; i++) {
        if (_cancelled) break;

        @autoreleasepool {
            NSString *path = files[i];

            if (progress) progress(i, total, path, ok, skipped, failed);

            // ── 0. Size filter ────────────────────────────────────────────
            if (_options.maxFileSizeBytes > 0) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
                NSNumber *sz = attrs[NSFileSize];
                if (sz && sz.longLongValue > _options.maxFileSizeBytes) {
                    [results addObject:[self _resultFor:path
                                                outcome:NPPBatchOutcomeSkippedTooBig
                                                message:nil]];
                    skipped++;
                    if (progress) progress(i + 1, total, path, ok, skipped, failed);
                    continue;
                }
            }

            // ── 1. Was this tab already open?
            // We record this BEFORE openFileAtPath: because that call may
            // either activate an existing tab or load a fresh one — either
            // way we need to know the pre-existing state to decide whether
            // to close it later.
            const BOOL preExisting = [self _isPathAlreadyOpen:path];

            // ── 2. Open. _tabManager openFileAtPath: returns the EditorView
            // (newly-created OR pre-existing-activated). nil means it
            // couldn't load (missing, permission, encoding sniff failed).
            EditorView *ed = [tm openFileAtPath:path];
            if (!ed) {
                [results addObject:[self _resultFor:path
                                            outcome:NPPBatchOutcomeFailedToOpen
                                            message:@"openFileAtPath: returned nil"]];
                failed++;
                if (_options.errorPolicy == NPPBatchErrorPolicyStop) {
                    if (progress) progress(i + 1, total, path, ok, skipped, failed);
                    break;
                }
                if (progress) progress(i + 1, total, path, ok, skipped, failed);
                continue;
            }

            // ── 3. Run the macro on this buffer.
            BOOL macroOk = YES;
            NSString *macroErrMsg = nil;
            @try {
                [ed runMacroActions:macroActions];
            } @catch (NSException *ex) {
                macroOk = NO;
                macroErrMsg = ex.reason ?: ex.name;
            }
            if (!macroOk) {
                [results addObject:[self _resultFor:path
                                            outcome:NPPBatchOutcomeMacroFailed
                                            message:macroErrMsg]];
                failed++;
                if (_options.errorPolicy == NPPBatchErrorPolicyStop) {
                    if (progress) progress(i + 1, total, path, ok, skipped, failed);
                    break;
                }
                if (progress) progress(i + 1, total, path, ok, skipped, failed);
                continue;
            }

            // ── 4. Save if modified (and requested).
            BOOL saveOk = YES;
            NSString *saveErrMsg = nil;
            if (_options.saveAfter && ed.isModified) {
                NSError *err = nil;
                saveOk = [ed saveError:&err];
                if (!saveOk) saveErrMsg = err.localizedDescription;
            }
            if (!saveOk) {
                [results addObject:[self _resultFor:path
                                            outcome:NPPBatchOutcomeSaveFailed
                                            message:saveErrMsg]];
                failed++;
                if (_options.errorPolicy == NPPBatchErrorPolicyStop) {
                    if (progress) progress(i + 1, total, path, ok, skipped, failed);
                    break;
                }
                if (progress) progress(i + 1, total, path, ok, skipped, failed);
                continue;
            }

            // ── 5. Close if requested.
            // Pre-existing tabs are protected by default — closing them
            // would yank away a buffer the user was actively working in.
            // The closePreExistingTabs flag is the explicit opt-in.
            if (_options.closeAfter && (!preExisting || _options.closePreExistingTabs)) {
                MainWindowController *mwc = _mwc;
                mwc.suppressClosedFileRecording = YES;
                [tm closeEditor:ed];
                mwc.suppressClosedFileRecording = NO;
            } else if (_options.closeAfter && preExisting) {
                // Record the protected-tab case so the user can see in the
                // result summary why some tabs remained open.
                [results addObject:[self _resultFor:path
                                            outcome:NPPBatchOutcomeSkippedPreExisting
                                            message:nil]];
                // Still counts as "ok" for the success count — the macro ran
                // and saved; only the close was skipped by policy.
                ok++;
                if (progress) progress(i + 1, total, path, ok, skipped, failed);
                // Pump and check cancel before the next file.
                if ([self _pollEscKey]) _cancelled = YES;
                continue;
            }

            [results addObject:[self _resultFor:path
                                        outcome:NPPBatchOutcomeOk
                                        message:nil]];
            ok++;
            if (progress) progress(i + 1, total, path, ok, skipped, failed);

            // ── 6. Pump the run loop so the progress sheet repaints,
            // dispatch the Cancel-button action if it was clicked, and let
            // us see any Esc keystroke that arrived while the macro ran.
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate distantPast]];
            if ([self _pollEscKey]) _cancelled = YES;
        }
    }

    if (completion) completion(results, _cancelled);
}

@end
