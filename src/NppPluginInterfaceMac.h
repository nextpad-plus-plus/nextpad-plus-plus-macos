/*
 * NppPluginInterfaceMac.h — macOS Plugin API for Nextpad++
 *
 * This header defines the plugin contract for the macOS port of Nextpad++.
 * It mirrors the Windows PluginInterface.h + Notepad_plus_msgs.h with
 * macOS-native types.  All NPPM_* and NPPN_* constants use the SAME
 * integer values as Windows so plugin source code can share constants.
 *
 * Key differences from Windows:
 *   - Strings are UTF-8 char* (not wchar_t*)
 *   - Handles are opaque uintptr_t (not HWND)
 *   - NppData includes a sendMessage function pointer (replaces Win32 SendMessage)
 *   - ShortcutKey adds _isCmd for the macOS Command key
 *   - No isUnicode() export — always Unicode
 *   - Export decoration: __attribute__((visibility("default")))
 */

#ifndef NPP_PLUGIN_INTERFACE_MAC_H
#define NPP_PLUGIN_INTERFACE_MAC_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ═══════════════════════════════════════════════════════════════════════════
   Win32 compatibility types — minimal set for easier plugin porting
   ═══════════════════════════════════════════════════════════════════════════ */
#ifndef _WIN32
  /* BOOL is already defined in Objective-C (objc/objc.h). Only define for
     pure C/C++ compilation units (i.e. plugin code without ObjC). */
  #ifndef OBJC_BOOL_DEFINED
    #ifndef __OBJC__
      typedef int           BOOL;
    #endif
  #endif
  typedef unsigned int    UINT;
  typedef intptr_t        LRESULT;
  typedef uintptr_t       WPARAM;
  typedef intptr_t        LPARAM;
  typedef unsigned char   UCHAR;
  typedef char            TCHAR;
  #ifndef TRUE
    #define TRUE  1
  #endif
  #ifndef FALSE
    #define FALSE 0
  #endif
  #define TEXT(x) x
#endif /* _WIN32 */

/* ═══════════════════════════════════════════════════════════════════════════
   Export macro
   ═══════════════════════════════════════════════════════════════════════════ */
#define NPP_EXPORT __attribute__((visibility("default")))

/* ═══════════════════════════════════════════════════════════════════════════
   Handle type & message-send function pointer
   ═══════════════════════════════════════════════════════════════════════════ */
typedef uintptr_t NppHandle;

/*
 * NppSendMessageFunc — replaces Win32 ::SendMessage().
 * Plugins call this for ALL communication with Nextpad++ and Scintilla.
 *   handle: one of NppData._nppHandle / _scintillaMainHandle / _scintillaSecondHandle
 *   msg:    NPPM_* constant (for nppHandle) or SCI_* constant (for scintilla handles)
 *   wParam, lParam: message-specific parameters (same semantics as Windows)
 */
typedef intptr_t (*NppSendMessageFunc)(uintptr_t handle, uint32_t msg,
                                       uintptr_t wParam, intptr_t lParam);

/* ═══════════════════════════════════════════════════════════════════════════
   Core data structures
   ═══════════════════════════════════════════════════════════════════════════ */

/* Passed to plugin via setInfo(). */
struct NppData {
    NppHandle _nppHandle;              /* Nextpad++ main (routes NPPM_* messages)  */
    NppHandle _scintillaMainHandle;    /* Primary editor  (routes SCI_* messages)  */
    NppHandle _scintillaSecondHandle;  /* Secondary editor (routes SCI_* messages) */
    NppSendMessageFunc _sendMessage;   /* Function to call instead of SendMessage  */
};

struct ShortcutKey {
    bool  _isCtrl;
    bool  _isAlt;     /* Option key on macOS */
    bool  _isShift;
    bool  _isCmd;     /* macOS Command key (not present on Windows) */
    UCHAR _key;       /* Virtual key code */
};

#define NPP_MENU_ITEM_SIZE 64

typedef void (*PFUNCPLUGINCMD)(void);

