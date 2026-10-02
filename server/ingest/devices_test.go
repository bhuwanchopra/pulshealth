package main

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

func TestNewDeviceTokenShape(t *testing.T) {
	seen := map[string]bool{}
	for range 16 {
		tok, err := newDeviceToken()
		if err != nil {
			t.Fatal(err)
		}
		// Same shape as `openssl rand -hex 32`, so the app's token field, QR
		// payloads and the curl examples all stay as they are.
		if len(tok) != 2*deviceTokenBytes {
			t.Fatalf("token %q has length %d, want %d", tok, len(tok), 2*deviceTokenBytes)
		}
		if _, err := hex.DecodeString(tok); err != nil {
			t.Fatalf("token %q is not lowercase hex: %v", tok, err)
		}
		if strings.ToLower(tok) != tok {
			t.Fatalf("token %q is not lowercase", tok)
		}
		if seen[tok] {
			t.Fatalf("token %q drawn twice", tok)
		}
		seen[tok] = true
	}
}

func TestHashTokenIsDeterministicSHA256(t *testing.T) {
	a := hashToken("0123456789abcdef")
	b := hashToken("0123456789abcdef")
	if !bytes.Equal(a, b) {
		t.Fatal("same token hashed to different values")
	}
	if len(a) != 32 {
		t.Fatalf("hash length = %d, want 32 (the schema's CHECK)", len(a))
	}
	// Pinned so a change of hash function cannot silently invalidate every
	// stored token.
	if got := hex.EncodeToString(hashToken("abc")); got !=
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatalf("hashToken(\"abc\") = %s, want the SHA-256 test vector", got)
	}
	if bytes.Equal(hashToken("abc"), hashToken("abd")) {
		t.Fatal("distinct tokens collided")
	}
}

func TestTokenPrefix(t *testing.T) {
	if got := tokenPrefix("0123456789abcdef"); got != "01234567" {
		t.Fatalf("prefix = %q", got)
	}
	if got := tokenPrefix("abc"); got != "abc" {
		t.Fatalf("short prefix = %q", got)
	}
}

func TestParseDevicesArgs(t *testing.T) {
	const user = "6f1c1f1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f"
	ok := []struct {
		args []string
		want devicesCommand
	}{
		{[]string{"list"}, devicesCommand{op: "list"}},
		{[]string{"list", "--all"}, devicesCommand{op: "list", all: true}},
		{[]string{"issue", "--user", user, "--name", "Sean's iPhone"},
			devicesCommand{op: "issue", userID: user, name: "Sean's iPhone"}},
		{[]string{"issue", "--name=Watch", "--user=" + user},
			devicesCommand{op: "issue", userID: user, name: "Watch"}},
		// --url is normalized on the way in; --no-qr is the one flag without a value.
		{[]string{"issue", "--user", user, "--name", "Watch", "--url", "https://health.example.net/", "--no-qr"},
			devicesCommand{op: "issue", userID: user, name: "Watch", url: "https://health.example.net", noQR: true}},
		{[]string{"issue", "--no-qr", "--url=http://192.168.1.20:8080", "--user", user, "--name", "Watch"},
			devicesCommand{op: "issue", userID: user, name: "Watch", url: "http://192.168.1.20:8080", noQR: true}},
		{[]string{"issue", "--user", strings.ToUpper(user), "--name", "Watch"},
			devicesCommand{op: "issue", userID: user, name: "Watch"}},
		{[]string{"revoke", "7"}, devicesCommand{op: "revoke", id: 7}},
		{[]string{"rename", "7", "Old phone"}, devicesCommand{op: "rename", id: 7, name: "Old phone"}},
	}
	for _, c := range ok {
		got, err := parseDevicesArgs(c.args)
		if err != nil {
			t.Fatalf("%v: %v", c.args, err)
		}
		if got != c.want {
			t.Fatalf("%v = %+v, want %+v", c.args, got, c.want)
		}
	}

	bad := [][]string{
		{},
		{"approve", "1"},
		{"list", "--revoked"},
		{"issue"},
		{"issue", "--user", user},
		{"issue", "--name", "x"},
		{"issue", "--user", "not-a-uuid", "--name", "x"},
		{"issue", "--user", user, "--name"},
		{"issue", "--user", user, "--name", strings.Repeat("x", maxDeviceNameLen+1)},
		{"issue", "--user", user, "--name", "x", "--url"},
		{"issue", "--user", user, "--name", "x", "--url", "health.example.net"},
		// The app refuses plain http beyond the local network; so does this.
		{"issue", "--user", user, "--name", "x", "--url", "http://health.example.net"},
		{"issue", "--user", user, "--name", "x", "--no-qr=true"},
		{"revoke"},
		{"revoke", "0"},
		{"revoke", "seven"},
		{"revoke", "1", "2"},
		{"rename", "1"},
		{"rename", "1", strings.Repeat("x", maxDeviceNameLen+1)},
	}
	for _, args := range bad {
		if _, err := parseDevicesArgs(args); err == nil {
			t.Fatalf("%v parsed without error", args)
		}
	}
}

