#import <Cocoa/Cocoa.h>
#import "NppApplication.h"
#import "NppPaths.h"
#import "AppDelegate.h"
#import "NppCommandLineParams.h"

static void printHelp(const char *progName) {
    fprintf(stdout,
        "Usage:\n\n"
        "  %s [options] [filePath ...]\n\n"
        "Options:\n"
        "  --help                       This help message\n"
        "  -multiInst                   Launch another Nextpad++ instance\n"
        "  -noPlugin                    Launch without loading any plugin\n"
        "  -lLanguage                   Open file with syntax highlighting of choice\n"
        "  -udl=\"My UDL Name\"           Open file applying User Defined Language\n"
        "  -LlangCode                   Apply indicated localization\n"
        "  -nLineNumber                 Scroll to indicated line on filePath\n"
        "  -cColumnNumber               Scroll to indicated column on filePath\n"
        "  -pPosition                   Scroll to indicated byte position on filePath\n"
        "  -xLeftPos                    Move window to indicated X position\n"
        "  -yTopPos                     Move window to indicated Y position\n"
        "  -monitor                     Open file with monitoring (tail -f) enabled\n"
        "  -nosession                   Launch without loading previous session\n"
        "  -notabbar                    Launch without tab bar\n"
        "  -ro                          Make filePath read-only\n"
        "  -fullReadOnly                Open all files read-only (toggling allowed)\n"
        "  -fullReadOnlySavingForbidden Open all files read-only (saving disabled)\n"
        "  -alwaysOnTop                 Make window always on top\n"
        "  -openSession                 Open a session file (filePath must be a session)\n"
        "  -r                           Open files recursively (if filePath has wildcard)\n"
        "  -openFoldersAsWorkspace      Open folder(s) as workspace\n"
        "  -titleAdd=\"string\"           Add string to title bar\n"
        "  -settingsDir=\"path\"          Override default settings directory\n"
        "  -quickPrint                  Print file and quit\n"
        "  -loadingTime                 Display loading time\n\n"
        "  filePath                     File or folder to open (absolute or relative)\n\n"
        "Examples:\n"
        "  %s -n42 -lcpp main.cpp\n"
        "  %s -nosession -alwaysOnTop notes.txt\n"
        "  open NotepadPlusPlusMac.app --args -n10 file.txt\n",
        progName, progName, progName);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Parse command line arguments before NSApplication starts
        NppCommandLineParams *cliParams = [[NppCommandLineParams alloc] initWithArgc:argc argv:argv];

        if (cliParams.settingsDir.length) NppSetConfigDirOverride(cliParams.settingsDir);

        // --help: print usage to stdout and exit immediately (no GUI)
        if (cliParams.showHelp) {
            printHelp(argv[0]);
            return 0;
        }

        // A direct executable invocation (including Homebrew's binary link) must
        // deliver files and flags to the running app, just like Finder opens.
        NSString *bundleID=NSBundle.mainBundle.bundleIdentifier;
        if (!cliParams.multiInstance && !cliParams.settingsDir.length && bundleID.length) {
            for (NSRunningApplication *running in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
                if (running.processIdentifier==getpid()) continue;
                NSMutableArray *args=[NSMutableArray new];
                for (int i=0;i<argc;i++) {
                    NSString *arg=[NSString stringWithUTF8String:argv[i]];
                    if (i && ![arg hasPrefix:@"-"] && !arg.isAbsolutePath)
                        arg=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:arg];
                    [args addObject:arg];
                }
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:[bundleID stringByAppendingString:@".OpenCommandLine"]
                    object:[NSString stringWithFormat:@"%d",running.processIdentifier] userInfo:@{@"arguments":args} deliverImmediately:YES];
                [running activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                return 0;
            }
        }

        // -loadingTime: record start time
        NSDate *launchStart = cliParams.showLoadingTime ? [NSDate date] : nil;

        NppApplication *app = (NppApplication *)[NppApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        delegate.cliParams = cliParams;
        delegate.launchStart = launchStart;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
