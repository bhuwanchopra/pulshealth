package main

import (
	"errors"
	"fmt"
	"io"
	"strings"

	qrcode "github.com/skip2/go-qrcode"
)

// `ingest qr`: a terminal QR code of whatever arrives on stdin. It exists so
// pairing never depends on a `qrencode` binary on the host — the image every
// install already has can draw the code — and it is what `devices issue`
// prints a fresh token with. It needs no database and no environment:
//
//	printf '%s' "$payload" | docker compose exec -T ingest /ingest qr
//
// (the image is distroless, so there is no shell to do the piping inside the
// container). The payload is read from stdin and never taken as an argument:
// it carries the bearer token, and argv is readable by every user on the host
// through `ps`.

const qrUsage = `usage: ingest qr < payload

Reads one payload from stdin (at most 512 bytes; surrounding whitespace is
dropped) and prints it as a QR code for a terminal. Takes no arguments: the
pairing payload holds a bearer token, and arguments are visible in ps.
`

// maxQRPayloadBytes bounds what `ingest qr` will draw. A pairing payload is
// about 200 bytes (a version 9 or 10 symbol, under 60 columns); 512 bytes is
// already version 16 — 85 columns with the margin, past what a default
// terminal shows without wrapping, and a wrapped code does not scan.
const maxQRPayloadBytes = 512

// qrMargin is the quiet zone in modules on every side. The standard asks for
// four; two is what `qrencode -m 2` (the renderer this replaces in
// scripts/bootstrap.sh) has always used, and phone cameras read it fine.
const qrMargin = 2

// Two text rows of modules share one terminal row: the upper half block
// carries the top module, the lower half block the bottom one. Light modules
// are drawn in the foreground colour over an explicit dark background — never
// left to the terminal's own colours — so the code has dark-on-light polarity
// and a real light quiet zone on a dark theme and a light theme alike. The
// colours are 256-colour cube entries (231 = #ffffff, 16 = #000000) rather
// than the basic "white" and "black", which themes are free to repaint.
const (
	qrColorsOn  = "\x1b[38;5;231m\x1b[48;5;16m"
	qrColorsOff = "\x1b[0m"

	qrBothLight   = "█"
	qrTopLight    = "▀"
	qrBottomLight = "▄"
	qrBothDark    = " "
)

// qrMatrix encodes payload and returns its modules without a quiet zone:
// matrix[y][x] is true for a dark module. Error correction level L, like
// qrencode's default — a terminal is a clean, undamaged surface, so the
// smaller symbol is worth more than the redundancy.
func qrMatrix(payload string) ([][]bool, error) {
	if payload == "" {
		return nil, errors.New("empty payload")
	}
	if len(payload) > maxQRPayloadBytes {
		return nil, fmt.Errorf("payload is %d bytes; the limit is %d (a larger code does not fit a terminal)",
			len(payload), maxQRPayloadBytes)
	}
	code, err := qrcode.New(payload, qrcode.Low)
	if err != nil {
		return nil, err
	}
	code.DisableBorder = true
	return code.Bitmap(), nil
}

// renderQR draws a module matrix the way `qrencode -t ANSIUTF8 -m 2` does.
// Anything outside the matrix is light, which is both the quiet zone and the
// lower half of the last text row when the row count is odd (it always is: a
// symbol is 4v+17 modules and the margin adds an even number).
func renderQR(w io.Writer, matrix [][]bool) error {
	size := len(matrix)
	dark := func(x, y int) bool {
		return y >= 0 && y < size && x >= 0 && x < len(matrix[y]) && matrix[y][x]
	}
	var b strings.Builder
	for y := -qrMargin; y < size+qrMargin; y += 2 {
		b.WriteString(qrColorsOn)
		for x := -qrMargin; x < size+qrMargin; x++ {
			top, bottom := dark(x, y), dark(x, y+1)
			switch {
			case !top && !bottom:
				b.WriteString(qrBothLight)
			case !top:
				b.WriteString(qrTopLight)
			case !bottom:
				b.WriteString(qrBottomLight)
			default:
				b.WriteString(qrBothDark)
			}
		}
		// Reset before the newline: a background colour still set at the
		// end of a line is smeared to the window edge by some terminals.
		b.WriteString(qrColorsOff)
		b.WriteByte('\n')
	}
	_, err := io.WriteString(w, b.String())
	return err
}

// writeQR is encode-then-draw, shared by `ingest qr` and `devices issue`.
func writeQR(w io.Writer, payload string) error {
	matrix, err := qrMatrix(payload)
	if err != nil {
		return err
	}
	return renderQR(w, matrix)
}

// runQRCLI is main's branch for `ingest qr`; it returns the process exit
// code: 2 on a usage error, 1 on a payload that cannot be drawn.
func runQRCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) > 0 {
		// Not echoed back: if it is a payload, it holds a token.
		fmt.Fprintf(stderr, "ingest qr: takes no arguments\n\n%s", qrUsage)
		return 2
	}
	// Never read an unbounded stream. The slack past the limit is for the
	// whitespace that is trimmed below — `echo`'s newline must not be what
	// tips a full-size payload over — and a read that fills it is too long
	// whatever it ends in.
	const readCap = maxQRPayloadBytes + 64
	raw, err := io.ReadAll(io.LimitReader(stdin, readCap))
	if err != nil {
		fmt.Fprintf(stderr, "ingest qr: reading stdin: %v\n", err)
		return 1
	}
	if len(raw) == readCap {
		fmt.Fprintf(stderr, "ingest qr: payload is longer than %d bytes (a larger code does not fit a terminal)\n", maxQRPayloadBytes)
		return 1
	}
	if err := writeQR(stdout, strings.TrimSpace(string(raw))); err != nil {
		fmt.Fprintf(stderr, "ingest qr: %v\n", err)
		return 1
	}
	return 0
}
