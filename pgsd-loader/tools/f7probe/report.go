package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

)

// report renders the structured diagnostic.
func report(cfg *config, r *result) {
	fmt.Println()
	fmt.Println(titleStyle.Render(" F7 PROBE REPORT "))
	fmt.Println()

	// 1. Transfer
	var tb strings.Builder
	tb.WriteString(headStyle.Render("Transfer") + "\n")
	tb.WriteString(fmt.Sprintf("  trampoline (cli)  %s\n", r.trampAddr))
	tb.WriteString(fmt.Sprintf("  kernel entry      %s\n", r.entryAddr))
	if r.cr3Before != "" && r.cr3After != "" {
		arrow := dimStyle.Render("→")
		tb.WriteString(fmt.Sprintf("  cr3 switch        %s %s %s\n", r.cr3Before, arrow, r.cr3After))
	}
	if r.transferOK {
		tb.WriteString("  status            " + okStyle.Render("cr3 switched, next fetch OK, entry reached") + "\n")
	} else if r.entryReached {
		tb.WriteString("  status            " + warnStyle.Render("entry reached but cr3 change not confirmed") + "\n")
	} else {
		tb.WriteString("  status            " + errStyle.Render("entry NOT reached; transfer failed") + "\n")
	}
	fmt.Println(boxStyle.Render(tb.String()))

	// 2. Kernel bring-up landmarks
	var lb strings.Builder
	lb.WriteString(headStyle.Render("Kernel bring-up") + "\n")
	reachedSet := map[string]bool{}
	for _, s := range r.reached {
		reachedSet[s] = true
	}
	lastReached := ""
	for _, lm := range landmarks {
		mark := errStyle.Render("✗")
		if reachedSet[lm.sym] {
			mark = okStyle.Render("✓")
			lastReached = lm.sym
		}
		lb.WriteString(fmt.Sprintf("  %s %-28s %s\n", mark, lm.sym, dimStyle.Render(lm.note)))
	}
	fmt.Println(boxStyle.Render(lb.String()))

	// 3. Verdict
	var vb strings.Builder
	vb.WriteString(headStyle.Render("Verdict") + "\n")
	switch {
	case !r.entryReached:
		vb.WriteString("  " + errStyle.Render("Transfer did not reach kernel entry.") + "\n")
		vb.WriteString(dimStyle.Render("  The fault is in the loader trampoline. Unexpected: prior\n  runs proved the transfer. Re-check the discovered address.") + "\n")
	case len(r.reached) == 0:
		vb.WriteString("  " + warnStyle.Render("Kernel entry reached; no landmark hit.") + "\n")
		vb.WriteString(dimStyle.Render("  Fault is in btext locore before hammer_time, OR the\n  landmark breakpoints did not resolve to the running\n  kernel's addresses (check the gdb transcript).") + "\n")
	case reachedSet["kern_reboot"]:
		vb.WriteString("  " + warnStyle.Render("Kernel booted through init and then called kern_reboot.") + "\n")
		vb.WriteString(dimStyle.Render("  This is not a crash: the kernel initialized and chose to\n  halt/shutdown. The cause is downstream of the loader,\n  most likely no mountable root (vfs.root.mountfrom names a\n  pool the emulator does not have) or a console that never\n  produced a prompt. Check whether vfs_mountroot was\n  reached and read the serial for a mountroot message.") + "\n")
	case reachedSet["start_init"]:
		vb.WriteString("  " + okStyle.Render("Kernel reached start_init (launching userland).") + "\n")
		vb.WriteString(dimStyle.Render("  Early boot is fully working through the loader handoff.\n  Any remaining issue is userland/root-fs, not the loader.") + "\n")
	case reachedSet["vfs_mountroot"]:
		vb.WriteString("  " + okStyle.Render("Kernel reached vfs_mountroot.") + "\n")
		vb.WriteString(dimStyle.Render("  The kernel booted through init to root mounting. A stop\n  here is a root-filesystem problem (the named root is not\n  present in the emulator), not a loader or handoff fault.") + "\n")
	case reachedSet["cninit"]:
		vb.WriteString("  " + okStyle.Render("Reached cninit (console init).") + "\n")
		vb.WriteString(dimStyle.Render("  The kernel booted through early init. If no banner on\n  serial, the issue is console/UART config, not the handoff.") + "\n")
	default:
		vb.WriteString("  " + warnStyle.Render("Boot stopped after "+lastReached+".") + "\n")
		next := nextLandmark(lastReached)
		if next != "" {
			vb.WriteString(dimStyle.Render(fmt.Sprintf("  The fault is between %s and %s. Read that span in\n  the FreeBSD source and check the loader contract it needs.", lastReached, next)) + "\n")
		}
	}
	if r.finalRIP != "" {
		sym := r.finalRIPSym
		if sym == "" {
			sym = "(no symbol)"
		}
		vb.WriteString(fmt.Sprintf("  final rip         %s  %s\n", r.finalRIP, dimStyle.Render(sym)))
	}
	for _, n := range r.notes {
		vb.WriteString("  " + okStyle.Render("note: "+n) + "\n")
	}
	fmt.Println(boxStyle.Render(vb.String()))

	// 4. NVRAM markers + serial tail
	var sb strings.Builder
	sb.WriteString(headStyle.Render("Evidence") + "\n")
	sb.WriteString(dimStyle.Render("  NVRAM markers:") + "\n")
	for _, m := range r.markers {
		sb.WriteString("    " + sanitize(m) + "\n")
	}
	sb.WriteString(dimStyle.Render("  serial tail:") + "\n")
	for _, l := range r.serialTail {
		if l == "" {
			continue
		}
		sb.WriteString("    " + dimStyle.Render(sanitize(l)) + "\n")
	}
	fmt.Println(boxStyle.Render(sb.String()))

	// 5. Full logs to files (nothing hidden)
	gpath := writeLog(cfg, "f7probe-gdb.log", r.gdbRaw)
	spath := writeLog(cfg, "f7probe-serial.log", r.serialRaw)
	fmt.Println(dimStyle.Render("Full transcripts (unfiltered):"))
	fmt.Println(dimStyle.Render("  gdb    " + gpath))
	fmt.Println(dimStyle.Render("  serial " + spath))
}

