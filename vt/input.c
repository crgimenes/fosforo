#include "utf8.h"
#include "vt.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

__attribute__((format(printf, 2, 3))) static size_t fmt(uint8_t *out, const char *f, ...) {
    char buf[VT_INPUT_MAX];
    va_list ap;
    va_start(ap, f);
    int n = vsnprintf(buf, sizeof(buf), f, ap);
    va_end(ap);
    if (n <= 0 || (size_t)n >= sizeof(buf)) {
        return 0;
    }
    memcpy(out, buf, (size_t)n);
    return (size_t)n;
}

/* xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). */
static int mod_param(uint32_t mods) {
    return 1 + (int)(mods & (VT_MOD_SHIFT | VT_MOD_ALT | VT_MOD_CTRL));
}

/* Cursor-style keys: CSI letter, SS3 letter under DECCKM, CSI 1;m letter
   with modifiers. */
static size_t letter_key(char c, uint32_t mods, int ss3_ok, uint8_t *out) {
    if (mods != 0) {
        return fmt(out, "\x1b[1;%d%c", mod_param(mods), c);
    }
    if (ss3_ok) {
        return fmt(out, "\x1bO%c", c);
    }
    return fmt(out, "\x1b[%c", c);
}

static size_t tilde_key(int code, uint32_t mods, uint8_t *out) {
    if (mods != 0) {
        return fmt(out, "\x1b[%d;%d~", code, mod_param(mods));
    }
    return fmt(out, "\x1b[%d~", code);
}

static size_t with_alt(uint32_t mods, const char *s, uint8_t *out) {
    size_t n = 0;
    if ((mods & VT_MOD_ALT) != 0) {
        out[n] = 0x1B;
        n++;
    }
    size_t len = strlen(s);
    memcpy(out + n, s, len);
    return n + len;
}

size_t vt_key(const vt *t, int key, uint32_t mods, uint8_t *out) {
    static const char cursor_letters[] = "ABCDHF";
    static const int f5_codes[] = {15, 17, 18, 19, 20, 21, 23, 24};
    uint32_t modes = vt_modes(t);
    int app_cursor = (modes & VT_MODE_CURSOR_KEYS) != 0;
    if (key >= VT_KEY_UP && key <= VT_KEY_END) {
        return letter_key(cursor_letters[key - VT_KEY_UP], mods, app_cursor, out);
    }
    if (key >= VT_KEY_F1 && key < VT_KEY_F1 + 4) {
        return letter_key((char)('P' + (key - VT_KEY_F1)), mods, 1, out);
    }
    if (key >= VT_KEY_F1 + 4 && key <= VT_KEY_F12) {
        return tilde_key(f5_codes[key - VT_KEY_F1 - 4], mods, out);
    }
    switch (key) {
    case VT_KEY_INSERT:
        return tilde_key(2, mods, out);
    case VT_KEY_DELETE:
        return tilde_key(3, mods, out);
    case VT_KEY_PAGE_UP:
        return tilde_key(5, mods, out);
    case VT_KEY_PAGE_DOWN:
        return tilde_key(6, mods, out);
    case VT_KEY_KP_ENTER:
        if ((modes & VT_MODE_KEYPAD) != 0) {
            return with_alt(mods, "\x1bOM", out);
        }
        return with_alt(mods, (modes & VT_MODE_NEWLINE) != 0 ? "\r\n" : "\r", out);
    case VT_KEY_ENTER:
        return with_alt(mods, (modes & VT_MODE_NEWLINE) != 0 ? "\r\n" : "\r", out);
    case VT_KEY_TAB:
        if ((mods & VT_MOD_SHIFT) != 0) {
            return with_alt(mods, "\x1b[Z", out);
        }
        return with_alt(mods, "\t", out);
    case VT_KEY_BACKSPACE:
        return with_alt(mods, (mods & VT_MOD_CTRL) != 0 ? "\b" : "\x7f", out);
    case VT_KEY_ESCAPE:
        return with_alt(mods, "\x1b", out);
    default:
        return 0;
    }
}

static int ctrl_code(uint32_t cp) {
    if (cp >= 'a' && cp <= 'z') {
        return (int)(cp - 'a' + 1);
    }
    if (cp >= '@' && cp <= '_') {
        return (int)(cp - '@');
    }
    if (cp >= '3' && cp <= '7') {
        return (int)(0x1B + (cp - '3'));
    }
    switch (cp) {
    case ' ':
    case '2':
        return 0;
    case '8':
    case '?':
        return 0x7F;
    case '/':
        return 0x1F;
    default:
        return -1;
    }
}

