// Copyright (c) 2016 The btcsuite developers
// Copyright (c) 2019-2024 The Decred developers
// Use of this source code is governed by an ISC
// license that can be found in the LICENSE file.

package connmgr

import (
	"context"
	"encoding/base32"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/monetarium/monetarium-node/crypto/rand"
	"github.com/monetarium/monetarium-node/wire"
	"golang.org/x/crypto/sha3"
)

const (
	// These constants are used by the seed code to pick a random last
	// seen time.
	duration3Days = 24 * time.Hour * 3
	duration4Days = 24 * time.Hour * 4
)

// DialFunc is the signature of the Dialer function.
type DialFunc func(context.Context, string, string) (net.Conn, error)

// HttpsSeederFilters houses filter parameters for use when making a request to
// an HTTPS seeder.  It can be configured via the various exported functions
// that start with the prefix SeedFilter.
type HttpsSeederFilters struct {
	ipVersion    uint16
	hasIPVersion bool
	pver         uint32
	hasPver      bool
	services     wire.ServiceFlag
	hasServices  bool
	full         bool
}

// SeedFilterIPVersion configures a request to an HTTPS seeder to filter all
// results that are not the provided ip version, which is expected to be either
// 4 or 6, to indicate IPv4 or IPv6 addresses, respectively.  The HTTPS seeder
// may choose to ignore other IP versions.
func SeedFilterIPVersion(ipVersion uint16) func(f *HttpsSeederFilters) {
	return func(f *HttpsSeederFilters) {
		f.ipVersion = ipVersion
		f.hasIPVersion = true
	}
}

// SeedFilterProtocolVersion configures a request to an HTTPS seeder to filter
// all results that are not the provided peer-to-peer protocol version.  This
// can be useful to discover peers that support specific peer versions.
func SeedFilterProtocolVersion(pver uint32) func(f *HttpsSeederFilters) {
	return func(f *HttpsSeederFilters) {
		f.pver = pver
		f.hasPver = true
	}
}

// SeedFilterServices configures a request to an HTTPS seeder to filter all
// results that do not support the provided service flags.  This can be useful
// to discover peers that support specific services such as fully-validating
// nodes.
func SeedFilterServices(services wire.ServiceFlag) func(f *HttpsSeederFilters) {
	return func(f *HttpsSeederFilters) {
		f.services = services
		f.hasServices = true
	}
}

// SeedFilterFull configures a request to an HTTPS seeder to return the full
// set of good peers instead of the reduced set the seeder returns by default.
//
// The reduced default omits every address that is not an IP address, which
// means Tor onion addresses are only ever reported when this filter is set.
// The HTTPS seeder may choose to ignore this request.
func SeedFilterFull() func(f *HttpsSeederFilters) {
	return func(f *HttpsSeederFilters) {
		f.full = true
	}
}

// node defines a single JSON object returned by the https seeders.
type node struct {
	Host            string `json:"host"`
	Services        uint64 `json:"services"`
	ProtocolVersion uint32 `json:"pver"`
}

