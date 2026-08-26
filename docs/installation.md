# Installing questlog

questlog runs on Linux, macOS and Windows. Pick one of the methods below, then see the Running section of the [README](../README.md) for the GUI and the command-line criteria.

Released artifacts are on the [releases page](https://github.com/overseers-desk/questlog/releases); the version appears in each filename.

Two kinds of artifact are published, and the difference is what the host must already have:

- **A distribution package** (`.deb`, `.rpm`, the Homebrew formula) installs questlog's scripts and lets the package manager pull the Tcl 9 runtime as a dependency. Pick one where your distribution carries Tcl 9.
- **A single-file image** carries a statically linked Tcl 9, Tk 9 and the thread extension inside the executable. Nothing is installed and nothing is required on the host beyond its window system. Pick one anywhere else, or when you want one file to drop on a machine or a USB stick, or to run without root.

## Linux

### Debian / Ubuntu

Download `questlog_<version>_all.deb` and install it. apt pulls the Tcl 9 runtime as dependencies:

```
sudo apt install ./questlog_<version>_all.deb
```

The Tcl 9 packages it depends on first ship together in Debian 13 and Ubuntu 25.10, so on anything older apt will refuse the deb; take the single-file image instead.

### Fedora / RHEL

Download `questlog-<version>-1.noarch.rpm` and install it:

```
sudo dnf install ./questlog-<version>-1.noarch.rpm
```

### Single-file image

Download `questlog-<version>-linux-x86_64` (or `-linux-arm64`), make it executable, and run it:

```
chmod +x questlog-<version>-linux-x86_64
./questlog-<version>-linux-x86_64
```

It links only libc and the X11 stack every desktop Linux already has.

## macOS

### Disk image

Download `questlog-<version>-macos-arm64.dmg`, open it, and drag questlog to Applications.

The first launch reports that questlog is damaged and should be moved to the Trash. The download is not damaged. macOS attaches a quarantine flag to anything fetched from the web, and an app that carries no signature it can check fails that check with this wording. questlog carries none: the single-file image is built by appending an archive to the interpreter, and `codesign` refuses to sign a file of that shape at all, whether ad-hoc or with an Apple Developer ID.

Clear the quarantine flag once, and every later launch is an ordinary double-click:

```
xattr -dr com.apple.quarantine /Applications/questlog.app
```

Control-click -> Open does not help here. That override answers "unidentified developer", which is a different verdict from this one.

Only Apple Silicon is published. On an Intel Mac, install through Homebrew below, or build the image from source with `zipfs/build-selfcontained.sh`.

### Homebrew

Homebrew pulls `tcl-tk` (9.x) as a dependency and installs questlog's scripts:

```
brew tap overseers-desk/od
brew install questlog
```

### Single-file image

`questlog-<version>-macos-arm64` is the same program without the bundle: no icon, no Finder launch, run from a terminal. Quarantine applies to it too, so clear it the same way:

```
xattr -d com.apple.quarantine questlog-<version>-macos-arm64
```

## Windows

Download `questlog-<version>-windows-x86_64.exe` and run it. There is nothing to install and no Tcl needed.

The .exe is not signed with a code-signing certificate, so SmartScreen interposes on the first run with "Windows protected your PC". Choose **More info**, then **Run anyway**.

questlog answers on the command line as well as in a window (`--json`, `--shortstat`, `--help`), and those answers print into the console it was started from. Started from Explorer it opens the window and prints nothing, which is what a double-click wants.

Two things questlog does on Linux and macOS it does not do on Windows:

- The Running filter is always empty. Claude Code records a live session's process id, and confirming that a process is still alive costs a console program on Windows, which would flash a console window over the app on every poll.
- Resuming a session opens a Windows Terminal tab where Windows Terminal is installed, and a cmd window where it is not. It runs `claude`, so `claude` has to be on PATH.
