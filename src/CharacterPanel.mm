#import "CharacterPanel.h"
#import "NppLocalizer.h"
#import "StyleConfiguratorWindowController.h"   // NPPStyleStore
#import "NppThemeManager.h"

// Phase 2: title-bar close button moved to shared PanelFrame.

// ── HTML data helpers (ported from asciiListView.cpp) ─────────────────────────

static NSString *_htmlName(int v)
{
    switch (v) {
        case  33: return @"&excl;";    case  34: return @"&quot;";
        case  35: return @"&num;";     case  36: return @"&dollar;";
        case  37: return @"&percnt;";  case  38: return @"&amp;";
        case  39: return @"&apos;";    case  40: return @"&lpar;";
        case  41: return @"&rpar;";    case  42: return @"&ast;";
        case  43: return @"&plus;";    case  44: return @"&comma;";
        case  45: return @"&minus;";   case  46: return @"&period;";
        case  47: return @"&sol;";     case  58: return @"&colon;";
        case  59: return @"&semi;";    case  60: return @"&lt;";
        case  61: return @"&equals;";  case  62: return @"&gt;";
        case  63: return @"&quest;";   case  64: return @"&commat;";
        case  91: return @"&lbrack;";  case  92: return @"&bsol;";
        case  93: return @"&rbrack;";  case  94: return @"&Hat;";
        case  95: return @"&lowbar;";  case  96: return @"&grave;";
        case 123: return @"&lbrace;";  case 124: return @"&vert;";
        case 125: return @"&rbrace;";
        case 128: return @"&euro;";    case 130: return @"&sbquo;";
        case 131: return @"&fnof;";    case 132: return @"&bdquo;";
        case 133: return @"&hellip;";  case 134: return @"&dagger;";
        case 135: return @"&Dagger;";  case 136: return @"&circ;";
        case 137: return @"&permil;";  case 138: return @"&Scaron;";
        case 139: return @"&lsaquo;";  case 140: return @"&OElig;";
        case 142: return @"&Zcaron;";  case 145: return @"&lsquo;";
        case 146: return @"&rsquo;";   case 147: return @"&ldquo;";
        case 148: return @"&rdquo;";   case 149: return @"&bull;";
        case 150: return @"&ndash;";   case 151: return @"&mdash;";
        case 152: return @"&tilde;";   case 153: return @"&trade;";
        case 154: return @"&scaron;";  case 155: return @"&rsaquo;";
        case 156: return @"&oelig;";   case 158: return @"&zcaron;";
        case 159: return @"&Yuml;";    case 160: return @"&nbsp;";
        case 161: return @"&iexcl;";   case 162: return @"&cent;";
        case 163: return @"&pound;";   case 164: return @"&curren;";
        case 165: return @"&yen;";     case 166: return @"&brvbar;";
        case 167: return @"&sect;";    case 168: return @"&uml;";
        case 169: return @"&copy;";    case 170: return @"&ordf;";
        case 171: return @"&laquo;";   case 172: return @"&not;";
        case 173: return @"&shy;";     case 174: return @"&reg;";
        case 175: return @"&macr;";    case 176: return @"&deg;";
        case 177: return @"&plusmn;";  case 178: return @"&sup2;";
        case 179: return @"&sup3;";    case 180: return @"&acute;";
        case 181: return @"&micro;";   case 182: return @"&para;";
        case 183: return @"&middot;";  case 184: return @"&cedil;";
        case 185: return @"&sup1;";    case 186: return @"&ordm;";
        case 187: return @"&raquo;";   case 188: return @"&frac14;";
        case 189: return @"&frac12;";  case 190: return @"&frac34;";
        case 191: return @"&iquest;";  case 192: return @"&Agrave;";
        case 193: return @"&Aacute;";  case 194: return @"&Acirc;";
        case 195: return @"&Atilde;";  case 196: return @"&Auml;";
        case 197: return @"&Aring;";   case 198: return @"&AElig;";
        case 199: return @"&Ccedil;";  case 200: return @"&Egrave;";
        case 201: return @"&Eacute;";  case 202: return @"&Ecirc;";
        case 203: return @"&Euml;";    case 204: return @"&Igrave;";
        case 205: return @"&Iacute;";  case 206: return @"&Icirc;";
        case 207: return @"&Iuml;";    case 208: return @"&ETH;";
        case 209: return @"&Ntilde;";  case 210: return @"&Ograve;";
        case 211: return @"&Oacute;";  case 212: return @"&Ocirc;";
        case 213: return @"&Otilde;";  case 214: return @"&Ouml;";
        case 215: return @"&times;";   case 216: return @"&Oslash;";
        case 217: return @"&Ugrave;";  case 218: return @"&Uacute;";
        case 219: return @"&Ucirc;";   case 220: return @"&Uuml;";
        case 221: return @"&Yacute;";  case 222: return @"&THORN;";
        case 223: return @"&szlig;";   case 224: return @"&agrave;";
        case 225: return @"&aacute;";  case 226: return @"&acirc;";
        case 227: return @"&atilde;";  case 228: return @"&auml;";
        case 229: return @"&aring;";   case 230: return @"&aelig;";
        case 231: return @"&ccedil;";  case 232: return @"&egrave;";
        case 233: return @"&eacute;";  case 234: return @"&ecirc;";
        case 235: return @"&euml;";    case 236: return @"&igrave;";
        case 237: return @"&iacute;";  case 238: return @"&icirc;";
        case 239: return @"&iuml;";    case 240: return @"&eth;";
        case 241: return @"&ntilde;";  case 242: return @"&ograve;";
        case 243: return @"&oacute;";  case 244: return @"&ocirc;";
        case 245: return @"&otilde;";  case 246: return @"&ouml;";
        case 247: return @"&divide;";  case 248: return @"&oslash;";
        case 249: return @"&ugrave;";  case 250: return @"&uacute;";
        case 251: return @"&ucirc;";   case 252: return @"&uuml;";
        case 253: return @"&yacute;";  case 254: return @"&thorn;";
        case 255: return @"&yuml;";
        default:  return @"";
    }
}

