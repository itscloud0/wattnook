// Command smc-readonly-probe lists charging-related SMC keys with their
// metadata and current values. It only calls Open, KeyCount, KeyAt, KeyInfo,
// Read and Close; it never writes to the SMC.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/charlie0129/gosmc"
)

var focus = []string{"CH0B", "CH0C", "CHTE", "CHIE", "CH0I", "CH0J", "CH0K", "CH0R",
	"BCLM", "bfF0", "bfD0", "bfE0", "ACLC", "AC-W", "BUIC", "B0AC", "PDTR", "PPBR"}

func attrs(a uint8) string {
	names := []struct {
		bit  uint8
		name string
	}{{0x80, "R"}, {0x40, "W"}, {0x20, "?20"}, {0x10, "FUNC"}, {0x08, "CONST"}, {0x04, "ATOMIC"}, {0x02, "PRIV_R"}, {0x01, "PRIV_W"}}
	var out []string
	for _, n := range names {
		if a&n.bit != 0 {
			out = append(out, n.name)
		}
	}
	return strings.Join(out, "|")
}

func main() {
	c := gosmc.New()
	if err := c.Open(); err != nil {
		fmt.Fprintln(os.Stderr, "open:", err)
		os.Exit(1)
	}
	defer c.Close()

	if len(os.Args) > 1 && os.Args[1] == "-temps" {
		printTemperatures(c)
		return
	}
	seen := map[string]bool{}
	keys := append([]string{}, focus...)
	if n, err := c.KeyCount(); err == nil {
		fmt.Printf("total SMC keys: %d\n", n)
		for i := uint32(0); i < n; i++ {
			k, err := c.KeyAt(i)
			if err != nil {
				continue
			}
			if strings.HasPrefix(k, "CH") || strings.HasPrefix(k, "bf") || strings.HasPrefix(k, "BCL") {
				keys = append(keys, k)
			}
		}
	} else {
		fmt.Println("key count:", err)
	}

	fmt.Printf("%-5s %-5s %-4s %-5s %-24s %s\n", "KEY", "TYPE", "SIZE", "ATTR", "FLAGS", "VALUE")
	for _, k := range keys {
		if seen[k] {
			continue
		}
		seen[k] = true
		info, err := c.KeyInfo(k)
		if err != nil {
			fmt.Printf("%-5s absent (%v)\n", k, err)
			continue
		}
		val := "-"
		if info.DataSize > 0 {
			if v, err := c.Read(k); err == nil {
				val = fmt.Sprintf("% x", v.Bytes)
			} else {
				val = "read err: " + err.Error()
			}
		}
		fmt.Printf("%-5s %-5s %-4d 0x%02x  %-24s %s\n", k, info.DataType, info.DataSize, info.Attribute, attrs(info.Attribute), val)
	}
}

// printTemperatures lists every readable float temperature key (T***) in a
// plausible range, hottest first per prefix, still read-only.
func printTemperatures(c *gosmc.Client) {
	n, err := c.KeyCount()
	if err != nil {
		fmt.Fprintln(os.Stderr, "key count:", err)
		return
	}
	for i := uint32(0); i < n; i++ {
		k, err := c.KeyAt(i)
		if err != nil || !strings.HasPrefix(k, "T") {
			continue
		}
		v, err := c.Read(k)
		if err != nil || v.DataType != "flt " {
			continue
		}
		t, err := v.Float64()
		if err != nil || t < 10 || t > 120 {
			continue
		}
		fmt.Printf("%s %.1f\n", k, t)
	}
}