struct FuncItem {
    char            _itemName[NPP_MENU_ITEM_SIZE]; /* UTF-8 menu text */
    PFUNCPLUGINCMD  _pFunc;                        /* Command callback */
    int             _cmdID;                        /* Assigned by host */
    bool            _init2Check;                   /* Initial checkmark */
    struct ShortcutKey *_pShKey;                   /* Optional shortcut */
};

/* ═══════════════════════════════════════════════════════════════════════════
   Function pointer types (used internally by the host)
   ═══════════════════════════════════════════════════════════════════════════ */
typedef const char *       (*PFUNCGETNAME)(void);
typedef void               (*PFUNCSETINFO)(struct NppData);
typedef struct FuncItem *   (*PFUNCGETFUNCSARRAY)(int *);
typedef void               (*PBENOTIFIED)(struct SCNotification *);
typedef intptr_t           (*PMESSAGEPROC)(uint32_t, uintptr_t, intptr_t);

/* ═══════════════════════════════════════════════════════════════════════════
   NPPM_* messages  (same integer values as Windows)
   Base: WM_USER(0x0400) + 1000 = 2024
   ═══════════════════════════════════════════════════════════════════════════ */
#ifndef WM_USER
  #define WM_USER 0x0400
#endif
#define NPPMSG  (WM_USER + 1000)

