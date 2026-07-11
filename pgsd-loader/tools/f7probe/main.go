// f7probe: a one-shot F7 diagnostic for pgsd-loader.
//
// It stages the transfer-armed real-kernel boot, discovers the
// trampoline address from the loader's NVRAM breadcrumb, runs QEMU
// halted under a gdb stub, drives gdb through the transfer and a set
// of early-kernel landmark breakpoints, and captures the COMPLETE
// gdb and serial streams (nothing filtered). It then parses both and
// prints a single structured report: where the transfer went, how
// far kernel bring-up got, and the final CPU state.
//
// The point is to replace a pile of grep-through-a-pipe gdb harness
// modes, which repeatedly hid the very diagnostic they were meant to
// surface, with one tool that keeps everything and presents it.
//
// Emulation only; the bench remains sole authority. This observes a
// QEMU run, never touches metal.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// config resolved from env and flags.
type config struct {
	projDir   string
	ovmfCode  string
	ovmfVars  string
	qemu      string
	gdb       string
	kernelELF string
	binDir    string
	work      string
}

// landmark is an early-kernel symbol we break on, in call order.
type landmark struct {
	sym  string
	note string
}

var landmarks = []landmark{
	{"amd64_loadaddr", "hammer_time's first op; walks loader page tables by phys"},
	{"hammer_time", "amd64 machine init entry"},
	{"native_parse_preload_data", "reads modulep+KERNBASE metadata"},
	{"getmemsize", "physical memory sizing"},
	{"init_param1", "kernel parameter init"},
	{"cninit", "console init; serial should come alive here"},
}

// result is the parsed outcome of the probe.
type result struct {
	trampAddr    string
	entryAddr    string
	transferOK   bool
	cr3Before    string
	cr3After     string
	entryReached bool
	reached      []string // landmarks hit, in order
	finalRIP     string
	finalRIPSym  string
	faulted      bool
	serialTail   []string
	markers      []string
	gdbRaw       string
	serialRaw    string
	notes        []string
}

func main() {
	cfg, err := resolveConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "f7probe:", err)
		os.Exit(2)
	}
	if os.Geteuid() == 0 {
		fmt.Fprintln(os.Stderr, "f7probe: do not run as root")
		os.Exit(1)
	}

	fmt.Println(titleStyle.Render(" f7probe  pgsd-loader F7 diagnostic "))
	step("building loader, launchers, tools")
	if err := build(cfg); err != nil {
		fatal("build failed", err)
	}

	step("staging transfer-armed ESP with the real kernel")
	esp, vars, err := stage(cfg)
	if err != nil {
		fatal("staging failed", err)
	}

	step("discovering the trampoline address (one boot, read NVRAM)")
	tramp, entry, markers, err := discover(cfg, esp, vars)
	if err != nil {
		fatal("discovery failed", err)
	}
	if tramp == "" {
		fatal("no trampoline address recorded", fmt.Errorf("transfer path not reached; check arming and PGSD_REAL_KERNEL"))
	}

	step("running the kernel under gdb, capturing everything")
	res, err := runUnderGDB(cfg, esp, vars, tramp, entry)
	if err != nil {
		fatal("gdb run failed", err)
	}
	res.markers = markers

	report(cfg, res)
}

