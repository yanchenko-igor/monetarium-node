package main

import (
	"bytes"
	"testing"
	"time"

	"github.com/monetarium/monetarium-node/wire"
)

func TestSeederConversionSkipsInvalidEntries(t *testing.T) {
	timestamp := time.Unix(123, 0)
	valid := wire.NewNetAddressV2(wire.IPv4Address, []byte{8, 8, 8, 8},
		9508, timestamp, wire.SFNodeNetwork)
	invalid := wire.NewNetAddressV2(wire.IPv4Address, []byte{8, 8, 8},
		9508, timestamp, wire.SFNodeNetwork)
	tests := []struct {
		name      string
		entries   []wire.NetAddressV2
		wantCount int
		wantErr   bool
	}{
		{"mixed entries", []wire.NetAddressV2{invalid, valid, invalid}, 1, false},
		{"all invalid", []wire.NetAddressV2{invalid}, 0, true},
		{"empty response", nil, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := seedWireToAddrmgrNetAddressesV2(tt.entries)
			if (err != nil) != tt.wantErr || len(got) != tt.wantCount {
				t.Fatalf("got %d addresses, error %v; want %d, error=%v", len(got), err, tt.wantCount, tt.wantErr)
			}
			if len(got) > 0 && (!bytes.Equal(got[0].IP, valid.EncodedAddr) || got[0].Port != valid.Port || !got[0].Timestamp.Equal(timestamp) || got[0].Services != valid.Services) {
				t.Fatalf("valid entry metadata changed: %+v", got[0])
			}
		})
	}
}