/* ── Editor & view ──────────────────────────────────────────────────────── */
#define NPPM_GETCURRENTSCINTILLA         (NPPMSG + 4)
#define NPPM_GETCURRENTLANGTYPE          (NPPMSG + 5)
#define NPPM_SETCURRENTLANGTYPE          (NPPMSG + 6)
#define NPPM_GETNBOPENFILES              (NPPMSG + 7)
#define NPPM_GETOPENFILENAMES            (NPPMSG + 8)
#define NPPM_MODELESSDIALOG              (NPPMSG + 12)
#define NPPM_GETNBSESSIONFILES           (NPPMSG + 13)
#define NPPM_GETSESSIONFILES             (NPPMSG + 14)
#define NPPM_SAVESESSION                 (NPPMSG + 15)
#define NPPM_SAVECURRENTSESSION          (NPPMSG + 16)
#define NPPM_CREATESCINTILLAHANDLE       (NPPMSG + 20)
#define NPPM_GETNBUSERLANG               (NPPMSG + 22)
#define NPPM_GETCURRENTDOCINDEX          (NPPMSG + 23)
#define NPPM_SETSTATUSBAR                (NPPMSG + 24)
#define NPPM_GETMENUHANDLE               (NPPMSG + 25)
#define NPPM_ENCODESCI                   (NPPMSG + 26)
#define NPPM_DECODESCI                   (NPPMSG + 27)
#define NPPM_ACTIVATEDOC                 (NPPMSG + 28)
#define NPPM_LAUNCHFINDINFILESDLG        (NPPMSG + 29)
#define NPPM_DMMSHOW                     (NPPMSG + 30)
#define NPPM_DMMHIDE                     (NPPMSG + 31)
#define NPPM_DMMUPDATEDISPINFO           (NPPMSG + 32)
#define NPPM_DMMREGASDCKDLG              (NPPMSG + 33)
#define NPPM_LOADSESSION                 (NPPMSG + 34)
#define NPPM_DMMVIEWOTHERTAB             (NPPMSG + 35)
#define NPPM_RELOADFILE                  (NPPMSG + 36)
#define NPPM_SWITCHTOFILE                (NPPMSG + 37)
#define NPPM_SAVECURRENTFILE             (NPPMSG + 38)
#define NPPM_SAVEALLFILES                (NPPMSG + 39)
#define NPPM_SETMENUITEMCHECK            (NPPMSG + 40)
#define NPPM_GETWINDOWSVERSION           (NPPMSG + 42)
#define NPPM_DMMGETPLUGINHWNDBYNAME      (NPPMSG + 43)
#define NPPM_MAKECURRENTBUFFERDIRTY      (NPPMSG + 44)
#define NPPM_GETPLUGINSCONFIGDIR         (NPPMSG + 46)
#define NPPM_MSGTOPLUGIN                 (NPPMSG + 47)
#define NPPM_MENUCOMMAND                 (NPPMSG + 48)
#define NPPM_TRIGGERTABBARCONTEXTMENU    (NPPMSG + 49)
#define NPPM_GETNPPVERSION               (NPPMSG + 50)
#define NPPM_HIDETABBAR                  (NPPMSG + 51)
#define NPPM_ISTABBARHIDDEN              (NPPMSG + 52)
#define NPPM_GETPOSFROMBUFFERID          (NPPMSG + 57)
#define NPPM_GETFULLPATHFROMBUFFERID     (NPPMSG + 58)
#define NPPM_GETBUFFERIDFROMPOS          (NPPMSG + 59)
#define NPPM_GETCURRENTBUFFERID          (NPPMSG + 60)
#define NPPM_RELOADBUFFERID              (NPPMSG + 61)
#define NPPM_GETBUFFERLANGTYPE           (NPPMSG + 64)
#define NPPM_SETBUFFERLANGTYPE           (NPPMSG + 65)
#define NPPM_GETBUFFERENCODING           (NPPMSG + 66)
#define NPPM_SETBUFFERENCODING           (NPPMSG + 67)
#define NPPM_GETBUFFERFORMAT             (NPPMSG + 68)
#define NPPM_SETBUFFERFORMAT             (NPPMSG + 69)
#define NPPM_HIDETOOLBAR                 (NPPMSG + 70)
#define NPPM_ISTOOLBARHIDDEN             (NPPMSG + 71)
#define NPPM_HIDEMENU                    (NPPMSG + 72)
#define NPPM_ISMENUHIDDEN                (NPPMSG + 73)
#define NPPM_HIDESTATUSBAR               (NPPMSG + 74)
#define NPPM_ISSTATUSBARHIDDEN           (NPPMSG + 75)
#define NPPM_GETSHORTCUTBYCMDID          (NPPMSG + 76)
#define NPPM_DOOPEN                      (NPPMSG + 77)
#define NPPM_SAVECURRENTFILEAS           (NPPMSG + 78)
#define NPPM_GETCURRENTNATIVELANGENCODING (NPPMSG + 79)
/* ID allocation: NPPM_ALLOCATECMDID / NPPM_ALLOCATEMARKER /
 * NPPM_ALLOCATEINDICATOR take wParam = count, lParam = int* that receives
 * the first ID, and return TRUE, or FALSE when the request can't be met.
 * On failure, CMDID and MARKER set *lParam to 0; INDICATOR leaves it
 * unchanged (same as Windows). Ranges match Windows NPP; still, never
 * hard-code them:
 *   command IDs  23000-24998   (FuncItem _cmdIDs use 22000-22999)
 *   markers      1-14
 *   indicators   9-20
 * NPPM_GETBOOKMARKID returns the host's bookmark marker (20). */
