/**
 * HarmonyOS keyCode -> Windows RDP Set 1 scancode mapping.
 *
 * The numeric keyCode values are kept in sync with RemoteDesktop.ets and
 * rustdesk_ffi/src/connector.rs so physical keys, virtual edit-bar keys and
 * RDP input all speak the same local key namespace.
 */

#ifndef RDP_KEYMAP_H
#define RDP_KEYMAP_H

#include <cstdint>

inline uint32_t mapHarmonyKeyCodeToRdpScancode(uint32_t keyCode) {
    switch (keyCode) {
        // ASCII letters (backwards-compat, keep but prefer Harmony codes below).
        case 65: return 0x1E;  // A
        case 66: return 0x30;  // B
        case 67: return 0x2E;  // C
        case 68: return 0x20;  // D
        case 69: return 0x12;  // E
        case 70: return 0x21;  // F
        case 71: return 0x22;  // G
        case 72: return 0x23;  // H
        case 73: return 0x17;  // I
        case 74: return 0x24;  // J
        case 75: return 0x25;  // K
        case 76: return 0x26;  // L
        case 77: return 0x32;  // M
        case 78: return 0x31;  // N
        case 79: return 0x18;  // O
        case 80: return 0x19;  // P
        case 81: return 0x10;  // Q
        case 82: return 0x13;  // R
        case 83: return 0x1F;  // S
        case 84: return 0x14;  // T
        case 85: return 0x16;  // U
        case 86: return 0x2F;  // V
        case 87: return 0x11;  // W
        case 88: return 0x2D;  // X
        case 89: return 0x15;  // Y
        case 90: return 0x2C;  // Z

        // Harmony A-Z keyCodes (T-172 P0-3: unified namespace).
        case 2017: return 0x1E;  // A
        case 2018: return 0x30;  // B
        case 2019: return 0x2E;  // C
        case 2020: return 0x20;  // D
        case 2021: return 0x12;  // E
        case 2022: return 0x21;  // F
        case 2023: return 0x22;  // G
        case 2024: return 0x23;  // H
        case 2025: return 0x17;  // I
        case 2026: return 0x24;  // J
        case 2027: return 0x25;  // K
        case 2028: return 0x26;  // L
        case 2029: return 0x32;  // M
        case 2030: return 0x31;  // N
        case 2031: return 0x18;  // O
        case 2032: return 0x19;  // P
        case 2033: return 0x10;  // Q
        case 2034: return 0x13;  // R
        case 2035: return 0x1F;  // S
        case 2036: return 0x14;  // T
        case 2037: return 0x16;  // U
        case 2038: return 0x2F;  // V
        case 2039: return 0x11;  // W
        case 2040: return 0x2D;  // X
        case 2041: return 0x15;  // Y
        case 2042: return 0x2C;  // Z

        // ASCII number row.
        case 48: return 0x0B;  // 0
        case 49: return 0x02;  // 1
        case 50: return 0x03;  // 2
        case 51: return 0x04;  // 3
        case 52: return 0x05;  // 4
        case 53: return 0x06;  // 5
        case 54: return 0x07;  // 6
        case 55: return 0x08;  // 7
        case 56: return 0x09;  // 8
        case 57: return 0x0A;  // 9

        // Navigation/control keys from RemoteDesktop.ets.
        case 2012: return 0xE048; // Up
        case 2013: return 0xE050; // Down
        case 2014: return 0xE04B; // Left
        case 2015: return 0xE04D; // Right
        case 2045: return 0x38;   // Left Alt
        case 2046: return 0xE038; // Right Alt
        case 2047: return 0x2A;   // Left Shift
        case 2048: return 0x36;   // Right Shift
        case 2049: return 0x0F;   // Tab
        case 2050: return 0x39;   // Space
        case 2054: return 0x1C;   // Enter
        case 2055: return 0x0E;   // Backspace
        case 2067: return 0xE05D; // Apps/Menu
        case 2068: return 0xE049; // Page Up
        case 2069: return 0xE051; // Page Down
        case 2070: return 0x01;   // Escape
        case 2071: return 0xE053; // Delete
        case 2072: return 0x1D;   // Left Ctrl
        case 2073: return 0xE01D; // Right Ctrl
        case 2076: return 0xE05B; // Left Meta
        case 2077: return 0xE05C; // Right Meta
        case 2079: return 0xE037; // Print Screen / SysRq
        case 2080: return 0x45;   // Pause / Break
        case 2081: return 0xE047; // Home
        case 2082: return 0xE04F; // End
        case 2083: return 0xE052; // Insert

        // Function keys from rustdesk_ffi/src/connector.rs.
        case 2090: return 0x3B; // F1
        case 2091: return 0x3C; // F2
        case 2092: return 0x3D; // F3
        case 2093: return 0x3E; // F4
        case 2094: return 0x3F; // F5
        case 2095: return 0x40; // F6
        case 2096: return 0x41; // F7
        case 2097: return 0x42; // F8
        case 2098: return 0x43; // F9
        case 2099: return 0x44; // F10
        case 2100: return 0x57; // F11
        case 2101: return 0x58; // F12

        // Numpad keys from rustdesk_ffi/src/connector.rs.
        case 2103: return 0x52;   // Numpad 0
        case 2104: return 0x4F;   // Numpad 1
        case 2105: return 0x50;   // Numpad 2
        case 2106: return 0x51;   // Numpad 3
        case 2107: return 0x4B;   // Numpad 4
        case 2108: return 0x4C;   // Numpad 5
        case 2109: return 0x4D;   // Numpad 6
        case 2110: return 0x47;   // Numpad 7
        case 2111: return 0x48;   // Numpad 8
        case 2112: return 0x49;   // Numpad 9
        case 2113: return 0xE035; // Divide
        case 2114: return 0x37;   // Multiply
        case 2115: return 0x4A;   // Subtract
        case 2116: return 0x4E;   // Add
        case 2117: return 0x53;   // Decimal
        case 2119: return 0xE01C; // Numpad Enter
        case 2120: return 0x0D;   // Equals

        // Common symbol keys observed from desktop-style key events.
        case 186: return 0x27; // Semicolon
        case 187: return 0x0D; // Equals
        case 188: return 0x33; // Comma
        case 189: return 0x0C; // Minus
        case 190: return 0x34; // Period
        case 191: return 0x35; // Slash
        case 192: return 0x29; // Backtick
        case 219: return 0x1A; // Left bracket
        case 220: return 0x2B; // Backslash
        case 221: return 0x1B; // Right bracket
        case 222: return 0x28; // Apostrophe

        default:
            return 0;
    }
}

#endif // RDP_KEYMAP_H
