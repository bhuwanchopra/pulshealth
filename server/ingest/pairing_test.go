package main

import (
	"net/url"
	"testing"
)

func TestPairingPayload(t *testing.T) {
	const user = "5ea4d000-0000-4000-8000-000000000001"
	// Byte for byte what scripts/bootstrap.sh builds for the same values.
	got := pairingPayload("http://192.168.1.20:8080", "abc123", user)
	want := "puls://pair?url=http%3A%2F%2F192.168.1.20%3A8080&token=abc123&user=" + user
	if got != want {
		t.Fatalf("payload = %q, want %q", got, want)
	}

	// Everything outside the unreserved set is escaped, a space as %20 and
	// never "+": the app's parser does not turn a plus back into a space.
	if got := pairingEscape("a b+c/d?e&f=g~h_i-j.k%"); got != "a%20b%2Bc%2Fd%3Fe%26f%3Dg~h_i-j.k%25" {
		t.Fatalf("pairingEscape = %q", got)
	}
	if got := pairingEscape("é"); got != "%C3%A9" {
		t.Fatalf("pairingEscape(é) = %q, want upper-case UTF-8 bytes", got)
	}

	// And a standard URL parser gets the three values back unchanged.
	const serverURL, token = "https://health.example.net/puls", "t0k+en &more"
	u, err := url.Parse(pairingPayload(serverURL, token, user))
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "puls" || u.Host != "pair" {
		t.Fatalf("scheme/host = %q/%q", u.Scheme, u.Host)
	}
	// url.ParseQuery would read "+" as a space; the payload has none to read.
	q := u.Query()
	if q.Get("url") != serverURL || q.Get("token") != token || q.Get("user") != user {
		t.Fatalf("round trip = %v", q)
	}
}

func TestNormalizePairingURL(t *testing.T) {
	ok := map[string]string{
		"https://health.example.net":         "https://health.example.net",
		"https://health.example.net/":        "https://health.example.net",
		" https://health.example.net/puls/ ": "https://health.example.net/puls",
		"HTTPS://health.example.net":         "HTTPS://health.example.net",
		"http://192.168.1.20:8080":           "http://192.168.1.20:8080",
		"http://10.0.0.5:8080/":              "http://10.0.0.5:8080",
		"http://172.16.0.1:8080":             "http://172.16.0.1:8080",
		"http://169.254.10.10:8080":          "http://169.254.10.10:8080",
		"http://nas.local:8080":              "http://nas.local:8080",
		"http://localhost:8080":              "http://localhost:8080",
		"http://[fd00::1]:8080":              "http://[fd00::1]:8080",
		"http://[::1]:8080":                  "http://[::1]:8080",
	}
	for in, want := range ok {
		got, err := normalizePairingURL(in)
		if err != nil {
			t.Fatalf("%q: %v", in, err)
		}
		if got != want {
			t.Fatalf("%q normalized to %q, want %q", in, got, want)
		}
	}

	bad := []string{
		"",
		"   ",
		"health.example.net",
		"health.example.net:8080",
		"ftp://health.example.net",
		"puls://pair",
		"https://",
		// Plain http beyond the local network: the app's ATS exception does
		// not cover it, so the scanner would refuse the code.
		"http://health.example.net",
		"http://8.8.8.8:8080",
		"http://172.32.0.1:8080",
		"http://192.169.1.1:8080",
		"http://[2001:db8::1]:8080",
	}
	for _, in := range bad {
		if got, err := normalizePairingURL(in); err == nil {
			t.Fatalf("%q accepted as %q", in, got)
		}
	}
}
