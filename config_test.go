// Copyright (c) 2018-2024 The Decred developers
// Use of this source code is governed by an ISC
// license that can be found in the LICENSE file.

package main

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMain(m *testing.M) {
	flag.Parse()

	// Trim -test.* flags from the command line arguments list to allow
	// go-flags tests to succeed.
	os.Args = append([]string{os.Args[0]}, flag.Args()...)

	os.Exit(m.Run())
}

// In order to test command line arguments and environment variables, append
// the flags to the os.Args variable like so:
//   os.Args = append(os.Args, "--altdnsnames=\"hostname1,hostname2\"")
//
// For environment variables, use the following to set the variable before the
// func that loads the configuration is called:
//   os.Setenv("MONETARIUM_ALT_DNSNAMES", "hostname1,hostname2")
//
// These args and env variables will then get parsed during configuration load.

// routableOnionAddr is a live Tor v3 onion hostname whose checksum is valid.
// It must decode, so it also guards the checksum computation during config
// loading.
const routableOnionAddr = "xtjxdav6eckeyyar6f2vutmbfdo4ygluxlcswlysnul4sqztjcesuiyd.onion"

// TestLoadConfig ensures that basic configuration loading succeeds.
func TestLoadConfig(t *testing.T) {
	appName := filepath.Base(os.Args[0])
	appName = strings.TrimSuffix(appName, filepath.Ext(appName))
	_, _, err := loadConfig(appName)
	if err != nil {
		t.Fatalf("Failed to load mond config: %s", err)
	}
}

// TestDefaultAltDNSNames ensures that there are no additional hostnames added
// by default during the configuration load phase.
func TestDefaultAltDNSNames(t *testing.T) {
	appName := filepath.Base(os.Args[0])
	appName = strings.TrimSuffix(appName, filepath.Ext(appName))
	cfg, _, err := loadConfig(appName)
	if err != nil {
		t.Fatalf("Failed to load mond config: %s", err)
	}
	if len(cfg.AltDNSNames) != 0 {
		t.Fatalf("Invalid default value for altdnsnames: %s", cfg.AltDNSNames)
	}
}

// TestAltDNSNamesWithEnv ensures the MONETARIUM_ALT_DNSNAMES environment variable is
// parsed into a slice of additional hostnames as intended.
func TestAltDNSNamesWithEnv(t *testing.T) {
	appName := filepath.Base(os.Args[0])
	appName = strings.TrimSuffix(appName, filepath.Ext(appName))
	t.Setenv("MONETARIUM_ALT_DNSNAMES", "hostname1,hostname2")
	cfg, _, err := loadConfig(appName)
	if err != nil {
		t.Fatalf("Failed to load mond config: %s", err)
	}
	hostnames := strings.Join(cfg.AltDNSNames, ",")
	if hostnames != "hostname1,hostname2" {
		t.Fatalf("altDNSNames should be %s but was %s", "hostname1,hostname2",
			hostnames)
	}
}

// TestAltDNSNamesWithArg ensures the altdnsnames configuration option parses
// additional hostnames into a slice of hostnames as intended.
func TestAltDNSNamesWithArg(t *testing.T) {
	appName := filepath.Base(os.Args[0])
	appName = strings.TrimSuffix(appName, filepath.Ext(appName))
	old := os.Args
	os.Args = append(os.Args, "--altdnsnames=\"hostname1,hostname2\"")
	cfg, _, err := loadConfig(appName)
	if err != nil {
		t.Fatalf("Failed to load mond config: %s", err)
	}
	hostnames := strings.Join(cfg.AltDNSNames, ",")
	if hostnames != "hostname1,hostname2" {
		t.Fatalf("altDNSNames should be %s but was %s", "hostname1,hostname2",
			hostnames)
	}
	os.Args = old
}

// TestOnionAddrConfig ensures the --onionaddr option is validated up front.
func TestOnionAddrConfig(t *testing.T) {
	appName := filepath.Base(os.Args[0])
	appName = strings.TrimSuffix(appName, filepath.Ext(appName))
	const wantExternal = routableOnionAddr

	tests := []struct {
		name      string
		args      []string
		wantErr   bool
		wantAddr  string
		wantOnion bool
	}{{
		name:      "valid onion address with port",
		args:      []string{"--onionaddr=" + wantExternal + ":9508"},
		wantAddr:  wantExternal + ":9508",
		wantOnion: true,
	}, {
		name:      "valid onion address without port uses the default",
		args:      []string{"--onionaddr=" + wantExternal},
		wantAddr:  wantExternal + ":9508",
		wantOnion: true,
	}, {
		name:    "hostname without onion suffix",
		args:    []string{"--onionaddr=www.example.com:9508"},
		wantErr: true,
	}, {
		name:    "onion hostname with a bad checksum",
		args:    []string{"--onionaddr=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.onion:9508"},
		wantErr: true,
	}, {
		name:    "onion address combined with noonion",
		args:    []string{"--onionaddr=" + wantExternal + ":9508", "--noonion"},
		wantErr: true,
	}}

	for i, test := range tests {
		oldArgs := os.Args
		os.Args = append(os.Args, test.args...)
		cfg, _, err := loadConfig(appName)
		os.Args = oldArgs

		if test.wantErr {
			if err == nil {
				t.Errorf("test %d %q: expected an error, got nil", i, test.name)
			}
			continue
		}
		if err != nil {
			t.Errorf("test %d %q: unexpected error: %v", i, test.name, err)
			continue
		}
		if cfg.OnionAddr != test.wantAddr {
			t.Errorf("test %d %q: unexpected onion address -- got %q, want %q",
				i, test.name, cfg.OnionAddr, test.wantAddr)
		}
		if test.wantOnion && !cfg.onionNetInfo.Reachable {
			t.Errorf("test %d %q: expected onion network to be reachable", i,
				test.name)
		}
	}
}
