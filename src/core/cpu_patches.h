// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include "common/arch.h"
#include "common/types.h"

// module.cpp's own two call sites (RegisterPatchModule, PrePatchInstructions) already guard
// themselves with #ifdef ARCH_X86_64 -- this header just needs the same guard, since these
// functions patch raw x86 machine code in place and have no meaning when guest x86 code never
// executes directly on host silicon (e.g. under FEX's ARM64-targeting JIT).
#ifdef ARCH_X86_64

namespace Core {

/// Registers a module for patching, providing an area to generate trampoline code.
void RegisterPatchModule(void* module_ptr, u64 module_size, void* trampoline_area_ptr,
                         u64 trampoline_area_size);

/// Applies CPU patches that need to be done before beginning executions.
void PrePatchInstructions(u64 segment_addr, u64 segment_size);

} // namespace Core

#endif // ARCH_X86_64