// Unicode code point for Windows-1252 bytes that don't match their byte value
static int _htmlNumber(int v)
{
    switch (v) {
        case  45: return 8722;   // MINUS SIGN
        case 128: return 8364;   // EURO SIGN
        case 130: return 8218;   case 131: return 402;
        case 132: return 8222;   case 133: return 8230;
        case 134: return 8224;   case 135: return 8225;
        case 136: return 710;    case 137: return 8240;
        case 138: return 352;    case 139: return 8249;
        case 140: return 338;    case 142: return 381;
        case 145: return 8216;   case 146: return 8217;
        case 147: return 8220;   case 148: return 8221;
        case 149: return 8226;   case 150: return 8211;
        case 151: return 8212;   case 152: return 732;
        case 153: return 8482;   case 154: return 353;
        case 155: return 8250;   case 156: return 339;
        case 158: return 382;    case 159: return 376;
        default: return -1;
    }
}

// Display string for the Character column (abbreviation for control chars)
static NSString *_displayChar(int v)
{
    switch (v) {
        case  0: return @"NULL"; case  1: return @"SOH"; case  2: return @"STX";
        case  3: return @"ETX";  case  4: return @"EOT"; case  5: return @"ENQ";
        case  6: return @"ACK";  case  7: return @"BEL"; case  8: return @"BS";
        case  9: return @"TAB";  case 10: return @"LF";  case 11: return @"VT";
        case 12: return @"FF";   case 13: return @"CR";  case 14: return @"SO";
        case 15: return @"SI";   case 16: return @"DLE"; case 17: return @"DC1";
        case 18: return @"DC2";  case 19: return @"DC3"; case 20: return @"DC4";
        case 21: return @"NAK";  case 22: return @"SYN"; case 23: return @"ETB";
        case 24: return @"CAN";  case 25: return @"EM";  case 26: return @"SUB";
        case 27: return @"ESC";  case 28: return @"FS";  case 29: return @"GS";
        case 30: return @"RS";   case 31: return @"US";  case 32: return @"Space";
        case 127: return @"DEL";
        default: {
            uint8_t byte = (uint8_t)v;
            NSString *s = [[NSString alloc] initWithBytes:&byte length:1
                                                 encoding:NSWindowsCP1252StringEncoding];
            return s ?: [NSString stringWithFormat:@"(%d)", v];
        }
    }
}

// ── Column identifiers ────────────────────────────────────────────────────────

static NSString *const kColVal  = @"val";   // 0
static NSString *const kColHex  = @"hex";   // 1
static NSString *const kColChar = @"char";  // 2
static NSString *const kColName = @"name";  // 3  HTML Name
static NSString *const kColDec  = @"dec";   // 4  HTML Decimal
static NSString *const kColXHex = @"xhex";  // 5  HTML Hexadecimal

// ── CharacterPanel ────────────────────────────────────────────────────────────

@implementation CharacterPanel {
    NSScrollView *_scrollView;
    NSTableView  *_tableView;
    // _rows[v] = @[dec, hex, charDisplay, htmlName, htmlDecimal, htmlHex]
    NSArray<NSArray<NSString *> *> *_rows;
    CGFloat _panelFontSize;
    // UTF-8 strings to insert when clicking the Character column
    NSArray<NSString *> *_insertStrings;
}