#define NPPM_ALLOCATECMDID               (NPPMSG + 81)
#define NPPM_ALLOCATEMARKER              (NPPMSG + 82)
#define NPPM_GETLANGUAGENAME             (NPPMSG + 83)
#define NPPM_GETLANGUAGEDESC             (NPPMSG + 84)
#define NPPM_SHOWDOCLIST                 (NPPMSG + 85)
#define NPPM_ISDOCLISTSHOWN              (NPPMSG + 86)
#define NPPM_GETAPPDATAPLUGINSALLOWED    (NPPMSG + 87)
#define NPPM_GETCURRENTVIEW              (NPPMSG + 88)
#define NPPM_DOCLISTDISABLEEXTCOLUMN     (NPPMSG + 89)
#define NPPM_GETEDITORDEFAULTFOREGROUNDCOLOR (NPPMSG + 90)
#define NPPM_GETEDITORDEFAULTBACKGROUNDCOLOR (NPPMSG + 91)
#define NPPM_SETSMOOTHFONT               (NPPMSG + 92)
#define NPPM_SETEDITORBORDEREDGE         (NPPMSG + 93)
#define NPPM_SAVEFILE                    (NPPMSG + 94)
#define NPPM_DISABLEAUTOUPDATE           (NPPMSG + 95)
#define NPPM_REMOVESHORTCUTBYCMDID       (NPPMSG + 96)
#define NPPM_GETPLUGINHOMEPATH           (NPPMSG + 97)
#define NPPM_GETSETTINGSONCLOUDPATH      (NPPMSG + 98)
#define NPPM_SETLINENUMBERWIDTHMODE      (NPPMSG + 99)
#define NPPM_GETLINENUMBERWIDTHMODE      (NPPMSG + 100)
#define NPPM_ADDTOOLBARICON_FORDARKMODE  (NPPMSG + 101)
#define NPPM_DOCLISTDISABLEPATHCOLUMN    (NPPMSG + 102)
#define NPPM_GETEXTERNALLEXERAUTOINDENTMODE (NPPMSG + 103)
#define NPPM_SETEXTERNALLEXERAUTOINDENTMODE (NPPMSG + 104)
#define NPPM_ISAUTOINDENTON              (NPPMSG + 105)
#define NPPM_GETCURRENTMACROSTATUS       (NPPMSG + 106)
#define NPPM_ISDARKMODEENABLED           (NPPMSG + 107)
#define NPPM_GETDARKMODECOLORS           (NPPMSG + 108)
#define NPPM_GETCURRENTCMDLINE           (NPPMSG + 109)
#define NPPM_CREATELEXER                 (NPPMSG + 110)
#define NPPM_GETBOOKMARKID               (NPPMSG + 111)
#define NPPM_DARKMODESUBCLASSANDTHEME    (NPPMSG + 112)
#define NPPM_ALLOCATEINDICATOR           (NPPMSG + 113)
#define NPPM_GETTABCOLORID               (NPPMSG + 114)
#define NPPM_SETUNTITLEDNAME             (NPPMSG + 115)
#define NPPM_GETNATIVELANGFILENAME       (NPPMSG + 116)
#define NPPM_ADDSCNMODIFIEDFLAGS         (NPPMSG + 117)
#define NPPM_GETTOOLBARICONSETCHOICE     (NPPMSG + 118)
#define NPPM_GETNPPSETTINGSDIRPATH       (NPPMSG + 119)

/* ── macOS-specific extensions ──────────────────────────────────────────
 *
 * These messages exist only in the macOS port of Nextpad++ and have no
 * equivalent on Windows NPP. Slots NPPMSG+500 upward are reserved for
 * macOS-only use so they can never collide with a future backport from
 * the Windows tree (which currently uses +0..+119).
 */

/* Per-plugin opt-out of specific Scintilla UI notifications.
 *
 * By default, every plugin receives all forwarded Scintilla notifications
 * (SCN_CHARADDED, SCN_MODIFIED, SCN_UPDATEUI, SCN_PAINTED, etc.). A plugin
 * may call NPPM_SETPLUGINSUBSCRIPTIONS to opt out of UI-related codes if
 * it conflicts with host-level handling of those events (e.g., a plugin
 * doing its own scroll sync alongside the host's timer-based sync).
 *
 *   wParam — subscription bitmask (NPPPLUGIN_WANTS_* flags). Bits that are
 *            SET mean "I want this notification." Bits that are CLEAR mean
 *            "do NOT forward this notification to me."
 *   lParam — const char * module name of the calling plugin (required).
 *            The host uses this to find the plugin's internal record.
 *
 * Returns 1 on success, 0 if no plugin with the given module name is loaded.
 *
 * Call once (typically from NPPN_READY). The flags persist for the plugin's
 * lifetime. Default is NPPPLUGIN_DEFAULT_SUBSCRIPTIONS (all bits set), so
 * plugins that never call this message behave exactly as before. */