func resolveConfig() (*config, error) {
	self, _ := os.Executable()
	// tools/f7probe/f7probe -> pgsd-loader
	proj := os.Getenv("PGSD_LOADER_DIR")
	if proj == "" {
		// default: two levels up from the binary's dir (tools/f7probe)
		proj = filepath.Clean(filepath.Join(filepath.Dir(self), "..", ".."))
	}
	c := &config{
		projDir:   proj,
		ovmfCode:  firstFile(os.Getenv("OVMF_CODE"), "/usr/local/share/edk2-qemu/QEMU_UEFI_CODE-x86_64.fd", "/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_CODE.fd"),
		ovmfVars:  firstFile(os.Getenv("OVMF_VARS"), "/usr/local/share/edk2-qemu/QEMU_UEFI_VARS-x86_64.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
		qemu:      envOr("QEMU", "qemu-system-x86_64"),
		gdb:       envOr("GDB", "gdb"),
		kernelELF: os.Getenv("PGSD_REAL_KERNEL"),
	}
	c.binDir = filepath.Join(c.projDir, "zig-out", "bin")
	c.work = filepath.Join(os.TempDir(), fmt.Sprintf("f7probe.%d", os.Getpid()))
	if c.ovmfCode == "" || c.ovmfVars == "" {
		return nil, fmt.Errorf("set OVMF_CODE and OVMF_VARS (no default firmware found)")
	}
	if c.kernelELF == "" {
		return nil, fmt.Errorf("set PGSD_REAL_KERNEL to the pinned kernel ELF")
	}
	if !fileExists(c.kernelELF) {
		return nil, fmt.Errorf("PGSD_REAL_KERNEL not found: %s", c.kernelELF)
	}
	return c, nil
}

func build(cfg *config) error {
	for _, target := range [][]string{{}, {"test-target"}, {"tools"}} {
		args := append([]string{filepath.Join(cfg.projDir, "build.sh")}, target...)
		cmd := exec.Command("sh", args...)
		cmd.Dir = cfg.projDir
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("build.sh %v: %v\n%s", target, err, out)
		}
	}
	return nil
}

func stage(cfg *config) (esp, vars string, err error) {
	esp = filepath.Join(cfg.work, "esp")
	vars = filepath.Join(cfg.work, "vars.fd")
	for _, d := range []string{"EFI/BOOT", "EFI/pgsd/bas/slots/1", "EFI/freebsd"} {
		if err = os.MkdirAll(filepath.Join(esp, d), 0o755); err != nil {
			return
		}
	}
	cp := func(src, dst string) error { return copyFile(src, filepath.Join(esp, dst)) }
	if err = cp(filepath.Join(cfg.binDir, "boot-launcher.efi"), "EFI/BOOT/BOOTX64.EFI"); err != nil {
		return
	}
	if err = cp(filepath.Join(cfg.binDir, "pgsd-loader.efi"), "EFI/pgsd/pgsd-loader-boot.efi"); err != nil {
		return
	}
	if err = cp(filepath.Join(cfg.binDir, "chainload-target.efi"), "EFI/freebsd/loader.efi"); err != nil {
		return
	}
	if err = cp(cfg.kernelELF, "EFI/pgsd/bas/slots/1/kernel"); err != nil {
		return
	}
	kpath := filepath.Join(esp, "EFI/pgsd/bas/slots/1/kernel")
	ksum, kerr := sha256File(kpath)
	if kerr != nil {
		return esp, vars, kerr
	}
	ksize, _ := fileSize(kpath)
	manifest := fmt.Sprintf("PGSD-BAS-MANIFEST 1\n%s %d kernel\n", ksum, ksize)
	mpath := filepath.Join(esp, "EFI/pgsd/bas/slots/1/manifest")
	if err = os.WriteFile(mpath, []byte(manifest), 0o644); err != nil {
		return
	}
	sel := filepath.Join(esp, "EFI/pgsd/bas/selector")
	if err = run(filepath.Join(cfg.binDir, "bas-selector"), "init", sel); err != nil {
		return
	}
	msum, merr := sha256File(mpath)
	if merr != nil {
		return esp, vars, merr
	}
	if err = run(filepath.Join(cfg.binDir, "bas-selector"), "commit", sel, "1", msum); err != nil {
		return
	}
	err = copyFile(cfg.ovmfVars, vars)
	return
}

var reTramp = regexp.MustCompile(`clipc=0x[0-9a-f]+`)
var reEntry = regexp.MustCompile(`entry=0x[0-9a-f]+`)
var reMarker = regexp.MustCompile(`(BOOT_ATTEMPT[^\x00]*|MARK_[A-Z_]+)`)