- (instancetype)init {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        { CGFloat z = [[NSUserDefaults standardUserDefaults] floatForKey:@"PanelZoom_Character"]; _panelFontSize = z >= 8 ? z : 11; }
        [self _buildData];
        [self _buildLayout];
        [self retranslateUI];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_locChanged:)
                                                     name:NPPLocalizationChanged object:nil];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)_locChanged:(NSNotification *)n { [self retranslateUI]; }
// Title is now supplied by PanelFrame via MainWindowController's centralized
// NPPLocalizationChanged observer. This panel only needs to retranslate its
// own table column headers (the panel's internal chrome).
- (void)retranslateUI {
    NppLocalizer *loc = [NppLocalizer shared];
    for (NSTableColumn *col in _tableView.tableColumns) {
        NSString *ident = col.identifier;
        if ([ident isEqualToString:kColVal])  col.title = [loc translate:@"Value"];
        else if ([ident isEqualToString:kColHex])  col.title = [loc translate:@"Hex"];
        else if ([ident isEqualToString:kColChar]) col.title = [loc translate:@"Character"];
        else if ([ident isEqualToString:kColName]) col.title = [loc translate:@"HTML Name"];
        else if ([ident isEqualToString:kColDec])  col.title = [loc translate:@"HTML Decimal"];
        else if ([ident isEqualToString:kColXHex]) col.title = [loc translate:@"HTML Hexadecimal"];
    }
}

// ── Data model ────────────────────────────────────────────────────────────────

- (void)_buildData {
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray arrayWithCapacity:256];
    NSMutableArray<NSString *> *inserts = [NSMutableArray arrayWithCapacity:256];

    for (int v = 0; v < 256; v++) {
        NSString *dec     = [NSString stringWithFormat:@"%d", v];
        NSString *hex     = [NSString stringWithFormat:@"%02X", v];
        NSString *charDisp = _displayChar(v);
        NSString *name    = _htmlName(v);

        NSString *htmlDec = @"";
        NSString *htmlHex = @"";

        if ((v >= 32 && v <= 126 && v != 45) || (v >= 160 && v <= 255)) {
            htmlDec = [NSString stringWithFormat:@"&#%d;",  v];
            htmlHex = [NSString stringWithFormat:@"&#x%x;", v];
        } else {
            int n = _htmlNumber(v);
            if (n > 0) {
                htmlDec = [NSString stringWithFormat:@"&#%d;",  n];
                htmlHex = [NSString stringWithFormat:@"&#x%x;", n];
            }
        }

        [rows addObject:@[dec, hex, charDisp, name, htmlDec, htmlHex]];

        // Character to insert: interpret the byte as Windows-1252 → Unicode
        uint8_t byte = (uint8_t)v;
        NSString *ins = [[NSString alloc] initWithBytes:&byte length:1
                                               encoding:NSWindowsCP1252StringEncoding];
        [inserts addObject:ins ?: @""];
    }
    _rows          = [rows copy];
    _insertStrings = [inserts copy];
}

// ── Layout ────────────────────────────────────────────────────────────────────

- (void)_buildLayout {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Table ─────────────────────────────────────────────────────────────────
    _tableView = [[NSTableView alloc] init];
    _tableView.rowHeight = 18;
    _tableView.dataSource = self;
    _tableView.delegate   = self;
    _tableView.allowsEmptySelection = YES;
    _tableView.allowsMultipleSelection = NO;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;

    // Column specs: identifier, title, width, fixed?
    NppLocalizer *loc = [NppLocalizer shared];
    struct ColSpec { NSString *ident; NSString *title; CGFloat w; BOOL fixed; };
    ColSpec cols[] = {
        { kColVal,  [loc translate:@"Value"],            45,  YES },
        { kColHex,  [loc translate:@"Hex"],              45,  YES },
        { kColChar, [loc translate:@"Character"],        70,  YES },
        { kColName, [loc translate:@"HTML Name"],       100,  YES },
        { kColDec,  [loc translate:@"HTML Decimal"],    110,  YES },
        { kColXHex, [loc translate:@"HTML Hexadecimal"], 0,   NO  },  // last: autoresize
    };
    NSUInteger nCols = sizeof(cols) / sizeof(cols[0]);
    for (NSUInteger i = 0; i < nCols; i++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:cols[i].ident];
        col.title = cols[i].title;
        col.editable = NO;
        if (cols[i].fixed) {
            col.width    = cols[i].w;
            col.minWidth = cols[i].w;
            col.maxWidth = cols[i].w;
            col.resizingMask = NSTableColumnNoResizing;
        } else {
            col.resizingMask = NSTableColumnAutoresizingMask;
        }
        [_tableView addTableColumn:col];
    }
    [_tableView sizeLastColumnToFit];

    _tableView.target       = self;
    _tableView.action       = @selector(_rowClicked:);
    _tableView.doubleAction = @selector(_rowDoubleClicked:);

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.documentView          = _tableView;

    [self addSubview:_scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
    ]];

    [self _applyTheme];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(_themeChanged:)
               name:@"NPPPreferencesChanged" object:nil];
}