#define NPPM_SETPLUGINSUBSCRIPTIONS      (NPPMSG + 500)
#define NPPPLUGIN_WANTS_UPDATEUI         (1U << 0)
#define NPPPLUGIN_WANTS_PAINTED          (1U << 1)
#define NPPPLUGIN_DEFAULT_SUBSCRIPTIONS  (NPPPLUGIN_WANTS_UPDATEUI | NPPPLUGIN_WANTS_PAINTED)

/* Plugin panel docking API (macOS-only, since v1.0.3).
 *
 * Allows a plugin to register an NSView as a docked side panel sharing the
 * same SidePanelHost as the host's built-in panels (Document List, Function
 * List, Document Map, etc.). The host strong-retains the NSView for the
 * lifetime of its registration so the plugin doesn't have to worry about
 * keeping a strong reference itself.
 *
 * Lifecycle:
 *   1. At NPPN_READY (or any time after), call NPPM_DMM_REGISTERPANEL once
 *      with your content view. Store the returned handle.
 *   2. Call NPPM_DMM_SHOWPANEL / NPPM_DMM_HIDEPANEL to toggle visibility.
 *      These are idempotent — calling SHOW on an already-shown panel, or
 *      HIDE on an already-hidden panel, is a successful no-op.
 *   3. On plugin shutdown, call NPPM_DMM_UNREGISTERPANEL so the host can
 *      release its strong retain on your view. Omitting this is not
 *      usually fatal (the host cleans up at shutdown) but it's good form.
 *
 * Thread safety:
 *   All four messages are safe to call from any thread. The host marshals
 *   to the main queue when necessary. Messages that return a value block
 *   until the main-thread work completes.
 *
 * Graceful degradation:
 *   On older hosts (pre-1.0.3) the messages fall through to the default
 *   handler and return 0. A plugin can detect that and fall back to a
 *   floating NSPanel without breaking under older builds. */

/* Register an NSView as a docked side panel. Host strong-retains the view.
 *
 *   wParam — NSView * (cast through (uintptr_t)). Must be non-nil.
 *   lParam — const char * UTF-8 title (copied by the host). May be NULL.
 *
 * Returns a nonzero handle on success, 0 on failure (nil view, no main
 * window yet, host doesn't support the message, etc.).
 *
 * The panel is HIDDEN on registration — you must call NPPM_DMM_SHOWPANEL
 * to make it visible. A subsequent REGISTERPANEL call with the same NSView
 * returns the existing handle rather than allocating a new one. */
#define NPPM_DMM_REGISTERPANEL           (NPPMSG + 501)

/* Show a previously-registered panel.
 *
 *   wParam — handle returned from NPPM_DMM_REGISTERPANEL.
 *   lParam — unused.
 *
 * Returns 1 on success (including when the panel was already shown), 0 if
 * the handle is invalid. */
#define NPPM_DMM_SHOWPANEL               (NPPMSG + 502)

/* Hide a panel without unregistering it. Call NPPM_DMM_SHOWPANEL to make
 * it reappear later. The host keeps its strong retain on the view.
 *
 *   wParam — handle returned from NPPM_DMM_REGISTERPANEL.
 *   lParam — unused.
 *
 * Returns 1 on success (including when the panel was already hidden), 0 if
 * the handle is invalid. */
#define NPPM_DMM_HIDEPANEL               (NPPMSG + 503)

/* Unregister a panel entirely, releasing the host's strong retain on it.
 * Also hides the panel first if currently visible. After this call the
 * handle is invalid and further calls with it return 0.
 *
 *   wParam — handle returned from NPPM_DMM_REGISTERPANEL.
 *   lParam — unused.
 *
 * Returns 1 on success, 0 if the handle is invalid. */
#define NPPM_DMM_UNREGISTERPANEL         (NPPMSG + 504)