// discover boots once headless and reads the loader breadcrumb from
// the (persisted) OVMF vars image.
func discover(cfg *config, esp, vars string) (tramp, entry string, markers []string, err error) {
	// fresh vars for this boot
	if err = copyFile(cfg.ovmfVars, vars); err != nil {
		return
	}
	args := qemuArgs(cfg, vars, esp, false)
	cmd := exec.Command(cfg.qemu, args...)
	done := make(chan error, 1)
	if e := cmd.Start(); e != nil {
		return "", "", nil, e
	}
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		_ = cmd.Process.Kill()
	}
	data, _ := os.ReadFile(vars)
	s := string(data)
	if m := reTramp.FindString(s); m != "" {
		tramp = strings.TrimPrefix(m, "clipc=")
	}
	if m := reEntry.FindString(s); m != "" {
		entry = strings.TrimPrefix(m, "entry=")
	}
	for _, m := range reMarker.FindAllString(s, -1) {
		markers = append(markers, strings.TrimRight(m, "\x00"))
	}
	markers = dedupTail(markers, 6)
	return
}

// runUnderGDB launches QEMU halted with a gdb stub and drives gdb in
// batch mode, capturing the full transcript.
func runUnderGDB(cfg *config, esp, vars, tramp, entry string) (*result, error) {
	if err := copyFile(cfg.ovmfVars, vars); err != nil {
		return nil, err
	}
	serialPath := filepath.Join(cfg.work, "serial.log")
	args := append(qemuArgs(cfg, vars, esp, true), "-serial", "file:"+serialPath)
	q := exec.Command(cfg.qemu, args...)
	if err := q.Start(); err != nil {
		return nil, err
	}
	defer func() { _ = q.Process.Kill() }()
	time.Sleep(1 * time.Second)

	cmds := buildGDBScript(cfg.kernelELF, tramp)
	scriptPath := filepath.Join(cfg.work, "gdb.cmds")
	if err := os.WriteFile(scriptPath, []byte(cmds), 0o644); err != nil {
		return nil, err
	}
	g := exec.Command(cfg.gdb, "-q", "-nx", "-batch", "-x", scriptPath)
	gout, err := g.CombinedOutput()
	if err != nil {
		// gdb batch returns nonzero on some detach paths; keep output
		gout = append(gout, []byte(fmt.Sprintf("\n[gdb exit: %v]\n", err))...)
	}
	serial, _ := os.ReadFile(serialPath)
	res := parse(string(gout), string(serial), tramp, entry)
	return res, nil
}

func buildGDBScript(kernelELF, tramp string) string {
	var b strings.Builder
	p := func(s string) { b.WriteString(s + "\n") }
	p("set pagination off")
	p("set confirm off")
	p("target remote localhost:1234")
	p("printf \"PROBE_CONNECTED\\n\"")
	p(fmt.Sprintf("hbreak *%s", tramp))
	p("continue")
	p("printf \"PROBE_AT_CLI rip=%#lx cr3=%#lx\\n\", $rip, $cr3")
	// step the four trampoline instructions
	p("stepi")
	p("printf \"PROBE_AFTER_CLI rip=%#lx\\n\", $rip")
	p("stepi")
	p("printf \"PROBE_AFTER_CR3 rip=%#lx cr3=%#lx\\n\", $rip, $cr3")
	p("stepi")
	p("printf \"PROBE_AFTER_RSP rip=%#lx rsp=%#lx\\n\", $rip, $rsp")
	p("stepi")
	p("printf \"PROBE_AT_ENTRY rip=%#lx\\n\", $rip")
	p(fmt.Sprintf("file %s", kernelELF))
	// landmarks, each with its own bound command block
	n := 2 // hbreak is #1
	for _, lm := range landmarks {
		p(fmt.Sprintf("break %s", lm.sym))
		p(fmt.Sprintf("commands %d", n))
		p("silent")
		p(fmt.Sprintf("printf \"PROBE_LANDMARK %s rip=%%#lx\\n\", $rip", lm.sym))
		p("continue")
		p("end")
		n++
	}
	// let it run; whatever stops it (fault, or a landmark that does not
	// continue) leaves final state to report
	p("continue")
	p("printf \"PROBE_FINAL rip=%#lx rsp=%#lx\\n\", $rip, $rsp")
	p("info registers rip rsp rax rbx rcx rdx rsi rdi")
	p("printf \"PROBE_DISASM\\n\"")
	p("x/4i $rip")
	p("detach")
	p("quit")
	return b.String()
}

