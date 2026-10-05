//  NppModelXmlMerge.mm
//  See NppModelXmlMerge.h. Port of NppParameters::updateFromModelXml,
//  updateLangXml and updateStylesXml from Notepad++ PowerEditor/src/Parameters.cpp.
//
//  NSXMLDocument cannot write a document back without reformatting it (empty
//  elements, quoting, the XML declaration, escaped '>' in attributes), so it is
//  used only to reject malformed files. The merge itself runs on a small scanner
//  that records where each element and attribute sits in the original text, and
//  applies the additions as text insertions at those positions.

#import "NppModelXmlMerge.h"
#import "NppPaths.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

// ── Scanner ──────────────────────────────────────────────────────────────────

struct XAttr {
    NSRange name;
    NSRange value;  // raw value, quotes excluded
    unichar quote;
};

struct XElem {
    NSRange name;
    NSUInteger start = 0;        // '<'
    NSUInteger attrsEnd = 0;     // just after the last attribute (or the name)
    NSUInteger startTagEnd = 0;  // just after the start tag's '>'
    NSUInteger contentStart = 0;
    NSUInteger contentEnd = 0;   // the '<' of the end tag
    NSUInteger end = 0;          // just after the end tag (or the self-closing tag)
    bool selfClosing = false;
    int parent = -1;
    std::vector<XAttr> attrs;
    std::vector<int> children;
};