/* ── RUNCOMMAND_USER submessages ────────────────────────────────────────── */
#define RUNCOMMAND_USER                  (WM_USER + 3000)
#define NPPM_GETFULLCURRENTPATH          (RUNCOMMAND_USER + 1)
#define NPPM_GETCURRENTDIRECTORY         (RUNCOMMAND_USER + 2)
#define NPPM_GETFILENAME                 (RUNCOMMAND_USER + 3)
#define NPPM_GETNAMEPART                 (RUNCOMMAND_USER + 4)
#define NPPM_GETEXTPART                  (RUNCOMMAND_USER + 5)
#define NPPM_GETCURRENTWORD              (RUNCOMMAND_USER + 6)
#define NPPM_GETNPPDIRECTORY             (RUNCOMMAND_USER + 7)
#define NPPM_GETCURRENTLINE              (RUNCOMMAND_USER + 8)
#define NPPM_GETCURRENTCOLUMN            (RUNCOMMAND_USER + 9)
#define NPPM_GETNPPFULLFILEPATH          (RUNCOMMAND_USER + 10)
#define NPPM_GETFILENAMEATCURSOR         (RUNCOMMAND_USER + 11)
#define NPPM_GETCURRENTLINESTR           (RUNCOMMAND_USER + 12)

/* ═══════════════════════════════════════════════════════════════════════════
   NPPN_* notifications  (same integer values as Windows)
   Delivered via beNotified(SCNotification*) with nmhdr.code set to these.
   ═══════════════════════════════════════════════════════════════════════════ */
#define NPPN_FIRST                       1000
#define NPPN_READY                       (NPPN_FIRST + 1)
#define NPPN_TBMODIFICATION              (NPPN_FIRST + 2)
#define NPPN_FILEBEFORECLOSE             (NPPN_FIRST + 3)
#define NPPN_FILEOPENED                  (NPPN_FIRST + 4)
#define NPPN_FILECLOSED                  (NPPN_FIRST + 5)
#define NPPN_FILEBEFOREOPEN              (NPPN_FIRST + 6)
#define NPPN_FILEBEFORESAVE              (NPPN_FIRST + 7)
#define NPPN_FILESAVED                   (NPPN_FIRST + 8)
#define NPPN_SHUTDOWN                    (NPPN_FIRST + 9)
#define NPPN_BUFFERACTIVATED             (NPPN_FIRST + 10)
#define NPPN_LANGCHANGED                 (NPPN_FIRST + 11)
#define NPPN_WORDSTYLESUPDATED           (NPPN_FIRST + 12)
#define NPPN_SHORTCUTREMAPPED            (NPPN_FIRST + 13)
#define NPPN_FILEBEFORELOAD              (NPPN_FIRST + 14)
#define NPPN_FILELOADFAILED              (NPPN_FIRST + 15)
#define NPPN_READONLYCHANGED             (NPPN_FIRST + 16)
#define NPPN_DOCORDERCHANGED             (NPPN_FIRST + 17)
#define NPPN_SNAPSHOTDIRTYFILELOADED     (NPPN_FIRST + 18)
#define NPPN_BEFORESHUTDOWN              (NPPN_FIRST + 19)
#define NPPN_CANCELSHUTDOWN              (NPPN_FIRST + 20)
#define NPPN_FILEBEFORERENAME            (NPPN_FIRST + 21)
#define NPPN_FILERENAMECANCEL            (NPPN_FIRST + 22)
#define NPPN_FILERENAMED                 (NPPN_FIRST + 23)
#define NPPN_FILEBEFOREDELETE            (NPPN_FIRST + 24)
#define NPPN_FILEDELETEFAILED            (NPPN_FIRST + 25)
#define NPPN_FILEDELETED                 (NPPN_FIRST + 26)
#define NPPN_DARKMODECHANGED             (NPPN_FIRST + 27)
#define NPPN_CMDLINEPLUGINMSG            (NPPN_FIRST + 28)
#define NPPN_EXTERNALLEXERBUFFER         (NPPN_FIRST + 29)
#define NPPN_GLOBALMODIFIED              (NPPN_FIRST + 30)
#define NPPN_NATIVELANGCHANGED           (NPPN_FIRST + 31)
#define NPPN_TOOLBARICONSETCHANGED       (NPPN_FIRST + 32)

