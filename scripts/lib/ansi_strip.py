"""Streaming ECMA-48 ANSI/escape-sequence stripper.

Implements the grammar documented in the research corpus entry:
  ai/research/shell-scripting/terminal-transcript-capture-strip-ansi-at-write-time-
  and-decouple-stall-detection-from-transcript-bytes.md

Grammar (ECMA-48 5th ed., clauses 5.4 and 5.6; console_codes(4) for non-CSI Fe forms):
  - CSI sequence: ESC '[' (or 0x9B) then parameter bytes 0x30-0x3F, then intermediate
    bytes 0x20-0x2F, then a final byte 0x40-0x7E.
  - Control strings (DCS/SOS/OSC/PM/APC): ESC followed by one of 'P X ] ^ _' (or the
    8-bit C1 equivalents), running until a String Terminator: ESC '\\' (ST), or BEL
    (0x07, xterm's non-ECMA-48 OSC terminator), or 0x9C.
  - Other two-byte Fe escapes (ESC + final byte 0x40-0x5F) EXCLUDING the string
    openers '[ ] P X ^ _' above, e.g. ESC 'M' (reverse index), ESC '=' , ESC '>' .
  - console_codes(4) three-byte forms: ESC '(' X, ESC ')' X, ESC '%' X, ESC '#' X
    (charset selection / line-size commands) -- one intermediate byte then one
    final byte, i.e. ESC + 0x28/0x29/0x25/0x23 + any single following byte.
  - Bare single-byte Fp/Fs forms without a following byte requirement are covered
    by the two-byte Fe rule above (ESC '7', ESC '8', ESC 'c', ESC 'D', ESC 'E',
    ESC 'H', ESC 'Z' all consume exactly ESC + 1 byte).

Trap avoided (documented in the corpus): the two-byte Fe rule must NOT match
ESC + '[' / ']' / 'P' / 'X' / '^' / '_' -- those are string/CSI openers with
their own (longer, differently-terminated) grammar. A rule written as
`ESC [\\x30-\\x7e]` matching everything including those openers will mis-strip
a partial OSC straddling a chunk boundary and leak its payload as text.

This module is a byte-level state machine, not a single regex pass over a
whole buffer, so it is correct when a control sequence straddles a chunk
boundary: incomplete sequences at the end of a chunk are held back (bounded)
and completed on the next chunk.
"""

from __future__ import annotations

ESC = 0x1B
BEL = 0x07

# NOTE: ECMA-48 also defines 8-bit C1 equivalents (0x9B for CSI, 0x9C for ST).
# They are DELIBERATELY NOT recognized here. Captured waspflow transcripts are
# UTF-8 text interleaved with 7-bit (ESC-prefixed) escape sequences, and 0x9B/
# 0x9C collide with ordinary UTF-8 continuation bytes (0x80-0xBF) -- e.g. the
# 3-byte UTF-8 encoding of U+2733 is 0xE2 0x9C 0xB3, whose middle byte is
# 0x9C. Treating 0x9C as a bare 8-bit ST mid-string truncates the UTF-8
# sequence and leaks the trailing continuation byte(s) as literal output.
# Reproduced on a real transcript: an OSC-0 title containing "\xe2\x9c\xb3"
# (a glyph) was mis-terminated at the embedded 0x9C, leaking "\xb3 <rest of
# title>\x07" as visible text. No 7-bit-ESC-prefixed sequence in any measured
# sample used the 8-bit forms, so this rule has zero cost on real captures.

CSI_PARAM_LO, CSI_PARAM_HI = 0x30, 0x3F
CSI_INTER_LO, CSI_INTER_HI = 0x20, 0x2F
CSI_FINAL_LO, CSI_FINAL_HI = 0x40, 0x7E

# Fe finals that open a *string* (their own longer grammar, not a bare 2-byte escape).
STRING_OPENERS = {ord("P"), ord("X"), ord("]"), ord("^"), ord("_"), ord("[")}

# console_codes(4) charset-select / line-size introducers: ESC + this + 1 more byte.
THREE_BYTE_INTRO = {ord("("), ord(")"), ord("%"), ord("#")}

# Holdback cap: if a state machine ends a chunk mid-sequence and the tail grows
# past this without resolving, it is not a well-formed sequence (or the grammar
# doesn't cover it -- console_codes(4) warns Linux private sequences can be
# non-standard). Fail safe: flush the raw holdback as literal text rather than
# stalling forever or blocking unboundedly on one adversarial/corrupt input.
MAX_HOLDBACK = 8192