// SeedAddrs uses HTTPS seeding to return a list of addresses of p2p peers on
// the network.
//
// The seeder parameter specifies the domain name of the seed.  The dial
// function specifies the dialer to use to contact the HTTPS seeder and allows
// the caller to use whatever configuration it deems fit such as using a proxy,
// like Tor.
//
// The variadic filters parameter allows additional query filters to be applied.
// The available filters can be set via the exported functions that start with
// the prefix SeedFilter.  See the documentation for each function for more
// details.
func SeedAddrs(ctx context.Context, seeder string, dialFn DialFunc, filters ...func(f *HttpsSeederFilters)) ([]wire.NetAddressV2, error) {
	// Set any caller provided filters.
	var seederFilters HttpsSeederFilters
	for _, f := range filters {
		f(&seederFilters)
	}

	// Setup the HTTPS request.
	url := "https://" + seeder
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.URL.Path = "/api/addrs"

	// Configure the query parameters based on the caller-provided filters.
	queryParams := req.URL.Query()
	if seederFilters.hasIPVersion {
		ipVersionStr := strconv.FormatInt(int64(seederFilters.ipVersion), 10)
		queryParams.Add("ipversion", ipVersionStr)
	}
	if seederFilters.hasPver {
		pverStr := strconv.FormatInt(int64(seederFilters.pver), 10)
		queryParams.Add("pver", pverStr)
	}
	if seederFilters.hasServices {
		servicesStr := strconv.FormatUint(uint64(seederFilters.services), 10)
		queryParams.Add("services", servicesStr)
	}
	if seederFilters.full {
		queryParams.Add("full", "1")
	}
	req.URL.RawQuery = queryParams.Encode()

	// Make the request.
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: dialFn,
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("seeder %s returned invalid status code '%d': %v",
			seeder, resp.StatusCode, http.StatusText(resp.StatusCode))
	}

	// Parse the JSON response.
	const maxNodes = 16
	const maxRespSize = maxNodes * 256
	var nodes []node
	dec := json.NewDecoder(io.LimitReader(resp.Body, maxRespSize))
	for ctx.Err() == nil && dec.More() {
		var node node
		if err = dec.Decode(&node); err != nil {
			return nil, fmt.Errorf("unable to parse response: %w", err)
		}
		nodes = append(nodes, node)
		if len(nodes) >= maxNodes {
			break
		}
	}

	// Nothing more to do when no addresses are returned.
	if len(nodes) == 0 {
		log.Infof("0 addresses found from seeder %s", seeder)
		return nil, nil
	}

	// Convert the response to net addresses.
	addrs := make([]wire.NetAddressV2, 0, len(nodes))
	for _, node := range nodes {
		host, portStr, err := net.SplitHostPort(node.Host)
		if err != nil {
			log.Warnf("seeder returned invalid host %q", node.Host)
			continue
		}
		port, err := strconv.ParseUint(portStr, 10, 16)
		if err != nil {
			log.Warnf("seeder returned invalid port %q", node.Host)
			continue
		}
		// Set the timestamp to a value randomly selected between 3 and 7 days
		// ago in order to improve the ranking of peers discovered from seeders
		// since they are a more authoritative source than other random peers.
		ts := time.Now().Add(-1 * (duration3Days + rand.Duration(duration4Days)))
		services := wire.ServiceFlag(node.Services)
		addrType, addrBytes := encodeSeedHost(host)
		var na wire.NetAddressV2
		switch addrType {
		case wire.IPv4Address:
			na = wire.NewNetAddressV2(wire.IPv4Address, addrBytes,
				uint16(port), ts, services)
		case wire.IPv6Address:
			na = wire.NewNetAddressV2(wire.IPv6Address, addrBytes,
				uint16(port), ts, services)
		case wire.TorV3Address:
			na = wire.NewNetAddressV2(wire.TorV3Address, addrBytes,
				uint16(port), ts, services)
		default:
			log.Warnf("seeder returned an unsupported hostname %q", host)
			continue
		}
		addrs = append(addrs, na)
	}

	if len(addrs) < len(nodes) {
		log.Infof("%d addresses found from seeder %s (excluded %d invalid)",
			len(addrs), seeder, len(nodes)-len(addrs))
	} else {
		log.Infof("%d addresses found from seeder %s", len(addrs), seeder)
	}

	return addrs, nil
}

func encodeSeedHost(host string) (wire.NetAddressType, []byte) {
	if len(host) == 62 && strings.HasSuffix(host, ".onion") {
		payload, err := base32.StdEncoding.WithPadding(base32.NoPadding).
			DecodeString(strings.ToUpper(host[:56]))
		if err == nil && len(payload) == 35 && payload[34] == 3 {
			input := append([]byte(".onion checksum"), payload[:32]...)
			input = append(input, 3)
			digest := sha3.Sum256(input)
			if string(payload[32:34]) == string(digest[:2]) {
				return wire.TorV3Address, payload[:32]
			}
		}
	}

	ip := net.ParseIP(host)
	if ip == nil {
		return wire.UnknownAddressType, nil
	}
	if ipv4 := ip.To4(); ipv4 != nil {
		return wire.IPv4Address, ipv4
	}
	return wire.IPv6Address, ip.To16()
}
