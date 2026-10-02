package main

import (
	"bytes"
	"strings"
	"testing"
)

// A fake token of the real shape (64 hex characters), so the test payload is
// the size a real pairing code is.
const testPairingPayload = "puls://pair?url=https%3A%2F%2Fhealth.example.net" +
	"&token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" +
	"&user=5ea4d000-0000-4000-8000-000000000001"

func stripQRColors(s string) string {
	return strings.NewReplacer(qrColorsOn, "", qrColorsOff, "").Replace(s)
}

// The encoder is deterministic (mask choice included), so the drawing is too.
// A version 1 symbol is small enough to keep in the source: if this changes,
// the dependency changed what it emits and the codes need scanning again.
func TestRenderQRGolden(t *testing.T) {
	const want = "" +
		"█████████████████████████\n" +
		"██ ▄▄▄▄▄ ██ ▀ ▄█ ▄▄▄▄▄ ██\n" +
		"██ █   █ █▄ █ ▄█ █   █ ██\n" +
		"██ █▄▄▄█ ███▄█ █ █▄▄▄█ ██\n" +
		"██▄▄▄▄▄▄▄█ ▀▄▀ █▄▄▄▄▄▄▄██\n" +
		"██▄▄▄▀  ▄▄▄▄ ▄█ ▄█▀█▄█▀██\n" +
		"██▄▄▄ ▀▀▄ ▀▀ █▄█▄▄ ▄▄ ▄██\n" +
		"██▄█▄██▄▄▄  █▀▄▀█ ▀█▀█ ██\n" +
		"██ ▄▄▄▄▄ █ █▀ ▀▄▄█ █▄▄ ██\n" +
		"██ █   █ █▄█▀ █▀▀ ▀ █▀███\n" +
		"██ █▄▄▄█ █  ▄▀ ▄▄▀  █▀▄██\n" +
		"██▄▄▄▄▄▄▄█▄█▄█▄▄███▄█▄▄██\n" +
		"█████████████████████████\n"
	var out bytes.Buffer
	if err := writeQR(&out, "puls://pair"); err != nil {
		t.Fatal(err)
	}
	if got := stripQRColors(out.String()); got != want {
		t.Fatalf("rendering changed:\n%s\nwant:\n%s", got, want)
	}
	// Every row sets its own colours and resets them before the newline:
	// that is what makes the code readable on a light terminal and keeps
	// the background from running to the window edge.
	for i, line := range strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n") {
		if !strings.HasPrefix(line, qrColorsOn) || !strings.HasSuffix(line, qrColorsOff) {
			t.Fatalf("row %d is not wrapped in the colour codes: %q", i, line)
		}
	}
}

