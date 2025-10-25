// Home OS - ARM64 Boot Code
// Entry point for Raspberry Pi 3/4

.section .text.boot

// Kernel entry point - called by bootloader
.global _start
_start:
    // x0 = dtb address (passed by bootloader)
    // x1-x3 = reserved

    // Read CPU ID from MPIDR_EL1
    mrs     x4, mpidr_el1
    and     x4, x4, #0xFF

    // Only CPU 0 continues, others halt
    cbnz    x4, halt_cpu

    // Save DTB address for later
    ldr     x5, =dtb_address
    str     x0, [x5]

    // Disable interrupts
    msr     daifset, #0xF

    // Check current exception level
    mrs     x4, CurrentEL
    lsr     x4, x4, #2
    and     x4, x4, #3

    // If we're at EL3, drop to EL2
    cmp     x4, #3
    beq     drop_to_el2

    // If we're at EL2, drop to EL1
    cmp     x4, #2
    beq     drop_to_el1

    // Already at EL1, continue
    b       setup_mmu

drop_to_el2:
    // Configure EL3 -> EL2 transition
    mov     x0, #0x531              // RW=1 (AArch64), HCE=1, SMD=1, RES1=1
    msr     scr_el3, x0

    mov     x0, #0x3C9              // Mask all interrupts, EL2h mode
    msr     spsr_el3, x0

    adr     x0, drop_to_el1
    msr     elr_el3, x0

    eret

drop_to_el1:
    // Configure EL2 -> EL1 transition
    mov     x0, #(1 << 31)          // RW=1 (AArch64 for EL1)
    msr     hcr_el2, x0

    mov     x0, #0x3C5              // Mask all interrupts, EL1h mode (SP_EL1)
    msr     spsr_el2, x0

    adr     x0, setup_mmu
    msr     elr_el2, x0

    eret

setup_mmu:
    // Disable MMU and caches
    mrs     x0, sctlr_el1
    bic     x0, x0, #(1 << 0)       // Clear M bit (MMU)
    bic     x0, x0, #(1 << 2)       // Clear C bit (D-cache)
    bic     x0, x0, #(1 << 12)      // Clear I bit (I-cache)
    msr     sctlr_el1, x0
    isb

    // Set up memory attributes (MAIR_EL1)
    // Index 0: Normal memory, write-back cacheable
    // Index 1: Device memory (peripheral registers)
    ldr     x0, =0xFF00              // Attr1=Device, Attr0=Normal WB
    msr     mair_el1, x0

    // Set up translation control (TCR_EL1)
    // 48-bit address space, 4KB granule
    ldr     x0, =0x803510            // T0SZ=16 (48-bit), TG0=4KB, SH0=3, ORGN0=1, IRGN0=1
    msr     tcr_el1, x0

    // Set up initial page tables (identity map first 1GB + higher-half map)
    bl      setup_page_tables

    // Set TTBR0_EL1 (lower half - identity mapping)
    ldr     x0, =page_tables_start
    msr     ttbr0_el1, x0

    // Set TTBR1_EL1 (upper half - kernel mapping)
    ldr     x0, =page_tables_start
    msr     ttbr1_el1, x0

    // Invalidate TLB
    tlbi    vmalle1
    dsb     sy
    isb

    // Enable MMU and caches
    mrs     x0, sctlr_el1
    orr     x0, x0, #(1 << 0)       // Set M bit (MMU)
    orr     x0, x0, #(1 << 2)       // Set C bit (D-cache)
    orr     x0, x0, #(1 << 12)      // Set I bit (I-cache)
    msr     sctlr_el1, x0
    isb

    // Set up exception vectors
    ldr     x0, =exception_vectors
    msr     vbar_el1, x0

    // Clear BSS
    ldr     x0, =bss_start
    ldr     x1, =bss_end
clear_bss:
    cmp     x0, x1
    bge     bss_done
    str     xzr, [x0], #8
    b       clear_bss

bss_done:
    // Set up stack pointer (top of stack)
    ldr     x0, =stack_top
    mov     sp, x0

    // Jump to kernel main
    bl      kernel_main

    // Should never reach here
halt:
    wfe
    b       halt

halt_cpu:
    // Secondary CPUs wait here
    wfe
    b       halt_cpu

// ============================================================================
// Page Table Setup
// ============================================================================

setup_page_tables:
    // Clear page table area
    ldr     x0, =page_tables_start
    ldr     x1, =page_tables_end
    mov     x2, #0
clear_page_tables:
    cmp     x0, x1
    bge     clear_done
    str     x2, [x0], #8
    b       clear_page_tables

clear_done:
    // For simplicity, create 2MB block mappings for first 1GB
    // This covers RAM and peripherals for Raspberry Pi

    ldr     x0, =page_tables_start  // L1 table

    // Entry 0: Point to L2 table
    ldr     x1, =page_tables_start
    add     x1, x1, #0x1000         // L2 table at offset 4KB
    orr     x1, x1, #0x3            // Valid + Table descriptor
    str     x1, [x0]

    // Set up L2 table (512 entries, each covering 2MB)
    ldr     x0, =page_tables_start
    add     x0, x0, #0x1000         // L2 table

    mov     x1, #0                  // Physical address
    mov     x2, #512                // Number of entries

    // Block attributes:
    // [1:0] = 01 (block)
    // [10] = 1 (AF - access flag)
    // [9:8] = 00 (SH - non-shareable for now)
    // [7:6] = 00 (AP - kernel RW)
    // [4:2] = 000 (AttrIndx - normal memory)
    ldr     x3, =0x401              // Block descriptor with AF=1

create_l2_entries:
    cbz     x2, page_tables_done
    orr     x4, x1, x3
    str     x4, [x0], #8
    add     x1, x1, #0x200000       // 2MB per block
    sub     x2, x2, #1
    b       create_l2_entries

page_tables_done:
    ret

// ============================================================================
// Exception Vectors
// ============================================================================

.section .vectors
.balign 2048
exception_vectors:
    // Current EL with SP0
    .balign 128
    b       sync_exception_sp0
    .balign 128
    b       irq_exception_sp0
    .balign 128
    b       fiq_exception_sp0
    .balign 128
    b       serror_exception_sp0

    // Current EL with SPx
    .balign 128
    b       sync_exception_spx
    .balign 128
    b       irq_exception_spx
    .balign 128
    b       fiq_exception_spx
    .balign 128
    b       serror_exception_spx

    // Lower EL using AArch64
    .balign 128
    b       sync_exception_lower_64
    .balign 128
    b       irq_exception_lower_64
    .balign 128
    b       fiq_exception_lower_64
    .balign 128
    b       serror_exception_lower_64

    // Lower EL using AArch32
    .balign 128
    b       sync_exception_lower_32
    .balign 128
    b       irq_exception_lower_32
    .balign 128
    b       fiq_exception_lower_32
    .balign 128
    b       serror_exception_lower_32

// Default exception handlers - just halt for now
sync_exception_sp0:
sync_exception_spx:
sync_exception_lower_64:
sync_exception_lower_32:
irq_exception_sp0:
irq_exception_spx:
irq_exception_lower_64:
irq_exception_lower_32:
fiq_exception_sp0:
fiq_exception_spx:
fiq_exception_lower_64:
fiq_exception_lower_32:
serror_exception_sp0:
serror_exception_spx:
serror_exception_lower_64:
serror_exception_lower_32:
    wfe
    b       .

// ============================================================================
// Data Section
// ============================================================================

.section .data
.global dtb_address
dtb_address:
    .quad   0