func qemuArgs(cfg *config, vars, esp string, gdbStub bool) []string {
	a := []string{
		"-machine", "q35", "-m", "256", "-nographic", "-no-reboot", "-boot", "menu=off",
		"-drive", "if=pflash,format=raw,readonly=on,file=" + cfg.ovmfCode,
		"-drive", "if=pflash,format=raw,file=" + vars,
		"-drive", "format=raw,file=fat:rw:" + esp,
		"-net", "none",
	}
	if gdbStub {
		a = append(a, "-S", "-gdb", "tcp::1234")
	}
	return a
}

var (
	reProbeCLI    = regexp.MustCompile(`PROBE_AT_CLI rip=(\w+) cr3=(\w+)`)
	reProbeCR3    = regexp.MustCompile(`PROBE_AFTER_CR3 rip=(\w+) cr3=(\w+)`)
	reProbeEntry  = regexp.MustCompile(`PROBE_AT_ENTRY rip=(\w+)`)
	reProbeLand   = regexp.MustCompile(`PROBE_LANDMARK (\w+) rip=(\w+)`)
	reProbeFinal  = regexp.MustCompile(`PROBE_FINAL rip=(\w+) rsp=(\w+)`)
	reRIPWithSym  = regexp.MustCompile(`rip\s+0x\w+\s+(0x\w+)\s+<([^>]+)>`)
	reBanner      = regexp.MustCompile(`Copyright \(c\) 1992`)
)

func parse(gdbOut, serial, tramp, entry string) *result {
	r := &result{trampAddr: tramp, entryAddr: entry, gdbRaw: gdbOut, serialRaw: serial}
	if m := reProbeCLI.FindStringSubmatch(gdbOut); m != nil {
		r.cr3Before = m[2]
	}
	if m := reProbeCR3.FindStringSubmatch(gdbOut); m != nil {
		r.cr3After = m[2]
	}
	if m := reProbeEntry.FindStringSubmatch(gdbOut); m != nil {
		r.entryReached = true
		_ = m
	}
	r.transferOK = r.cr3Before != "" && r.cr3After != "" && r.cr3Before != r.cr3After && r.entryReached
	for _, m := range reProbeLand.FindAllStringSubmatch(gdbOut, -1) {
		r.reached = append(r.reached, m[1])
	}
	if m := reProbeFinal.FindStringSubmatch(gdbOut); m != nil {
		r.finalRIP = m[1]
	}
	if m := reRIPWithSym.FindStringSubmatch(gdbOut); m != nil {
		r.finalRIPSym = m[2]
	}
	// serial tail
	sc := bufio.NewScanner(strings.NewReader(serial))
	var lines []string
	for sc.Scan() {
		lines = append(lines, strings.TrimRight(sc.Text(), "\r"))
	}
	r.serialTail = tail(lines, 12)
	if reBanner.MatchString(serial) {
		r.notes = append(r.notes, "FreeBSD copyright banner present in serial")
	}
	return r
}

func fatal(msg string, err error) {
	fmt.Fprintln(os.Stderr, errStyle.Render("f7probe: "+msg))
	if err != nil {
		fmt.Fprintln(os.Stderr, "  "+err.Error())
	}
	os.Exit(1)
}

func step(s string) { fmt.Println(stepStyle.Render("• " + s)) }

// styles
var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("15")).Background(lipgloss.Color("57")).Padding(0, 1)
	stepStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))
	errStyle   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("196"))
	okStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("46"))
	warnStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	dimStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	boxStyle   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color("63")).Padding(0, 1)
	headStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("63"))
)
