#import <Cocoa/Cocoa.h>

@class MainWindowController;
@class NppCommandLineParams;

@interface AppDelegate : NSObject <NSApplicationDelegate>

/// The primary window controller (first window opened).
@property (nonatomic, strong) MainWindowController *mainWindowController;

/// All open window controllers (including mainWindowController).
@property (nonatomic, strong, readonly) NSMutableArray<MainWindowController *> *windowControllers;

/// Command line parameters parsed in main(). Set before NSApplication runs.
@property (nonatomic, strong, nullable) NppCommandLineParams *cliParams;

/// Launch timestamp for -loadingTime display.
@property (nonatomic, strong, nullable) NSDate *launchStart;

/// YES once -applicationShouldTerminate: has begun tearing windows down.
/// Windows consult this so they don't re-save the session per-window while the
/// app is quitting — that save has already happened once, for all windows.
@property (nonatomic, readonly) BOOL isTerminating;

/// Create and show a new editor window. Returns the new controller.
- (MainWindowController *)openNewWindow;

/// Check GitHub for a newer release. If userInitiated is YES, shows alert even if up-to-date.
- (void)checkForUpdateUserInitiated:(BOOL)userInitiated;

/// Action wired to "Check for Updates..." menu item.
- (void)checkForUpdates:(id)sender;

@end
