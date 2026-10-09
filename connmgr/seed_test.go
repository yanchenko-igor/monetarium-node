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
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/monetarium/monetarium-node/wire"
)

// newSeedTestTLS creates a self-signed certificate along with a pool that
// trusts it.  The certificate serves as both the TLS server certificate and the
// root for the HTTPS test servers below.
func newSeedTestTLS(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("unable to generate test key: %v", err)
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
		t.Fatalf("unable to create test certificate: %v", err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("unable to parse test certificate: %v", err)
	}
	cert := tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  privKey,
		Leaf:        leaf,
	}

	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return cert, pool
}

// newSeedTestServer returns an HTTPS test server that replies with the provided
// JSON body, a pointer to the query of the most recent request, and the pool of
// roots that trusts it.
func newSeedTestServer(t *testing.T, body string) (*httptest.Server, *url.Values, *x509.CertPool) {
	t.Helper()

	cert, roots := newSeedTestTLS(t)

	var gotQuery url.Values
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter,
		r *http.Request) {

		gotQuery = r.URL.Query()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}))
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}
	server.StartTLS()
	t.Cleanup(server.Close)

	return server, &gotQuery, roots
}

// seedTLSConfig returns a TLS configuration that trusts only the roots of the
// provided test server.
func seedTLSConfig(roots *x509.CertPool) func(f *HttpsSeederFilters) {
	return SeedTLSConfig(&tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12})
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
			server, gotQuery, roots := newSeedTestServer(t, respBody)
			addr := strings.TrimPrefix(server.URL, "https://")
			dialer := &net.Dialer{}

			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()

			filters := append([]func(f *HttpsSeederFilters){
				seedTLSConfig(roots),
			}, test.filters...)
			addrs, err := SeedAddrs(ctx, addr, dialer.DialContext,
				filters...)
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

	server, _, roots := newSeedTestServer(t, respBody)
	addr := strings.TrimPrefix(server.URL, "https://")
	dialer := &net.Dialer{}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	addrs, err := SeedAddrs(ctx, addr, dialer.DialContext,
		SeedFilterFull(), seedTLSConfig(roots))
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