/* ═══════════════════════════════════════════════════════════════════════════
   View & misc constants
   ═══════════════════════════════════════════════════════════════════════════ */
#define MAIN_VIEW          0
#define SUB_VIEW           1
#define ALL_OPEN_FILES     0
#define PRIMARY_VIEW       1
#define SECOND_VIEW        2

#define NPPPLUGINMENU      0
#define NPPMAINMENU        1

#define MODELESSDIALOGADD     0
#define MODELESSDIALOGREMOVE  1

/* Status bar sections */
#define STATUSBAR_DOC_TYPE      0
#define STATUSBAR_DOC_SIZE      1
#define STATUSBAR_CUR_POS       2
#define STATUSBAR_EOF_FORMAT    3
#define STATUSBAR_UNICODE_TYPE  4
#define STATUSBAR_TYPING_MODE   5

/* Docking panel positions */
#define CONT_LEFT    0
#define CONT_RIGHT   1
#define CONT_TOP     2
#define CONT_BOTTOM  3

/* Docking style flags */
#define DWS_ICONTAB             0x00000001
#define DWS_ICONBAR             0x00000002
#define DWS_ADDINFO             0x00000004
#define DWS_USEOWNDARKMODE      0x00000008
#define DWS_DF_CONT_LEFT        (CONT_LEFT   << 28)
#define DWS_DF_CONT_RIGHT       (CONT_RIGHT  << 28)
#define DWS_DF_CONT_TOP         (CONT_TOP    << 28)
#define DWS_DF_CONT_BOTTOM      (CONT_BOTTOM << 28)
#define DWS_DF_FLOATING         0x80000000

/* Inter-plugin communication */
struct CommunicationInfo {
    long          internalMsg;
    const char   *srcModuleName;   /* UTF-8 (wchar_t on Windows) */
    void         *info;
};

/* ═══════════════════════════════════════════════════════════════════════════
   Convenience: redirect SendMessage calls through NppData._sendMessage
   Usage: after declaring `NppData nppData;` as a global, this macro lets
   existing plugin code like  SendMessage(nppData._nppHandle, NPPM_*, ...)
   compile without changes.
   ═══════════════════════════════════════════════════════════════════════════ */
#ifndef _WIN32
  /* Plugins must have `extern NppData nppData;` accessible in scope. */
  #define SendMessage(h, m, w, l) \
      nppData._sendMessage((uintptr_t)(h), (uint32_t)(m), (uintptr_t)(w), (intptr_t)(l))
  #define SendMessageW  SendMessage
  #define SendMessageA  SendMessage
#endif

/* ═══════════════════════════════════════════════════════════════════════════
   Required plugin exports
   Every .dylib plugin must export these 5 functions with C linkage.
   (isUnicode is not required — macOS plugins are always Unicode.)
   ═══════════════════════════════════════════════════════════════════════════ */

/*
 * setInfo — called once at load time with Nextpad++ handles.
 *   Store nppData and initialise your FuncItem array here.
 */
NPP_EXPORT void             setInfo(struct NppData nppData);

/*
 * getName — return a human-readable plugin name (UTF-8, static storage).
 */
NPP_EXPORT const char *     getName(void);

/*
 * getFuncsArray — return a pointer to your FuncItem array and set *nbF
 *   to the number of entries.  The array must have static lifetime.
 */
NPP_EXPORT struct FuncItem * getFuncsArray(int *nbF);

/*
 * beNotified — receive Scintilla (SCN_*) and Nextpad++ (NPPN_*)
 *   notifications.  Check notifyCode->nmhdr.code for the event type.
 */
NPP_EXPORT void             beNotified(struct SCNotification *notifyCode);

/*
 * messageProc — handle inter-plugin messages (NPPM_MSGTOPLUGIN).
 *   Return TRUE if handled, FALSE otherwise.
 */
NPP_EXPORT intptr_t         messageProc(uint32_t Message, uintptr_t wParam, intptr_t lParam);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NPP_PLUGIN_INTERFACE_MAC_H */
