/*
 * Custom wish for the self-contained questlog image.
 *
 * A stock wish loads Tk and Thread as shared objects at runtime, and zipfs
 * cannot serve a .so to load(). So both are linked into this interpreter and
 * registered as static libraries: Tcl_StaticLibrary records their init
 * functions, and package require resolves against the in-binary code instead
 * of a dlopen. The pure-Tcl json package travels in the image's embedded
 * tcl_library and needs no C glue.
 *
 * Thread's own NewThread() calls Tcl_Init() then Thread_Init() on each worker
 * interp it spawns (generic/threadCmd.c), so worker threads created by
 * thread::create pick up Thread with no package ifneeded entry.
 */
#include <tcl.h>
#include <tk.h>

#ifdef _WIN32
#include <windows.h>
#include <stdio.h>

/*
 * questlog answers on stdout as well as in a window: --json, --shortstat,
 * --help and the subcommands all print and exit. On Windows those two answers
 * pull in opposite directions. A console-subsystem binary would open a console
 * window behind every GUI launch; a GUI-subsystem one, which is what gets
 * linked, has no console to print into when it is started from one.
 *
 * So borrow the parent's. Where questlog was launched from a terminal and
 * inherited no usable stdout, attach to that terminal's console and point the
 * standard streams at it; where the streams are already connected (a
 * redirection, a pipe), leave them, or the reopen would overwrite the
 * redirection the caller asked for. Double-clicked from Explorer there is no
 * parent console, AttachConsole fails, and nothing is printed - which is the
 * behaviour a windowed launch wants.
 */
static void BorrowParentConsole(void) {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out != NULL && out != INVALID_HANDLE_VALUE) {
        return;
    }
    if (!AttachConsole(ATTACH_PARENT_PROCESS)) {
        return;
    }
    freopen("CONOUT$", "w", stdout);
    freopen("CONOUT$", "w", stderr);
    freopen("CONIN$", "r", stdin);
}
#endif

extern int Thread_Init(Tcl_Interp *interp);

static int Questlog_AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
    if (Tk_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);

    if (Thread_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Thread", Thread_Init, NULL);

    return TCL_OK;
}

int main(int argc, char **argv) {
#ifdef _WIN32
    BorrowParentConsole();
#endif
    /*
     * Mount the appended zip and rewrite argv to source its main.tcl. Without
     * this hook the stubbed image finds no startup script and drops into an
     * interactive wish.
     */
    TclZipfs_AppHook(&argc, &argv);
    Tk_Main(argc, argv, Questlog_AppInit);
    return 0;
}