func TestRunDevicesCLIUsageErrorExits2(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := runDevicesCLI([]string{"approve"}, &out, &errOut); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), "usage: ingest devices") {
		t.Fatalf("stderr = %q, want the usage text", errOut.String())
	}
	if out.Len() != 0 {
		t.Fatalf("stdout = %q, want nothing", out.String())
	}
}

func TestPrintDeviceTokens(t *testing.T) {
	var out bytes.Buffer
	printDeviceTokens(&out, nil, false)
	if !strings.Contains(out.String(), "No active device tokens") {
		t.Fatalf("empty listing = %q", out.String())
	}
	out.Reset()
	seen := time.Date(2026, 9, 15, 8, 30, 0, 0, time.UTC)
	printDeviceTokens(&out, []deviceToken{{
		ID: 3, UserID: "6f1c1f1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f", Name: "Phone",
		Status: "active", TokenPrefix: "0123abcd",
		CreatedAt: seen.Add(-24 * time.Hour), LastSeenAt: &seen,
	}}, false)
	for _, want := range []string{"ID", "PREFIX", "0123abcd…", "active", "Phone", "2026-09-15 08:30"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("listing %q lacks %q", out.String(), want)
		}
	}
	// The plaintext never appears anywhere: only its prefix is stored.
	if strings.Contains(out.String(), "0123abcd0") {
		t.Fatal("listing shows more than the prefix")
	}
}

// A PULS_PUBLIC_URL the app would refuse stops `issue` before the database is
// opened — DATABASE_URL is not even set here — so no token is minted for a
// code that could never be scanned.
func TestRunDevicesCLIRejectsBadPublicURLBeforeIssuing(t *testing.T) {
	t.Setenv("PULS_PUBLIC_URL", "http://health.example.net")
	t.Setenv("DATABASE_URL", "")
	var out, errOut bytes.Buffer
	args := []string{"issue", "--user", "6f1c1f1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f", "--name", "Watch"}
	if code := runDevicesCLI(args, &out, &errOut); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "PULS_PUBLIC_URL") || !strings.Contains(errOut.String(), "No token was issued") {
		t.Fatalf("stderr = %q", errOut.String())
	}
	// It is only `issue` that reads it: `list` gets as far as the database.
	errOut.Reset()
	if code := runDevicesCLI([]string{"list"}, &out, &errOut); code != 1 || !strings.Contains(errOut.String(), "DATABASE_URL") {
		t.Fatalf("list: exit %d, stderr %q", code, errOut.String())
	}
}

func TestPrintIssuedPairing(t *testing.T) {
	const (
		user  = "6f1c1f1e-2a3b-4c5d-8e9f-0a1b2c3d4e5f"
		token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
		site  = "https://health.example.net"
	)
	payload := "puls://pair?url=https%3A%2F%2Fhealth.example.net&token=" + token + "&user=" + user
	const once = "This is the only time the token is shown"

	var withQR bytes.Buffer
	printIssuedPairing(&withQR, devicesCommand{op: "issue", url: site}, 3, token, user)
	var code bytes.Buffer
	if err := writeQR(&code, payload); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Server URL  " + site, "Token       " + token, "User ID     " + user,
		code.String(), payload, "scan the QR code", once} {
		if !strings.Contains(withQR.String(), want) {
			t.Fatalf("output lacks %q:\n%s", want, withQR.String())
		}
	}

	var noQR bytes.Buffer
	printIssuedPairing(&noQR, devicesCommand{op: "issue", url: site, noQR: true}, 3, token, user)
	if strings.Contains(noQR.String(), qrColorsOn) || !strings.Contains(noQR.String(), payload) {
		t.Fatalf("--no-qr output should carry the payload and no drawing:\n%s", noQR.String())
	}

	// No URL: the token is already minted, so it is still printed in full,
	// with the way to a code spelled out — and no payload, which would be
	// missing the one field the app cannot do without.
	var noURL bytes.Buffer
	printIssuedPairing(&noURL, devicesCommand{op: "issue"}, 3, token, user)
	for _, want := range []string{token, user, "devices revoke 3", "--issue-device", "--url", "PULS_PUBLIC_URL", once} {
		if !strings.Contains(noURL.String(), want) {
			t.Fatalf("output lacks %q:\n%s", want, noURL.String())
		}
	}
	if strings.Contains(noURL.String(), "puls://pair") || strings.Contains(noURL.String(), qrColorsOn) {
		t.Fatalf("no-URL output should have no pairing code:\n%s", noURL.String())
	}
}
