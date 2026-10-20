// adapter-recover tests whether a longer adapter-input inhibit (CHIE=08)
// makes macOS take power from a charger it ignores (ExternalConnected = No
// while the charger is live). It always writes CHIE back to 00. Needs root.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"time"

	"github.com/charlie0129/gosmc"
)

var external = regexp.MustCompile(`"ExternalConnected" = (Yes|No)`)

func connected() string {
	out, err := exec.Command("/usr/sbin/ioreg", "-rn", "AppleSmartBattery").Output()
	if err != nil {
		return "?"
	}
	if m := external.FindSubmatch(out); m != nil {
		return string(m[1])
	}
	return "?"
}

func main() {
	hold := flag.Duration("hold", 3*time.Second, "how long to keep the adapter input off")
	watch := flag.Duration("watch", 20*time.Second, "how long to watch afterwards")
	flag.Parse()
	c, err := gosmc.Open()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer c.Close()
	v, err := c.Read("CHIE")
	if err != nil || len(v.Bytes) != 1 || v.Bytes[0] != 0 {
		fmt.Fprintln(os.Stderr, "CHIE not readable as 00; nothing written", err)
		os.Exit(1)
	}
	fmt.Println(time.Now().Format("15:04:05"), "before: external", connected())
	if err := c.WriteBytes("CHIE", []byte{8}); err != nil {
		fmt.Fprintln(os.Stderr, "write 08:", err)
		os.Exit(1)
	}
	time.Sleep(*hold)
	if err := c.WriteBytes("CHIE", []byte{0}); err != nil {
		fmt.Fprintln(os.Stderr, "RESTORE FAILED, CHIE may be 08:", err)
		os.Exit(2)
	}
	v, _ = c.Read("CHIE")
	fmt.Println(time.Now().Format("15:04:05"), "CHIE restored", v.Bytes)
	for deadline := time.Now().Add(*watch); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		fmt.Println(time.Now().Format("15:04:05"), "external", connected())
	}
}