- (void)_applyTheme {
    NSColor *bg = [[NPPStyleStore sharedStore] globalBg];

    // Whole panel background (visible behind the table header)
    self.wantsLayer = YES;
    self.layer.backgroundColor = bg.CGColor;

    _scrollView.backgroundColor = bg;
    _tableView.backgroundColor  = bg;

    // Drive table appearance (incl. header) from theme brightness
    _tableView.appearance = [NppThemeManager appearanceForBackground:bg];

    [_tableView reloadData];
}

- (void)_themeChanged:(NSNotification *)note {
    [self _applyTheme];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return 256;
}

// ── NSTableViewDelegate ───────────────────────────────────────────────────────

- (nullable NSView *)tableView:(NSTableView *)tv
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    if (row < 0 || row >= 256) return nil;

    NSString *colId = tableColumn.identifier;
    NSArray<NSString *> *rowData = _rows[(NSUInteger)row];
    NSString *text;
    if      ([colId isEqual:kColVal])  text = rowData[0];
    else if ([colId isEqual:kColHex])  text = rowData[1];
    else if ([colId isEqual:kColChar]) text = rowData[2];
    else if ([colId isEqual:kColName]) text = rowData[3];
    else if ([colId isEqual:kColDec])  text = rowData[4];
    else                               text = rowData[5];

    NSTextField *cell = [tv makeViewWithIdentifier:@"CharCell" owner:nil];
    if (!cell) {
        cell = [[NppThemedLabel alloc] init];
        cell.identifier     = @"CharCell";
        cell.editable       = NO;
        cell.bordered       = NO;
        cell.drawsBackground = NO;
        cell.font = [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightRegular];
    }
    cell.stringValue = text;
    if ([cell isKindOfClass:[NppThemedLabel class]])
        ((NppThemedLabel *)cell).themeTextColor = [[NPPStyleStore sharedStore] globalFg];
    else
        cell.textColor = [[NPPStyleStore sharedStore] globalFg];
    cell.font = [NSFont monospacedSystemFontOfSize:_panelFontSize weight:NSFontWeightRegular];
    return cell;
}

// ── Click handling ────────────────────────────────────────────────────────────

/// Single-click: insert the character (col 0-2) or the HTML entity (col 3-5).
- (void)_rowClicked:(id)sender {
    [self _insertForRow:_tableView.clickedRow column:_tableView.clickedColumn];
}

/// Double-click: same behaviour (keeps parity with NPP Windows double-click).
- (void)_rowDoubleClicked:(id)sender {
    [self _insertForRow:_tableView.clickedRow column:_tableView.clickedColumn];
}

- (void)_insertForRow:(NSInteger)row column:(NSInteger)col {
    if (row < 0 || row >= 256 || col < 0) return;

    NSString *str;
    if (col == 2) {
        // Character column → insert the actual Unicode character
        str = _insertStrings[(NSUInteger)row];
    } else {
        // All other columns → insert the text shown in that cell
        // (decimal value, hex value, HTML name, HTML decimal, HTML hex)
        str = _rows[(NSUInteger)row][(NSUInteger)col];
    }

    if (!str.length) { NSBeep(); return; }
    [_delegate characterPanel:self insertString:str];
}

#pragma mark - Panel Zoom

- (void)_saveZoom { [[NSUserDefaults standardUserDefaults] setFloat:_panelFontSize forKey:@"PanelZoom_Character"]; }
- (void)panelZoomIn    { _panelFontSize = MIN(_panelFontSize + 1, 28); _tableView.rowHeight = _panelFontSize + 8; [_tableView reloadData]; [self _saveZoom]; }
- (void)panelZoomOut   { _panelFontSize = MAX(_panelFontSize - 1, 8);  _tableView.rowHeight = _panelFontSize + 8; [_tableView reloadData]; [self _saveZoom]; }
- (void)panelZoomReset { _panelFontSize = 11; _tableView.rowHeight = 19; [_tableView reloadData]; [self _saveZoom]; }

@end