size_t vt_text(const vt *t, uint32_t cp, uint32_t mods, uint8_t *out) {
    (void)t;
    size_t n = 0;
    if ((mods & VT_MOD_ALT) != 0) {
        out[n] = 0x1B;
        n++;
    }
    if ((mods & VT_MOD_CTRL) != 0) {
        int c = ctrl_code(cp);
        if (c >= 0) {
            out[n] = (uint8_t)c;
            return n + 1;
        }
    }
    return n + utf8_encode(out + n, cp);
}

/* Legacy X10 byte: value + 32, or a 2-byte UTF-8 sequence under mode 1005. */
static size_t mouse_byte(uint8_t *out, int v, int utf8) {
    v += 32;
    if (v < 128 || (!utf8 && v < 256)) {
        out[0] = (uint8_t)v;
        return 1;
    }
    return utf8_encode(out, (uint32_t)v);
}

size_t vt_mouse(const vt *t, int event, int button, int row, int col, uint32_t mods, uint8_t *out) {
    uint32_t m = vt_modes(t);
    uint32_t tracking =
        m & (VT_MODE_MOUSE_X10 | VT_MODE_MOUSE_BUTTON | VT_MODE_MOUSE_DRAG | VT_MODE_MOUSE_ANY);
    if (tracking == 0 || row < 0 || col < 0 || button < 0 || button > VT_BUTTON_WHEEL_RIGHT) {
        return 0;
    }
    int wheel = button >= VT_BUTTON_WHEEL_UP;
    if (event == VT_MOUSE_MOTION && (m & VT_MODE_MOUSE_ANY) == 0 &&
        ((m & VT_MODE_MOUSE_DRAG) == 0 || button == VT_BUTTON_NONE)) {
        return 0;
    }
    if ((m & VT_MODE_MOUSE_X10) != 0) {
        if (event != VT_MOUSE_PRESS) {
            return 0;
        }
        mods = 0;
    }
    if (event == VT_MOUSE_RELEASE && wheel) {
        return 0;
    }
    int sgr = (m & VT_MODE_MOUSE_SGR) != 0;
    int code = wheel ? 64 + (button - VT_BUTTON_WHEEL_UP) : button;
    if (event == VT_MOUSE_RELEASE && !sgr) {
        code = 3;
    }
    if (event == VT_MOUSE_MOTION) {
        code += 32;
    }
    if ((mods & VT_MOD_SHIFT) != 0) {
        code += 4;
    }
    if ((mods & VT_MOD_ALT) != 0) {
        code += 8;
    }
    if ((mods & VT_MOD_CTRL) != 0) {
        code += 16;
    }
    int x = col + 1;
    int y = row + 1;
    if (sgr) {
        char buf[VT_INPUT_MAX];
        int n = snprintf(buf, sizeof(buf), "\x1b[<%d;%d;%d%c", code, x, y,
                         event == VT_MOUSE_RELEASE ? 'm' : 'M');
        if (n <= 0 || (size_t)n >= sizeof(buf)) {
            return 0;
        }
        memcpy(out, buf, (size_t)n);
        return (size_t)n;
    }
    if ((m & VT_MODE_MOUSE_URXVT) != 0) {
        char buf[VT_INPUT_MAX];
        int n = snprintf(buf, sizeof(buf), "\x1b[%d;%d;%dM", code + 32, x, y);
        if (n <= 0 || (size_t)n >= sizeof(buf)) {
            return 0;
        }
        memcpy(out, buf, (size_t)n);
        return (size_t)n;
    }
    int utf8 = (m & VT_MODE_MOUSE_UTF8) != 0;
    int limit = utf8 ? 2015 : 223;
    if (x > limit || y > limit) {
        return 0;
    }
    memcpy(out, "\x1b[M", 3);
    size_t n = 3;
    n += mouse_byte(out + n, code, utf8);
    n += mouse_byte(out + n, x, utf8);
    n += mouse_byte(out + n, y, utf8);
    return n;
}

size_t vt_focus(const vt *t, int focused, uint8_t *out) {
    if ((vt_modes(t) & VT_MODE_FOCUS) == 0) {
        return 0;
    }
    memcpy(out, focused ? "\x1b[I" : "\x1b[O", 3);
    return 3;
}

size_t vt_paste(const vt *t, const uint8_t *text, size_t len, uint8_t *out) {
    int bracketed = (vt_modes(t) & VT_MODE_BRACKETED_PASTE) != 0;
    size_t n = 0;
    if (bracketed) {
        memcpy(out, "\x1b[200~", 6);
        n = 6;
    }
    for (size_t i = 0; i < len; i++) {
        uint8_t b = text[i];
        if (b == '\r' && i + 1 < len && text[i + 1] == '\n') {
            i++;
        }
        if (b == '\n') {
            b = '\r';
        }
        if (bracketed && b == 0x1B) {
            continue;
        }
        out[n] = b;
        n++;
    }
    if (bracketed) {
        memcpy(out + n, "\x1b[201~", 6);
        n += 6;
    }
    return n;
}
