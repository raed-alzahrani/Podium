#include "PodiumJIT.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CS_DEBUGGED 0x10000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static char status_text[192] = "";
static bool breakpoint_abandoned = false;

static void set_status(const char *text) {
    snprintf(status_text, sizeof(status_text), "%s", text);
    fprintf(stderr, "[podium-jit] %s\n", text);
}

const char *podium_jit_status(void) {
    return status_text;
}

bool podium_jit_breakpoint_abandoned(void) {
    return breakpoint_abandoned;
}

bool podium_jit_debugger_attached(void) {
    unsigned int flags = 0;
    return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED) != 0;
}

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR

// universal.js only steps over `brk #0xf00d` when the stop packet contains
// x0, x1, and x16. Prepare leaves the caller's x0 (address) and x1 (length)
// in place and puts the command in x16. Detach has no arguments, so it
// writes x0 and x1 itself; otherwise the script sends `c` again without
// moving the PC and this thread stays on the breakpoint.
__attribute__((naked))
static void jit26_prepare_region(__attribute__((unused)) void *address, __attribute__((unused)) size_t length) {
    __asm__ volatile("mov x16, #1\n"
                     "brk #0xf00d\n"
                     "ret\n");
}

__attribute__((naked))
static void jit26_detach(void) {
    __asm__ volatile("mov x0, #1\n"
                     "mov x1, #1\n"
                     "mov x16, #0\n"
                     "brk #0xf00d\n"
                     "ret\n");
}

static sigjmp_buf trap_jump;
static volatile sig_atomic_t brk_finished;
static volatile sig_atomic_t brk_armed;
static pthread_t brk_thread;
static thread_t brk_mach;

static void on_give_up(int signal_number) {
    (void)signal_number;
    if (!brk_armed) return;
    brk_armed = 0;
    brk_finished = 1;
    siglongjmp(trap_jump, 1);
}

// Runs beside the breakpoint. A dead debugserver leaves that thread
// stopped; resuming it and raising SIGALRM turns the wait into a failure
// the caller can leave, instead of sitting in kernel load forever.
static void *brk_watchdog(void *context) {
    (void)context;
    for (int tick = 0; tick < 30; tick++) {
        usleep(100 * 1000);
        if (brk_finished) return NULL;
    }
    if (brk_finished) return NULL;
    fprintf(stderr, "[podium-jit] breakpoint not resumed after 3s\n");
    thread_resume(brk_mach);
    pthread_kill(brk_thread, SIGALRM);
    return NULL;
}

static bool guarded(void (*body)(void *, size_t), void *address, size_t length) {
    struct sigaction trap_action, alarm_action, previous_trap, previous_alarm;
    memset(&trap_action, 0, sizeof(trap_action));
    memset(&alarm_action, 0, sizeof(alarm_action));
    trap_action.sa_handler = on_give_up;
    alarm_action.sa_handler = on_give_up;
    sigemptyset(&trap_action.sa_mask);
    sigemptyset(&alarm_action.sa_mask);
    sigaddset(&trap_action.sa_mask, SIGALRM);
    sigaddset(&alarm_action.sa_mask, SIGTRAP);
    sigaction(SIGTRAP, &trap_action, &previous_trap);
    sigaction(SIGALRM, &alarm_action, &previous_alarm);

    sigset_t blocked, previous_mask;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGALRM);
    sigaddset(&blocked, SIGTRAP);
    pthread_sigmask(SIG_BLOCK, &blocked, &previous_mask);

    brk_finished = 0;
    brk_armed = 1;
    brk_thread = pthread_self();
    brk_mach = mach_thread_self();
    pthread_t watchdog;
    bool started = pthread_create(&watchdog, NULL, brk_watchdog, NULL) == 0;

    bool ok = false;
    if (sigsetjmp(trap_jump, 1) == 0) {
        pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
        body(address, length);
        pthread_sigmask(SIG_BLOCK, &blocked, NULL);
        brk_armed = 0;
        ok = true;
    } else {
        brk_armed = 0;
    }
    brk_finished = 1;
    if (started) pthread_join(watchdog, NULL);
    mach_port_deallocate(mach_task_self(), brk_mach);
    pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
    sigaction(SIGTRAP, &previous_trap, NULL);
    sigaction(SIGALRM, &previous_alarm, NULL);
    return ok;
}

static void detach_body(void *address, size_t length) {
    (void)address;
    (void)length;
    jit26_detach();
}

#endif

void *podium_jit_allocate(size_t size, void **writable, PodiumJITMode *mode) {
    *writable = NULL;
    *mode = PodiumJITModeNone;
    breakpoint_abandoned = false;

    set_status("Trying RWX MAP_JIT.");
    void *rwx = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (rwx != MAP_FAILED) {
        *writable = rwx;
        *mode = PodiumJITModeRWX;
        char ready[192];
        snprintf(ready, sizeof(ready), "JIT ready: RWX MAP_JIT at %p, %zu bytes.", rwx, size);
        set_status(ready);
        return rwx;
    }
    char refused[192];
    snprintf(refused, sizeof(refused), "RWX MAP_JIT refused (errno %d).", errno);
    set_status(refused);

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (!podium_jit_debugger_attached()) {
        set_status("JIT aborted: no debugger attached. Using the interpreter.");
        return NULL;
    }
    void *executable = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (executable == MAP_FAILED) {
        char message[192];
        snprintf(message, sizeof(message), "JIT aborted: RX mmap failed (errno %d). Using the interpreter.", errno);
        set_status(message);
        return NULL;
    }

    char waiting[192];
    snprintf(waiting, sizeof(waiting), "Waiting for StikDebug prepare: brk #0xf00d, x0=%p, x1=%zu, x16=1.", executable, size);
    set_status(waiting);
    if (!guarded(jit26_prepare_region, executable, size)) {
        breakpoint_abandoned = true;
        set_status("JIT aborted at prepare: StikDebug did not resume the breakpoint. Using the interpreter.");
        munmap(executable, size);
        return NULL;
    }

    set_status("Waiting for StikDebug detach: brk #0xf00d, x0=1, x1=1, x16=0.");
    if (!guarded(detach_body, NULL, 0)) {
        breakpoint_abandoned = true;
        set_status("JIT aborted at detach: StikDebug did not resume the breakpoint. Using the interpreter.");
        munmap(executable, size);
        return NULL;
    }

    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                    (vm_address_t)executable, false, &current, &maximum, VM_INHERIT_DEFAULT);
    if (result != KERN_SUCCESS || mprotect((void *)alias, size, PROT_READ | PROT_WRITE) != 0) {
        char message[192];
        snprintf(message, sizeof(message), "JIT aborted: writable alias failed (kr %d, errno %d). Using the interpreter.", result, errno);
        set_status(message);
        if (result == KERN_SUCCESS) vm_deallocate(mach_task_self(), alias, size);
        munmap(executable, size);
        return NULL;
    }
    *writable = (void *)alias;
    *mode = PodiumJITModeDualMapped;
    char ready[192];
    snprintf(ready, sizeof(ready), "JIT ready: runs at %p, written at %p, %zu bytes.", executable, (void *)alias, size);
    set_status(ready);
    return executable;
#else
    set_status("JIT aborted: this build cannot run generated code. Using the interpreter.");
    return NULL;
#endif
}
