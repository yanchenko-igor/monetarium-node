// Copyright (c) 2026 The Monetarium developers
// Use of this source code is governed by an ISC
// license that can be found in the LICENSE file.

package connmgr

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/monetarium/monetarium-node/wire"
)

// testCert is a self-signed certificate that serves as both the TLS server
// certificate and the trusted root for the HTTPS test servers below.
var testCert tls.Certificate

// TestMain installs the test root certificate into the process-wide system root
// pool.  SeedAddrs builds its own HTTP client with a TLS config it does not
// expose, so the only way for the default client to trust a test server is to
// make the root trusted by the system pool.
//
// The root pool is loaded once per process and caches on first use, so this has
// to happen here rather than in an individual test.
func TestMain(m *testing.M) {
	if err := setupTestTLS(); err != nil {
		fmt.Fprintf(os.Stderr, "unable to set up test TLS: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// setupTestTLS generates the test certificate and writes it to a temporary file
// that the system root pool is then pointed at via SSL_CERT_FILE.
func setupTestTLS() error {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "monetarium connmgr test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              []string{"localhost"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1"),
			net.ParseIP("::1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template,
		&privKey.PublicKey, privKey)
	if err != nil {
		return err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return err
	}
	testCert = tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  privKey,
		Leaf:        leaf,
	}

	dir, err := os.MkdirTemp("", "mond-seedtest")
	if err != nil {
		return err
	}
	certPath := filepath.Join(dir, "ca.pem")
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		return err
	}
	return os.Setenv("SSL_CERT_FILE", certPath)
}

// newSeedTestServer returns an HTTPS test server that replies with the provided
// JSON body along with a pointer to the query of the most recent request.
func newSeedTestServer(t *testing.T, body string) (*httptest.Server, *url.Values) {
	t.Helper()

	var gotQuery url.Values
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter,
		r *http.Request) {

		gotQuery = r.URL.Query()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}))
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{testCert},
		MinVersion:   tls.VersionTLS12,
	}
	server.StartTLS()
	t.Cleanup(server.Close)

	return server, &gotQuery
}

// TestSeedAddrsFilters ensures the requested filters are forwarded to the seeder
// as query parameters.  In particular, the full address set must only be
// requested when the caller explicitly asks for it, because seeders omit every
// address that is not an IP address from the reduced set.
func TestSeedAddrsFilters(t *testing.T) {
	const respBody = `{"host":"127.0.0.1:9508","services":1,"pver":13}`

	tests := []struct {
		name       string
		filters    []func(f *HttpsSeederFilters)
		wantFull   string
		wantSvcs   string
		wantSvcsOK bool
	}{
		{
			name:     "no filters requests nothing",
			filters:  nil,
			wantFull: "",
		},
		{
			name: "services filter does not request full set",
			filters: []func(f *HttpsSeederFilters){
				SeedFilterServices(wire.SFNodeNetwork),
			},
			wantFull:   "",
			wantSvcs:   "1",
			wantSvcsOK: true,
		},
		{
			name: "full filter requests the full set",
			filters: []func(f *HttpsSeederFilters){
				SeedFilterFull(),
			},
			wantFull: "1",
		},
		{
			name: "full filter composes with services filter",
			filters: []func(f *HttpsSeederFilters){
				SeedFilterServices(wire.SFNodeNetwork),
				SeedFilterFull(),
			},
			wantFull:   "1",
			wantSvcs:   "1",
			wantSvcsOK: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server, gotQuery := newSeedTestServer(t, respBody)
			addr := strings.TrimPrefix(server.URL, "https://")
			dialer := &net.Dialer{}

			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()

			addrs, err := SeedAddrs(ctx, addr, dialer.DialContext,
				test.filters...)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(addrs) != 1 {
				t.Fatalf("expected 1 address, got %d", len(addrs))
			}

			if got := (*gotQuery).Get("full"); got != test.wantFull {
				t.Errorf("unexpected full param: got %q, want %q", got,
					test.wantFull)
			}

			if test.wantSvcsOK {
				got := (*gotQuery).Get("services")
				if got != test.wantSvcs {
					t.Errorf("unexpected services param: got %q, want %q", got,
						test.wantSvcs)
				}
			}
		})
	}
}

func TestSeedAddrsReturnsTorV3OnionAddress(t *testing.T) {
	const respBody = `{"host":"xtjxdav6eckeyyar6f2vutmbfdo4ygluxlcswlysnul4sqztjcesuiyd.onion:9508","services":1,"pver":13}`

	server, _ := newSeedTestServer(t, respBody)
	addr := strings.TrimPrefix(server.URL, "https://")
	dialer := &net.Dialer{}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	addrs, err := SeedAddrs(ctx, addr, dialer.DialContext, SeedFilterFull())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(addrs) != 1 {
		t.Fatalf("expected onion address, got %d addresses", len(addrs))
	}
	if addrs[0].Type != wire.TorV3Address {
		t.Fatalf("unexpected address type: got %v, want TorV3", addrs[0].Type)
	}
	if len(addrs[0].EncodedAddr) != 32 {
		t.Fatalf("unexpected onion payload length: got %d, want 32",
			len(addrs[0].EncodedAddr))
	}
}