// Reads the half blocks back into modules and compares them with the matrix
// the encoder produced: the drawing loses nothing, adds exactly the quiet
// zone, and never paints a dark module into it.
func TestRenderQRRoundTripsTheMatrix(t *testing.T) {
	matrix, err := qrMatrix(testPairingPayload)
	if err != nil {
		t.Fatal(err)
	}
	size := len(matrix)
	if size < 21 || (size-17)%4 != 0 {
		t.Fatalf("matrix is %d modules wide, not a QR symbol size", size)
	}
	var out bytes.Buffer
	if err := renderQR(&out, matrix); err != nil {
		t.Fatal(err)
	}

	var modules [][]bool // true = dark, quiet zone included
	for _, line := range strings.Split(strings.TrimSuffix(stripQRColors(out.String()), "\n"), "\n") {
		var top, bottom []bool
		for _, r := range line {
			switch string(r) {
			case qrBothLight:
				top, bottom = append(top, false), append(bottom, false)
			case qrTopLight:
				top, bottom = append(top, false), append(bottom, true)
			case qrBottomLight:
				top, bottom = append(top, true), append(bottom, false)
			case qrBothDark:
				top, bottom = append(top, true), append(bottom, true)
			default:
				t.Fatalf("unexpected rune %q in the drawing", r)
			}
		}
		modules = append(modules, top, bottom)
	}

	full := size + 2*qrMargin
	// An odd module count leaves the last text row's lower half over.
	if len(modules) != full+full%2 {
		t.Fatalf("drew %d module rows, want %d", len(modules), full+full%2)
	}
	for y, row := range modules {
		if len(row) != full {
			t.Fatalf("row %d is %d modules wide, want %d", y, len(row), full)
		}
		for x, dark := range row {
			mx, my := x-qrMargin, y-qrMargin
			want := mx >= 0 && mx < size && my >= 0 && my < size && matrix[my][mx]
			if dark != want {
				t.Fatalf("module (%d,%d) drawn dark=%v, want %v", mx, my, dark, want)
			}
		}
	}

	// A finder pattern in three corners and not the fourth: the matrix is
	// the right way up and is a QR symbol rather than merely square.
	finder := func(ox, oy int) bool {
		for y := 0; y < 7; y++ {
			for x := 0; x < 7; x++ {
				ring := x == 0 || x == 6 || y == 0 || y == 6
				core := x >= 2 && x <= 4 && y >= 2 && y <= 4
				if matrix[oy+y][ox+x] != (ring || core) {
					return false
				}
			}
		}
		return true
	}
	if !finder(0, 0) || !finder(size-7, 0) || !finder(0, size-7) || finder(size-7, size-7) {
		t.Fatal("finder patterns are not where a QR symbol has them")
	}
}

func TestQRMatrixRejectsEmptyAndOversized(t *testing.T) {
	if _, err := qrMatrix(""); err == nil {
		t.Fatal("empty payload encoded without error")
	}
	if _, err := qrMatrix(strings.Repeat("x", maxQRPayloadBytes)); err != nil {
		t.Fatalf("payload at the limit: %v", err)
	}
	if _, err := qrMatrix(strings.Repeat("x", maxQRPayloadBytes+1)); err == nil {
		t.Fatal("payload past the limit encoded without error")
	}
}

func TestRunQRCLI(t *testing.T) {
	run := func(stdin string, args ...string) (int, string, string) {
		var out, errOut bytes.Buffer
		code := runQRCLI(args, strings.NewReader(stdin), &out, &errOut)
		return code, out.String(), errOut.String()
	}

	var direct bytes.Buffer
	if err := writeQR(&direct, testPairingPayload); err != nil {
		t.Fatal(err)
	}
	// `echo` and a here-string both add a newline; it is not part of the payload.
	for _, stdin := range []string{testPairingPayload, testPairingPayload + "\n", "  " + testPairingPayload + "\r\n"} {
		code, out, errOut := run(stdin)
		if code != 0 || errOut != "" {
			t.Fatalf("stdin %q: exit %d, stderr %q", stdin, code, errOut)
		}
		if out != direct.String() {
			t.Fatalf("stdin %q drew a different code than the bare payload", stdin)
		}
	}

	failures := []struct {
		name  string
		stdin string
		args  []string
		code  int
		want  string
	}{
		{"empty", "", nil, 1, "empty payload"},
		{"whitespace only", " \n", nil, 1, "empty payload"},
		{"one byte over", strings.Repeat("x", maxQRPayloadBytes+1), nil, 1, "limit is 512"},
		{"far over", strings.Repeat("x", 1<<16), nil, 1, "longer than 512"},
		// The payload holds the token; argv is visible in ps.
		{"payload as an argument", "", []string{testPairingPayload}, 2, "usage: ingest qr"},
	}
	for _, c := range failures {
		code, out, errOut := run(c.stdin, c.args...)
		if code != c.code {
			t.Fatalf("%s: exit %d, want %d (stderr %q)", c.name, code, c.code, errOut)
		}
		if !strings.Contains(errOut, c.want) {
			t.Fatalf("%s: stderr %q, want it to mention %q", c.name, errOut, c.want)
		}
		if out != "" {
			t.Fatalf("%s: stdout %q, want nothing", c.name, out)
		}
	}
}