class AnsiStripper:
    """Incremental ANSI stripper. Feed bytes via .feed(chunk), then .finish()."""

    # states
    _TEXT = 0
    _ESC = 1  # saw ESC, waiting to classify
    _CSI_PARAM = 2  # inside CSI parameter/intermediate bytes
    _STR = 3  # inside a control string (OSC/DCS/SOS/PM/APC), waiting for ST/BEL
    _STR_ESC = 4  # inside a control string, just saw ESC (maybe start of ST)
    _THREE_BYTE = 5  # ESC + one of ()%# , waiting for the final byte

    def __init__(self) -> None:
        self._state = self._TEXT
        self._pending: bytearray = bytearray()  # bytes consumed but not yet emitted
        self._out: bytearray = bytearray()
        self._str_allows_bel = False  # set when entering _STR; True only for OSC

    def feed(self, chunk: bytes) -> bytes:
        out = self._out
        out.clear()
        state = self._state
        pending = self._pending

        for b in chunk:
            if state == self._TEXT:
                if b == ESC:
                    state = self._ESC
                    pending.append(b)
                else:
                    out.append(b)

            elif state == self._ESC:
                pending.append(b)
                if b == ord("["):
                    state = self._CSI_PARAM
                elif b in (ord("P"), ord("X"), ord("]"), ord("^"), ord("_")):
                    # BEL is only a valid terminator for OSC (ESC ]) per xterm;
                    # DCS/SOS/PM/APC embed arbitrary nested bytes (e.g. tmux's
                    # DCS passthrough "\ePtmux;...\e\\") and must run to a
                    # literal ST (ESC \\) only, or an embedded BEL would
                    # truncate the payload early.
                    self._str_allows_bel = (b == ord("]"))
                    state = self._STR
                elif b in THREE_BYTE_INTRO:
                    state = self._THREE_BYTE
                elif CSI_FINAL_LO <= b <= 0x5F and b not in STRING_OPENERS:
                    # two-byte Fe escape (e.g. ESC M, ESC =, ESC >), complete now
                    pending.clear()
                    state = self._TEXT
                elif 0x30 <= b <= 0x3F or 0x60 <= b <= 0x7E:
                    # Fp (0x30-0x3F, e.g. ESC 7 / ESC 8) and Fs (0x60-0x7E, e.g. ESC c)
                    # both complete as a bare two-byte escape.
                    pending.clear()
                    state = self._TEXT
                else:
                    # Not a recognized second byte (e.g. control char, or a byte
                    # this grammar doesn't cover). Fail safe: this ESC did not
                    # start a sequence we understand -- drop just the ESC (it is
                    # never legitimate printable text) and reprocess b as text.
                    pending.clear()
                    state = self._TEXT
                    if b == ESC:
                        state = self._ESC
                        pending.append(b)
                    else:
                        out.append(b)

            elif state == self._CSI_PARAM:
                pending.append(b)
                if CSI_FINAL_LO <= b <= CSI_FINAL_HI:
                    pending.clear()
                    state = self._TEXT
                # else: still consuming params/intermediates (0x20-0x3F) or, per
                # console_codes(4)'s warning that some sequences don't follow
                # ECMA-48, any other byte -- stay in CSI_PARAM and let the
                # holdback cap fail safe rather than mis-terminate.

            elif state == self._THREE_BYTE:
                # ESC + ( ) % # + exactly one more byte completes the sequence.
                pending.append(b)
                pending.clear()
                state = self._TEXT

            elif state == self._STR:
                pending.append(b)
                if b == BEL and self._str_allows_bel:
                    pending.clear()
                    state = self._TEXT
                elif b == ESC:
                    state = self._STR_ESC
                # else: any other byte, including a BEL that doesn't terminate
                # here (DCS/SOS/PM/APC) or a byte that numerically collides
                # with a C1 control (e.g. a UTF-8 continuation byte), stays
                # inside the string body -- only ESC \\ (ST) or, for OSC only,
                # BEL can end it.

            elif state == self._STR_ESC:
                pending.append(b)
                if b == ord("\\"):
                    # ST = ESC \\
                    pending.clear()
                    state = self._TEXT
                else:
                    # Not a terminator; still inside the control string.
                    state = self._STR

            if state != self._TEXT and len(pending) > MAX_HOLDBACK:
                # Fail safe: this doesn't look like a real sequence (or the
                # grammar doesn't cover it). Flush the holdback as literal text
                # rather than holding it, or the whole rest of the file, hostage.
                out.extend(pending)
                pending.clear()
                state = self._TEXT

        self._state = state
        return bytes(out)

    def finish(self) -> bytes:
        """Call after the last feed(). Flushes any incomplete trailing sequence
        as literal text (it never resolved, so it is not a real escape sequence
        we can safely discard -- fail safe by keeping the bytes visible)."""
        out = bytes(self._pending)
        self._pending = bytearray()
        self._state = self._TEXT
        return out


def strip_bytes(data: bytes) -> bytes:
    """Whole-buffer convenience wrapper (used for verification / small inputs)."""
    s = AnsiStripper()
    return s.feed(data) + s.finish()
