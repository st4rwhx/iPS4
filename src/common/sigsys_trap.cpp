// SPDX-FileCopyrightText: Copyright 2025-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "common/sigsys_trap.h"

#include <array>
#include <cerrno>
#include <cstring>
#include <signal.h>
#include <unistd.h>

#ifdef __APPLE__
// Darwin's <ucontext.h> hard-errors on the deprecated getcontext/setcontext/swapcontext
// declarations unless _XOPEN_SOURCE is defined; only the ucontext_t/mcontext_t *types*
// are needed below, never those functions. pc/sp/fp/lr are pointer-authentication-opaque
// fields on Apple Silicon requiring the arm_thread_state64_get_* accessor macros.
#define _XOPEN_SOURCE 1
#include <ucontext.h>
#include <mach/arm/thread_status.h>
#include <pthread.h>
#else
#include <sys/syscall.h>
#include <ucontext.h>
#endif

#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
#include "core/fex/fex_guest_engine.h"
#endif

namespace Common {

namespace {
struct sigaction g_old_sigsys_action;
// Alternate signal stack so the handler can run even if the crashing thread's
// stack is exhausted. SA_ONSTACK (set below) routes the signal here.
std::array<unsigned char, 65536> g_sigsys_altstack alignas(16){};

// snprintf (formerly used here) is not on POSIX's async-signal-safe list, and this
// handler runs from a raw sa_sigaction context (installed via InstallBachataSigsysTrap).
// core/fex/fex_guest_engine.cpp diagnosed the exact same bug class in HandleGuestSignal:
// vsnprintf-family calls can lazily initialize per-thread locale/conversion state on
// first use, which can require a heap allocation -- and if the interrupting signal landed
// while this same thread already held malloc's internal lock, that lazy init self-deadlocks
// forever with no crash and no output. This handler builds its report with the same
// allocation-free, manual-digit-conversion technique that fex_guest_engine.cpp's
// SignalSafeLog uses, rather than depending on that FEX-specific translation unit from
// this generic (non-FEX-specific) crash handler.
void SigSafeWriteUnsigned(char*& out, char* end, unsigned long long value, int base) {
    char digits[32];
    int n = 0;
    if (value == 0) {
        digits[n++] = '0';
    } else {
        while (value != 0 && n < static_cast<int>(sizeof(digits))) {
            const unsigned long long digit = value % static_cast<unsigned long long>(base);
            digits[n++] = digit < 10 ? static_cast<char>('0' + digit) : static_cast<char>('a' + (digit - 10));
            value /= static_cast<unsigned long long>(base);
        }
    }
    while (n > 0 && out < end) {
        *out++ = digits[--n];
    }
}

void SigSafeWriteHex(char*& out, char* end, unsigned long long value) {
    if (out < end) *out++ = '0';
    if (out < end) *out++ = 'x';
    SigSafeWriteUnsigned(out, end, value, 16);
}

// For fields the original snprintf format printed with a signed specifier (%d/%ld) --
// si_syscall in particular is commonly -1 on Apple (see below) and must not come out as
// a huge unsigned value.
void SigSafeWriteSigned(char*& out, char* end, long long value) {
    if (value < 0) {
        if (out < end) *out++ = '-';
        SigSafeWriteUnsigned(out, end, static_cast<unsigned long long>(-value), 10);
    } else {
        SigSafeWriteUnsigned(out, end, static_cast<unsigned long long>(value), 10);
    }
}

void SigSafeWriteStr(char*& out, char* end, const char* s) {
    while (s != nullptr && *s != '\0' && out < end) {
        *out++ = *s++;
    }
}

// EINTR-retry write loop: a single unchecked write() inside a signal handler can silently
// drop a short-written or EINTR-interrupted message (we may already be re-entering after
// another interrupt here).
void SigSafeFlush(const char* buf, size_t len) {
    size_t remaining = len;
    const char* wp = buf;
    while (remaining > 0) {
        const ssize_t written = ::write(STDERR_FILENO, wp, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (written == 0) {
            break;
        }
        wp += written;
        remaining -= static_cast<size_t>(written);
    }
}

void BachataSigsysHandler(int signo, siginfo_t* info, void* uctx) {
    ucontext_t* _ctx = reinterpret_cast<ucontext_t*>(uctx);
    uint64_t pc = 0, sp = 0, x8 = 0;
    uint64_t x0 = 0, x1 = 0, x2 = 0, x3 = 0, x4 = 0, x5 = 0, x29 = 0, x30 = 0;
#ifdef __aarch64__
    if (_ctx) {
#ifdef __APPLE__
        const auto& ts = _ctx->uc_mcontext->__ss;
        pc = (uint64_t)arm_thread_state64_get_pc(ts);
        sp = (uint64_t)arm_thread_state64_get_sp(ts);
        x8 = ts.__x[8];
        x0 = ts.__x[0];
        x1 = ts.__x[1];
        x2 = ts.__x[2];
        x3 = ts.__x[3];
        x4 = ts.__x[4];
        x5 = ts.__x[5];
        x29 = (uint64_t)arm_thread_state64_get_fp(ts);
        x30 = (uint64_t)arm_thread_state64_get_lr(ts);
#else
        pc = _ctx->uc_mcontext.pc;
        sp = _ctx->uc_mcontext.sp;
        x8 = _ctx->uc_mcontext.regs[8];
        x0 = _ctx->uc_mcontext.regs[0];
        x1 = _ctx->uc_mcontext.regs[1];
        x2 = _ctx->uc_mcontext.regs[2];
        x3 = _ctx->uc_mcontext.regs[3];
        x4 = _ctx->uc_mcontext.regs[4];
        x5 = _ctx->uc_mcontext.regs[5];
        x29 = _ctx->uc_mcontext.regs[29];
        x30 = _ctx->uc_mcontext.regs[30];
#endif
    }
#endif

    // Best-effort guest RIP/syscall capture. On the FEX guest CPU path, mid-JIT
    // guest state lives in SRA host regs, but at a host syscall boundary the
    // CurrentFrame holds the spilled guest RIP and RAX. Returns false (leaves
    // guest_rip/guest_syscall as the "unavailable" sentinels) when no FEX thread
    // is active (e.g. crash during host-only init or in a non-FEX host library).
    uint64_t guest_rip = 0;
    uint64_t guest_syscall = 0;
    bool have_guest = false;
#ifdef SHADPS4_ENABLE_FEX_GUEST_CPU
    have_guest = AetherPS4::Fex::BachataQueryGuestRipSyscall(&guest_rip, &guest_syscall);
#endif

#ifdef __APPLE__
    uint64_t apple_tid = 0;
    pthread_threadid_np(nullptr, &apple_tid);
#endif

    const long signo_v = info ? info->si_signo : signo;
    const long code_v = info ? info->si_code : 0;
    const long errno_v = info ? info->si_errno : 0;
#ifdef __APPLE__
    // si_syscall/si_arch/si_call_addr are populated by Linux's seccomp-based syscall
    // filtering, which SIGSYS is normally paired with there; Darwin has no seccomp
    // equivalent and siginfo_t carries none of these fields, so there's nothing
    // meaningful to report here.
    const long syscall_v = -1;
    const unsigned long arch_v = 0u;
    const unsigned long call_addr_v = 0UL;
#else
    const long syscall_v = info ? info->si_syscall : -1;
    const unsigned long arch_v = info ? info->si_arch : 0;
    const unsigned long call_addr_v = info ? (unsigned long)(uintptr_t)info->si_call_addr : 0UL;
#endif
#ifdef __APPLE__
    const long tid_v = (long)apple_tid;
#else
    const long tid_v = (long)::syscall(SYS_gettid);
#endif

    char buf[1024];
    char* out = buf;
    char* const end = buf + sizeof(buf);
    SigSafeWriteStr(out, end, "[Bachata.FEX.SIGSYS] signo=");
    SigSafeWriteSigned(out, end, signo_v);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] code=");
    SigSafeWriteSigned(out, end, code_v);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] errno=");
    SigSafeWriteSigned(out, end, errno_v);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] syscall=");
    SigSafeWriteSigned(out, end, syscall_v);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] arch=");
    SigSafeWriteHex(out, end, arch_v);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] call_addr=");
    SigSafeWriteHex(out, end, call_addr_v);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] host_pc=");
    SigSafeWriteHex(out, end, (unsigned long)pc);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] host_x8=");
    SigSafeWriteUnsigned(out, end, (unsigned long)x8, 10);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] guest_rip=");
    SigSafeWriteHex(out, end, (unsigned long)guest_rip);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] guest_syscall=");
    SigSafeWriteStr(out, end, have_guest ? "" : "unavailable ");
    SigSafeWriteUnsigned(out, end, (unsigned long)guest_syscall, 10);
    SigSafeWriteStr(out, end, "\n[Bachata.FEX.SIGSYS] host_sp=");
    SigSafeWriteHex(out, end, (unsigned long)sp);
    SigSafeWriteStr(out, end, " host_x0=");
    SigSafeWriteHex(out, end, (unsigned long)x0);
    SigSafeWriteStr(out, end, " host_x1=");
    SigSafeWriteHex(out, end, (unsigned long)x1);
    SigSafeWriteStr(out, end, " host_x2=");
    SigSafeWriteHex(out, end, (unsigned long)x2);
    SigSafeWriteStr(out, end, " host_x3=");
    SigSafeWriteHex(out, end, (unsigned long)x3);
    SigSafeWriteStr(out, end, " host_x4=");
    SigSafeWriteHex(out, end, (unsigned long)x4);
    SigSafeWriteStr(out, end, " host_x5=");
    SigSafeWriteHex(out, end, (unsigned long)x5);
    SigSafeWriteStr(out, end, " host_x29=");
    SigSafeWriteHex(out, end, (unsigned long)x29);
    SigSafeWriteStr(out, end, " host_x30=");
    SigSafeWriteHex(out, end, (unsigned long)x30);
    SigSafeWriteStr(out, end, " pid=");
    SigSafeWriteUnsigned(out, end, (unsigned long long)::getpid(), 10);
    SigSafeWriteStr(out, end, " tid=");
    SigSafeWriteSigned(out, end, tid_v);
    SigSafeWriteStr(out, end, "\n");

    SigSafeFlush(buf, static_cast<size_t>(out - buf));

    if (g_old_sigsys_action.sa_flags & SA_SIGINFO) {
        if (g_old_sigsys_action.sa_sigaction) {
            g_old_sigsys_action.sa_sigaction(signo, info, uctx);
        }
    } else if (g_old_sigsys_action.sa_handler != SIG_DFL && g_old_sigsys_action.sa_handler != SIG_IGN) {
        g_old_sigsys_action.sa_handler(signo);
    } else {
        signal(signo, SIG_DFL);
        raise(signo);
    }
}
} // namespace

void InstallBachataSigsysTrap() {
    // Install an alternate stack first: SA_ONSTACK redirects the signal here so
    // the handler runs even on an exhausted main stack.
    stack_t ss{};
    ss.ss_sp = g_sigsys_altstack.data();
    ss.ss_size = g_sigsys_altstack.size();
    ss.ss_flags = 0;
    sigaltstack(&ss, nullptr);

    struct sigaction sa{};
    sa.sa_sigaction = BachataSigsysHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSYS, &sa, &g_old_sigsys_action);
}

} // namespace Common