static inline bool isXmlSpace(unichar c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

class XDoc {
public:
    NSString *text = nil;
    std::vector<unichar> buf;
    std::vector<XElem> elems;
    int root = -1;

    /// Scan the whole document. With rootOnly, stop after the root's start tag.
    bool parse(NSString *t, bool rootOnly = false) {
        text = t;
        const NSUInteger n = t.length;
        buf.resize(n);
        if (n) [t getCharacters:buf.data() range:NSMakeRange(0, n)];
        elems.clear();
        root = -1;

        auto at = [&](NSUInteger p, const char *s) {
            for (NSUInteger k = 0; s[k]; k++)
                if (p + k >= n || buf[p + k] != (unichar)s[k]) return false;
            return true;
        };
        auto find = [&](NSUInteger p, const char *s) -> NSUInteger {
            for (; p < n; p++) if (at(p, s)) return p;
            return NSNotFound;
        };
        auto skipSpace = [&](NSUInteger p) { while (p < n && isXmlSpace(buf[p])) p++; return p; };

        std::vector<int> stack;
        NSUInteger i = 0;
        while (i < n) {
            if (buf[i] != '<') { i++; continue; }
            if (at(i, "<!--")) {
                NSUInteger p = find(i + 4, "-->");
                if (p == NSNotFound) return false;
                i = p + 3; continue;
            }
            if (at(i, "<![CDATA[")) {
                NSUInteger p = find(i + 9, "]]>");
                if (p == NSNotFound) return false;
                i = p + 3; continue;
            }
            if (at(i, "<?")) {
                NSUInteger p = find(i + 2, "?>");
                if (p == NSNotFound) return false;
                i = p + 2; continue;
            }
            if (at(i, "<!")) {  // DOCTYPE, possibly with an internal subset
                int depth = 0;
                NSUInteger j = i + 2;
                for (; j < n; j++) {
                    unichar c = buf[j];
                    if (c == '[') depth++;
                    else if (c == ']') depth--;
                    else if (c == '>' && depth <= 0) break;
                }
                if (j >= n) return false;
                i = j + 1; continue;
            }
            if (at(i, "</")) {
                NSUInteger j = i + 2, ns = j;
                while (j < n && !isXmlSpace(buf[j]) && buf[j] != '>') j++;
                NSRange nm = NSMakeRange(ns, j - ns);
                while (j < n && buf[j] != '>') j++;
                if (j >= n || stack.empty()) return false;
                XElem &top = elems[stack.back()];
                if (![[t substringWithRange:top.name] isEqualToString:[t substringWithRange:nm]]) return false;
                top.contentEnd = i;
                top.end = j + 1;
                stack.pop_back();
                i = j + 1; continue;
            }

            // Start tag
            XElem e;
            e.start = i;
            NSUInteger j = i + 1, ns = j;
            while (j < n && !isXmlSpace(buf[j]) && buf[j] != '>' && buf[j] != '/') j++;
            if (j == ns) return false;
            e.name = NSMakeRange(ns, j - ns);
            e.attrsEnd = j;
            for (;;) {
                j = skipSpace(j);
                if (j >= n) return false;
                unichar c = buf[j];
                if (c == '/') {
                    if (j + 1 < n && buf[j + 1] == '>') { e.selfClosing = true; j += 2; break; }
                    return false;
                }
                if (c == '>') { j++; break; }
                NSUInteger as = j;
                while (j < n && !isXmlSpace(buf[j]) && buf[j] != '=' && buf[j] != '>' && buf[j] != '/') j++;
                if (j == as) return false;
                XAttr a;
                a.name = NSMakeRange(as, j - as);
                j = skipSpace(j);
                if (j >= n || buf[j] != '=') return false;
                j = skipSpace(j + 1);
                if (j >= n || (buf[j] != '"' && buf[j] != '\'')) return false;
                a.quote = buf[j];
                NSUInteger vs = ++j;
                while (j < n && buf[j] != a.quote) j++;
                if (j >= n) return false;
                a.value = NSMakeRange(vs, j - vs);
                j++;
                e.attrsEnd = j;
                e.attrs.push_back(a);
            }
            e.startTagEnd = j;
            e.parent = stack.empty() ? -1 : stack.back();
            const int idx = (int)elems.size();
            if (e.selfClosing) { e.contentStart = e.contentEnd = e.end = j; }
            else               { e.contentStart = j; }
            elems.push_back(e);
            if (e.parent >= 0) elems[e.parent].children.push_back(idx);
            else if (root >= 0) return false;  // second root element
            else root = idx;
            if (!e.selfClosing) stack.push_back(idx);
            if (rootOnly && root >= 0) return true;
            i = j;
        }
        return stack.empty() && root >= 0;
    }

    NSString *sub(NSRange r) const { return [text substringWithRange:r]; }
    NSString *name(int e) const { return sub(elems[e].name); }

    const XAttr *attr(int e, NSString *n) const {
        for (const XAttr &a : elems[e].attrs)
            if ([sub(a.name) isEqualToString:n]) return &a;
        return nullptr;
    }
    /// Raw attribute value, or nil when the attribute is absent.
    NSString *attrValue(int e, NSString *n) const {
        const XAttr *a = attr(e, n);
        return a ? sub(a->value) : nil;
    }
    std::vector<int> childrenNamed(int e, NSString *n) const {
        std::vector<int> out;
        for (int c : elems[e].children) if ([name(c) isEqualToString:n]) out.push_back(c);
        return out;
    }
    int firstChildNamed(int e, NSString *n) const {
        for (int c : elems[e].children) if ([name(c) isEqualToString:n]) return c;
        return -1;
    }
    NSString *content(int e) const {
        const XElem &x = elems[e];
        return sub(NSMakeRange(x.contentStart, x.contentEnd - x.contentStart));
    }
    /// The spaces/tabs between the start of the element's line and the element,
    /// or nil when something else precedes it on that line.
    NSString *indentOf(int e) const {
        NSUInteger s = elems[e].start, k = s;
        while (k > 0 && (buf[k - 1] == ' ' || buf[k - 1] == '\t')) k--;
        if (k > 0 && buf[k - 1] != '\n' && buf[k - 1] != '\r') return nil;
        return sub(NSMakeRange(k, s - k));
    }
};

// ── Edits ────────────────────────────────────────────────────────────────────

struct AttrOverride {
    int elem;          // element index in the source document
    NSString *attr;
    NSString *value;
};

struct NewChild {
    int srcElem;                       // element in the model to copy
    std::vector<AttrOverride> overrides;
    int before = -1;                   // insert before this user element, else append

    explicit NewChild(int e) : srcElem(e) {}
};

struct NewAttr {
    NSString *name;
    NSString *value;  // raw, already escaped
    unichar quote;
};

struct Pending {
    std::vector<NewAttr> attrs;
    std::vector<NewChild> children;
    NSString *content = nil;  // replacement content (Keywords text)
};

struct Edit {
    NSUInteger loc, len;
    NSString *text;
    size_t seq;
};

static NSArray<NSString *> *tokens(NSString *s) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *t in [s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (t.length) [out addObject:t];
    return out;
}

static NSString *normalizeNewlines(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    return [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}

static NSString *detectEOL(NSString *s) {
    NSRange lf = [s rangeOfString:@"\n"];
    if (lf.location != NSNotFound)
        return (lf.location > 0 && [s characterAtIndex:lf.location - 1] == '\r') ? @"\r\n" : @"\n";
    return [s rangeOfString:@"\r"].location != NSNotFound ? @"\r" : @"\n";
}

class Merger {
public:
    const XDoc &u;  // user
    const XDoc &m;  // model
    const bool isTheme;
    NSString *eol;
    NSString *unit;  // one indentation step in the user file
    std::map<int, Pending> pend;
    std::vector<Edit> edits;
    size_t seq = 0;

    Merger(const XDoc &user, const XDoc &model, bool theme) : u(user), m(model), isTheme(theme) {
        eol = detectEOL(u.text);
        unit = @"    ";
        for (size_t i = 0; i < u.elems.size(); i++) {
            int p = u.elems[i].parent;
            if (p < 0) continue;
            NSString *ci = u.indentOf((int)i), *pi = u.indentOf(p);
            if (ci && pi && ci.length > pi.length && [ci hasPrefix:pi]) {
                unit = [ci substringFromIndex:pi.length];
                break;
            }
        }
    }

    void addAttr(int e, NSString *name, NSString *value, unichar quote = '"') {
        pend[e].attrs.push_back({name, value, quote});
    }
    void setAttrValue(int e, NSString *name, NSString *value) {
        const XAttr *a = u.attr(e, name);
        if (a) edits.push_back({a->value.location, a->value.length, value, seq++});
        else addAttr(e, name, value);
    }
    void addChild(int parent, NewChild c) { pend[parent].children.push_back(c); }
    void setContent(int e, NSString *content) { pend[e].content = content; }

    /// The model element's text, re-indented to `indent` and converted to the
    /// user file's line endings, with `ov` applied to existing attributes.
    NSString *cloneText(const NewChild &c, NSString *indent) {
        const XElem &x = m.elems[c.srcElem];
        NSMutableString *s = [m.sub(NSMakeRange(x.start, x.end - x.start)) mutableCopy];
        std::vector<std::pair<NSRange, NSString *>> reps;
        for (const AttrOverride &o : c.overrides) {
            const XAttr *a = m.attr(o.elem, o.attr);
            if (a) reps.push_back({NSMakeRange(a->value.location - x.start, a->value.length), o.value});
        }
        std::sort(reps.begin(), reps.end(), [](auto &a, auto &b) { return a.first.location > b.first.location; });
        for (auto &r : reps) [s replaceCharactersInRange:r.first withString:r.second];

        NSString *modelIndent = m.indentOf(c.srcElem) ?: @"";
        NSArray<NSString *> *lines = [normalizeNewlines(s) componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *l = lines[i];
            if (i > 0 && modelIndent.length && [l hasPrefix:modelIndent])
                l = [indent stringByAppendingString:[l substringFromIndex:modelIndent.length]];
            else if (i > 0 && !modelIndent.length && l.length)
                l = [indent stringByAppendingString:l];
            [out addObject:l];
        }
        return [out componentsJoinedByString:eol];
    }

    NSString *childIndentFor(int e) {
        NSString *pi = u.indentOf(e) ?: @"";
        const XElem &x = u.elems[e];
        if (!x.children.empty()) {
            NSString *ci = u.indentOf(x.children.back());
            if (ci) return ci;
        }
        return [pi stringByAppendingString:unit];
    }

    void emit() {
        for (auto &kv : pend) {
            const int e = kv.first;
            Pending &p = kv.second;
            const XElem &x = u.elems[e];
            NSString *pi = u.indentOf(e) ?: @"";
            NSString *ci = childIndentFor(e);

            NSMutableString *attrText = [NSMutableString string];
            for (const NewAttr &a : p.attrs)
                [attrText appendFormat:@" %@=%C%@%C", a.name, a.quote, a.value, a.quote];

            NSMutableString *appended = [NSMutableString string];
            for (const NewChild &c : p.children) {
                if (c.before >= 0) {
                    NSString *bi = u.indentOf(c.before) ?: ci;
                    NSString *t = [NSString stringWithFormat:@"%@%@%@", cloneText(c, bi), eol, bi];
                    edits.push_back({u.elems[c.before].start, 0, t, seq++});
                } else {
                    [appended appendFormat:@"%@%@%@", eol, ci, cloneText(c, ci)];
                }
            }

            if (x.selfClosing && (appended.length || p.content)) {
                // <X a="1" /> becomes <X a="1">...</X>
                NSString *body = p.content ?: [appended stringByAppendingFormat:@"%@%@", eol, pi];
                NSString *t = [NSString stringWithFormat:@"%@>%@</%@>", attrText, body, u.name(e)];
                edits.push_back({x.attrsEnd, x.startTagEnd - x.attrsEnd, t, seq++});
                continue;
            }
            if (attrText.length) edits.push_back({x.attrsEnd, 0, attrText, seq++});
            if (p.content)
                edits.push_back({x.contentStart, x.contentEnd - x.contentStart, p.content, seq++});
            if (appended.length) {
                if (!x.children.empty()) {
                    edits.push_back({u.elems[x.children.back()].end, 0, appended, seq++});
                } else {
                    NSString *existing = u.content(e);
                    BOOL multiline = [existing rangeOfCharacterFromSet:
                                      [NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location != NSNotFound;
                    NSString *t = multiline ? appended
                                            : [appended stringByAppendingFormat:@"%@%@", eol, pi];
                    edits.push_back({x.contentStart, 0, t, seq++});
                }
            }
        }
    }

    NSString *apply() {
        emit();
        std::sort(edits.begin(), edits.end(), [](const Edit &a, const Edit &b) {
            if (a.loc != b.loc) return a.loc > b.loc;
            return a.seq > b.seq;
        });
        NSMutableString *out = [u.text mutableCopy];
        for (const Edit &ed : edits)
            [out replaceCharactersInRange:NSMakeRange(ed.loc, ed.len) withString:ed.text];
        return out;
    }

    // ── langs ────────────────────────────────────────────────────────────────

    /// Space-separated words, sorted, with lines wrapped near 8000 characters,
    /// exactly as updateLangXml writes them.
    NSString *joinWords(NSArray<NSString *> *words) {
        NSArray *sorted = [words sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            int r = strcmp(a.UTF8String, b.UTF8String);
            return r < 0 ? NSOrderedAscending : r > 0 ? NSOrderedDescending : NSOrderedSame;
        }];
        NSMutableString *out = [NSMutableString string];
        NSString *wrap = [eol stringByAppendingString:@"                "];
        NSUInteger lineLength = 0;
        BOOL first = YES;
        for (NSString *w in sorted) {
            if (!first) { [out appendString:@" "]; lineLength += 1; }
            first = NO;
            NSUInteger wl = strlen(w.UTF8String);
            if (lineLength + wl >= 8000) { lineLength = 0; [out appendString:wrap]; }
            [out appendString:w];
            lineLength += wl;
        }
        return out;
    }

    bool mergeLangs() {
        int lu = u.firstChildNamed(u.root, @"Languages");
        int lm = m.firstChildNamed(m.root, @"Languages");
        if (lu < 0 || lm < 0) return false;

        NSMutableDictionary<NSString *, NSNumber *> *userLangs = [NSMutableDictionary dictionary];
        for (int c : u.childrenNamed(lu, @"Language")) {
            NSString *n = u.attrValue(c, @"name");
            if (n) userLangs[n] = @(c);
        }

        for (int ml : m.childrenNamed(lm, @"Language")) {
            NSString *langName = m.attrValue(ml, @"name");
            if (!langName.length) continue;
            NSNumber *found = userLangs[langName];
            if (!found) { addChild(lu, NewChild(ml)); continue; }
            const int ul = found.intValue;

            NSMutableDictionary<NSString *, NSNumber *> *userKw = [NSMutableDictionary dictionary];
            for (int k : u.childrenNamed(ul, @"Keywords")) {
                NSString *n = u.attrValue(k, @"name");
                if (n) userKw[n] = @(k);
            }
            for (int mk : m.childrenNamed(ml, @"Keywords")) {
                NSString *kwName = m.attrValue(mk, @"name");
                if (!kwName.length) continue;
                NSNumber *uk = userKw[kwName];
                if (!uk) { addChild(ul, NewChild(mk)); continue; }

                NSString *userText = u.content(uk.intValue);
                NSString *modelText = m.content(mk);
                // Only plain word lists are merged; leave anything with markup alone.
                if ([userText containsString:@"<"] || [modelText containsString:@"<"]) continue;
                NSArray<NSString *> *userWords = tokens(userText);
                NSArray<NSString *> *modelWords = tokens(modelText);
                if (!userWords.count) {
                    // An empty user group takes the model's words, as upstream does.
                    if (modelWords.count) {
                        NSString *t = [normalizeNewlines(modelText) stringByTrimmingCharactersInSet:
                                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        setContent(uk.intValue, [t stringByReplacingOccurrencesOfString:@"\n" withString:eol]);
                    }
                    continue;
                }
                NSMutableArray<NSString *> *all = [userWords mutableCopy];
                NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:userWords];
                for (NSString *w in modelWords)
                    if (![seen containsObject:w]) { [seen addObject:w]; [all addObject:w]; }
                if (all.count != userWords.count) setContent(uk.intValue, joinWords(all));
            }

            // Missing <Language> attributes, and extensions missing from "ext".
            for (const XAttr &a : m.elems[ml].attrs) {
                NSString *an = m.sub(a.name);
                NSString *uv = u.attrValue(ul, an);
                NSString *mv = m.sub(a.value);
                if (!uv) { addAttr(ul, an, mv, a.quote); continue; }
                if ([an isEqualToString:@"ext"]) {
                    NSMutableArray<NSString *> *exts = [NSMutableArray array];
                    NSMutableSet<NSString *> *seen = [NSMutableSet set];
                    for (NSString *t in [tokens(uv) arrayByAddingObjectsFromArray:tokens(mv)])
                        if (![seen containsObject:t]) { [seen addObject:t]; [exts addObject:t]; }
                    if (exts.count != tokens(uv).count)
                        setAttrValue(ul, @"ext", [exts componentsJoinedByString:@" "]);
                }
            }
        }
        return true;
    }

    // ── stylers / themes ─────────────────────────────────────────────────────

    static NSString *widgetKey(const XDoc &d, int e) {
        NSString *sid = d.attrValue(e, @"styleID");
        int v = sid.intValue;
        if (v > 0 && v <= 256) return [NSString stringWithFormat:@"%d", v];
        return d.attrValue(e, @"name") ?: @"";
    }

    bool mergeStylers() {
        int gsU = u.firstChildNamed(u.root, @"GlobalStyles");
        int gsM = m.firstChildNamed(m.root, @"GlobalStyles");
        int lsU = u.firstChildNamed(u.root, @"LexerStyles");
        int lsM = m.firstChildNamed(m.root, @"LexerStyles");
        if (gsU < 0 || gsM < 0 || lsU < 0 || lsM < 0) return false;

        // Themes give anything added the colours of their own "Default Style".
        NSString *defaultFg = @"", *defaultBg = @"";
        NSMutableDictionary<NSString *, NSNumber *> *userWidgets = [NSMutableDictionary dictionary];
        for (int w : u.childrenNamed(gsU, @"WidgetStyle")) {
            NSString *key = widgetKey(u, w);
            if (!key.length) continue;
            userWidgets[key] = @(w);
            if ([key isEqualToString:@"32"]) {
                defaultFg = u.attrValue(w, @"fgColor") ?: @"";
                defaultBg = u.attrValue(w, @"bgColor") ?: @"";
            }
        }

        for (int mw : m.childrenNamed(gsM, @"WidgetStyle")) {
            NSString *key = widgetKey(m, mw);
            if (!key.length) continue;
            NSNumber *uw = userWidgets[key];
            if (uw) {
                for (const XAttr &a : m.elems[mw].attrs) {
                    NSString *an = m.sub(a.name);
                    if (u.attr(uw.intValue, an)) continue;  // present, even if empty: keep it
                    NSString *v = m.sub(a.value);
                    if (isTheme && [an isEqualToString:@"fgColor"]) v = defaultFg;
                    else if (isTheme && [an isEqualToString:@"bgColor"]) v = defaultBg;
                    addAttr(uw.intValue, an, v, a.quote);
                }
            } else {
                NewChild c(mw);
                if (isTheme) {
                    if (m.attr(mw, @"fgColor")) c.overrides.push_back({mw, @"fgColor", defaultFg});
                    if (m.attr(mw, @"bgColor")) c.overrides.push_back({mw, @"bgColor", defaultBg});
                }
                addChild(gsU, c);
            }
        }

        NSMutableDictionary<NSString *, NSNumber *> *userLexers = [NSMutableDictionary dictionary];
        for (int l : u.childrenNamed(lsU, @"LexerType")) {
            NSString *n = u.attrValue(l, @"name");
            if (n) userLexers[n] = @(l);
        }
        NSNumber *searchResult = userLexers[@"searchResult"];

        for (int ml : m.childrenNamed(lsM, @"LexerType")) {
            NSString *lexName = m.attrValue(ml, @"name");
            if (!lexName) continue;

            // A theme gaining "javascript.js" takes its colours from the theme's
            // embedded "javascript" lexer (dot-js styleID -> embedded styleID).
            std::map<std::string, std::map<std::string, std::string>> jsColors;
            if (isTheme && [lexName isEqualToString:@"javascript.js"] && userLexers[@"javascript"]) {
                static const std::pair<const char *, const char *> kMap[] = {
                    {"11", "41"}, {"4", "45"}, {"16", "46"}, {"5", "47"}, {"19", "47"},
                    {"6", "48"}, {"20", "48"}, {"7", "49"}, {"10", "50"}, {"14", "52"},
                    {"1", "42"}, {"2", "43"}, {"3", "44"}, {"15", "44"}, {"17", "44"},
                    {"18", "44"}, {"19", "44"}, {"128", "200"}, {"129", "201"},
                    {"130", "202"}, {"131", "203"}, {"132", "204"}, {"133", "205"},
                    {"134", "206"}, {"135", "207"},
                };
                for (int ews : u.childrenNamed(userLexers[@"javascript"].intValue, @"WordsStyle")) {
                    NSString *eid = u.attrValue(ews, @"styleID");
                    if (!eid) continue;
                    NSString *efg = u.attrValue(ews, @"fgColor"), *ebg = u.attrValue(ews, @"bgColor");
                    for (const auto &pr : kMap) {
                        if (strcmp(pr.second, eid.UTF8String) != 0) continue;
                        if (efg) jsColors[pr.first]["fgColor"] = efg.UTF8String;
                        if (ebg) jsColors[pr.first]["bgColor"] = ebg.UTF8String;
                    }
                }
            }
            auto themeColor = [&](NSString *styleID, NSString *attrName) -> NSString * {
                auto it = jsColors.find(styleID.UTF8String ?: "");
                if (it != jsColors.end()) {
                    auto jt = it->second.find(attrName.UTF8String);
                    if (jt != it->second.end()) return @(jt->second.c_str());
                }
                return [attrName isEqualToString:@"fgColor"] ? defaultFg : defaultBg;
            };
            auto themeOverrides = [&](int mws, std::vector<AttrOverride> &ov) {
                NSString *sid = m.attrValue(mws, @"styleID") ?: @"";
                for (NSString *an in @[@"fgColor", @"bgColor"])
                    if (m.attr(mws, an)) ov.push_back({mws, an, themeColor(sid, an)});
            };

            NSNumber *ul = userLexers[lexName];
            if (!ul) {
                NewChild c(ml);
                if (isTheme)
                    for (int mws : m.childrenNamed(ml, @"WordsStyle")) themeOverrides(mws, c.overrides);
                if (searchResult && ![lexName isEqualToString:@"searchResult"]) c.before = searchResult.intValue;
                addChild(lsU, c);
                continue;
            }

            NSMutableDictionary<NSString *, NSNumber *> *userStyles = [NSMutableDictionary dictionary];
            for (int ws : u.childrenNamed(ul.intValue, @"WordsStyle")) {
                NSString *sid = u.attrValue(ws, @"styleID");
                if (sid) userStyles[sid] = @(ws);
            }
            for (int mws : m.childrenNamed(ml, @"WordsStyle")) {
                NSString *sid = m.attrValue(mws, @"styleID");
                if (!sid.length) continue;
                NSNumber *uws = userStyles[sid];
                if (!uws) {
                    NewChild c(mws);
                    if (isTheme) themeOverrides(mws, c.overrides);
                    addChild(ul.intValue, c);
                    continue;
                }
                for (const XAttr &a : m.elems[mws].attrs) {
                    NSString *an = m.sub(a.name);
                    if (u.attr(uws.intValue, an)) continue;
                    NSString *v = m.sub(a.value);
                    if (isTheme && ([an isEqualToString:@"fgColor"] || [an isEqualToString:@"bgColor"]))
                        v = themeColor(sid, an);
                    addAttr(uws.intValue, an, v, a.quote);
                }
            }
        }
        return true;
    }
};

static NSError *mergeError(NSString *msg) {
    return [NSError errorWithDomain:@"NppModelXmlMerge" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static BOOL isWellFormed(NSString *text, NSString **why) {
    NSError *err = nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithXMLString:text options:0 error:&err];
    if (!doc && why) *why = err.localizedDescription ?: @"unknown parse error";
    return doc != nil;
}

}  // namespace

// ── Public API ───────────────────────────────────────────────────────────────

NSString *NppMergeModelXmlText(NSString *userText, NSString *modelText, NppModelXmlKind kind,
                               BOOL isTheme, NppModelXmlMergeStatus *status, NSError **error) {
    auto fail = [&](NSString *msg) -> NSString * {
        if (status) *status = NppModelXmlMergeFailed;
        if (error) *error = mergeError(msg);
        return nil;
    };
    if (status) *status = NppModelXmlMergeUpToDate;

    // Cheap check first: only the root start tags are needed to compare dates.
    XDoc ur, mr;
    if (!mr.parse(modelText, true) || ![mr.name(mr.root) isEqualToString:@"NotepadPlus"])
        return fail(@"model has no <NotepadPlus> root");
    if (!ur.parse(userText, true) || ![ur.name(ur.root) isEqualToString:@"NotepadPlus"])
        return fail(@"user file has no <NotepadPlus> root");
    NSString *modelDate = mr.attrValue(mr.root, @"modelDate");
    const long long vModel = modelDate.longLongValue;
    const long long vUser = ur.attrValue(ur.root, @"modelDate").longLongValue;  // 0 when absent
    if (vModel == 0 || vUser >= vModel) return nil;

    NSString *why = nil;
    if (!isWellFormed(modelText, &why)) return fail([@"model does not parse: " stringByAppendingString:why]);
    if (!isWellFormed(userText, &why)) return fail([@"user file does not parse: " stringByAppendingString:why]);

    XDoc u, m;
    if (!m.parse(modelText)) return fail(@"model could not be scanned");
    if (!u.parse(userText)) return fail(@"user file could not be scanned");

    Merger mg(u, m, isTheme);
    bool ok = kind == NppModelXmlKindLangs ? mg.mergeLangs() : mg.mergeStylers();
    if (!ok) return fail(kind == NppModelXmlKindLangs ? @"missing <Languages>"
                                                      : @"missing <GlobalStyles> or <LexerStyles>");
    mg.setAttrValue(u.root, @"modelDate", modelDate);
    NSString *merged = mg.apply();

    if (!isWellFormed(merged, &why)) return fail([@"merge produced invalid XML: " stringByAppendingString:why]);
    if (status) *status = NppModelXmlMergeMerged;
    return merged;
}

NppModelXmlMergeStatus NppMergeModelXmlFile(NSString *userPath, NSString *modelPath,
                                            NppModelXmlKind kind, BOOL isTheme) {
    // Follow a symlinked config file (dotfiles setups) instead of replacing the link.
    NSString *path = [userPath stringByResolvingSymlinksInPath];
    NSString *file = path.lastPathComponent;

    NSData *userData = [NSData dataWithContentsOfFile:path];
    NSData *modelData = [NSData dataWithContentsOfFile:modelPath];
    if (!userData || !modelData) {
        NSLog(@"[ModelMerge] %@: could not read %@", file, userData ? modelPath : path);
        return NppModelXmlMergeFailed;
    }
    NSString *userText = [[NSString alloc] initWithData:userData encoding:NSUTF8StringEncoding];
    NSString *modelText = [[NSString alloc] initWithData:modelData encoding:NSUTF8StringEncoding];
    if (!userText || !modelText) {
        NSLog(@"[ModelMerge] %@: not UTF-8, left untouched", file);
        return NppModelXmlMergeFailed;
    }

    NppModelXmlMergeStatus status;
    NSError *err = nil;
    NSString *merged = NppMergeModelXmlText(userText, modelText, kind, isTheme, &status, &err);
    if (status == NppModelXmlMergeFailed) {
        NSLog(@"[ModelMerge] %@: %@; left untouched", file, err.localizedDescription);
        return status;
    }
    if (!merged) return status;

    // Keep one backup of the pre-merge file next to it.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSString *prefix = [file stringByAppendingString:@".bak-"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil])
        if ([name hasPrefix:prefix]) [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    NSDateFormatter *df = [NSDateFormatter new];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.dateFormat = @"yyyyMMdd";
    NSString *backup = [dir stringByAppendingPathComponent:
                        [prefix stringByAppendingString:[df stringFromDate:[NSDate date]]]];
    if (![userData writeToFile:backup options:NSDataWritingAtomic error:&err]) {
        NSLog(@"[ModelMerge] %@: backup failed (%@); left untouched", file, err.localizedDescription);
        return NppModelXmlMergeFailed;
    }
    if (![[merged dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:NSDataWritingAtomic error:&err]) {
        NSLog(@"[ModelMerge] %@: write failed (%@); left untouched", file, err.localizedDescription);
        return NppModelXmlMergeFailed;
    }
    NSLog(@"[ModelMerge] %@: merged entries from %@ (backup %@)", file,
          modelPath.lastPathComponent, backup.lastPathComponent);
    return NppModelXmlMergeMerged;
}

namespace {
struct UserModelFile {
    NSString *user;
    NSString *model;
    NppModelXmlKind kind;
    NSString *tag;
};

static std::vector<UserModelFile> userModelFiles() {
    // User edits langs.xml to customise extensions, keywords and comment
    // delimiters, and stylers.xml to customise the Default theme styles.
    return {
        {@"langs.xml",   @"langs.model",   NppModelXmlKindLangs,   @"[Langs]"},
        {@"stylers.xml", @"stylers.model", NppModelXmlKindStylers, @"[Stylers]"},
    };
}
}  // namespace

void NppInstallUserLangsAndStylers(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (const UserModelFile &f : userModelFiles()) {
        NSString *userPath = NppConfigSubpath(f.user);
        if ([fm fileExistsAtPath:userPath]) continue;
        NSString *modelPath = [[NSBundle mainBundle] pathForResource:f.model ofType:@"xml"];
        if (modelPath && [fm copyItemAtPath:modelPath toPath:userPath error:nil])
            NSLog(@"%@ Copied %@.xml as %@ to %@", f.tag, f.model, f.user, NppConfigDir());
    }

    // Copies made above are current; older ones pick up new model entries.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (const UserModelFile &f : userModelFiles()) {
            NSString *userPath = NppConfigSubpath(f.user);
            NSString *modelPath = [[NSBundle mainBundle] pathForResource:f.model ofType:@"xml"];
            if (modelPath && [[NSFileManager defaultManager] fileExistsAtPath:userPath])
                NppMergeModelXmlFile(userPath, modelPath, f.kind, NO);
        }
    });
}

void NppUpdateUserThemeFromModel(NSString *themePath) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:themePath]) return;
    NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"stylers.model" ofType:@"xml"];
    if (modelPath) NppMergeModelXmlFile(themePath, modelPath, NppModelXmlKindStylers, YES);
}