func nextLandmark(sym string) string {
	for i, lm := range landmarks {
		if lm.sym == sym && i+1 < len(landmarks) {
			return landmarks[i+1].sym
		}
	}
	return ""
}

func writeLog(cfg *config, name, content string) string {
	p := "/tmp/" + name
	_ = os.WriteFile(p, []byte(content), 0o644)
	return p
}

// ---- small helpers ----

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func firstFile(paths ...string) string {
	for _, p := range paths {
		if p != "" && fileExists(p) {
			return p
		}
	}
	return ""
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func fileSize(p string) (int64, error) {
	fi, err := os.Stat(p)
	if err != nil {
		return 0, err
	}
	return fi.Size(), nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Sync()
}

func sha256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%s %v: %v\n%s", name, args, err, out)
	}
	return nil
}

func tail(lines []string, n int) []string {
	if len(lines) <= n {
		return lines
	}
	return lines[len(lines)-n:]
}

// sanitize keeps printable ASCII and common whitespace, replacing
// other bytes (raw firmware/serial noise) with a dot, so the report
// is always valid UTF-8 and legible.
func sanitize(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		switch {
		case c == '\n' || c == '\t':
			b.WriteByte(c)
		case c >= 0x20 && c < 0x7f:
			b.WriteByte(c)
		default:
			b.WriteByte('.')
		}
	}
	return b.String()
}

func dedupTail(items []string, n int) []string {
	seen := map[string]bool{}
	var out []string
	for _, it := range items {
		if !seen[it] {
			seen[it] = true
			out = append(out, it)
		}
	}
	return tail(out, n)
}

