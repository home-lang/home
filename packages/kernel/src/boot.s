// Home Programming Language - Boot Assembly
// Early boot code for x86-64 kernel initialization
//
// This file contains:
// - Multiboot2 header
// - 32-bit protected mode entry point
// - Initial page tables setup
// - Transition to 64-bit long mode
// - Jump to kernel main

.section .multiboot
.align 8

// ============================================================================
// Multiboot2 Header
// ============================================================================

multiboot2_header_start:
    // Magic number
    .long 0xe85250d6

    // Architecture: i386 (32-bit protected mode)
    .long 0

    // Header length
    .long multiboot2_header_end - multiboot2_header_start

    // Checksum: -(magic + architecture + header_length)
    .long -(0xe85250d6 + 0 + (multiboot2_header_end - multiboot2_header_start))

// ============================================================================
// Multiboot2 Tags
// ============================================================================

    // Information request tag - request memory map and framebuffer info
    .align 8
information_request_tag_start:
    .short 1                    // type = MULTIBOOT_HEADER_TAG_INFORMATION_REQUEST
    .short 0                    // flags
    .long information_request_tag_end - information_request_tag_start // size
    .long 6                     // MULTIBOOT_TAG_TYPE_MMAP
    .long 8                     // MULTIBOOT_TAG_TYPE_FRAMEBUFFER
    .long 14                    // MULTIBOOT_TAG_TYPE_ACPI_OLD
    .long 15                    // MULTIBOOT_TAG_TYPE_ACPI_NEW
information_request_tag_end:

    // Framebuffer tag - request graphics mode
    .align 8
framebuffer_tag_start:
    .short 5                    // type = MULTIBOOT_HEADER_TAG_FRAMEBUFFER
    .short 1                    // flags = optional
    .long framebuffer_tag_end - framebuffer_tag_start // size
    .long 1024                  // width
    .long 768                   // height
    .long 32                    // depth (bits per pixel)
framebuffer_tag_end:

    // Module alignment tag
    .align 8
module_align_tag_start:
    .short 6                    // type = MULTIBOOT_HEADER_TAG_MODULE_ALIGN
    .short 0                    // flags
    .long module_align_tag_end - module_align_tag_start // size
module_align_tag_end:

    // End tag
    .align 8
    .short 0                    // type = MULTIBOOT_HEADER_TAG_END
    .short 0                    // flags
    .long 8                     // size

multiboot2_header_end:

// ============================================================================
// Bootstrap Stack
// ============================================================================

.section .bss
.align 16

stack_bottom:
    .skip 16384                 // 16 KB stack
stack_top:

// ============================================================================
// Bootstrap Page Tables (Identity Mapping)
// ============================================================================

.align 4096
boot_pml4:
    .skip 4096                  // Page Map Level 4 (PML4)

boot_pdpt:
    .skip 4096                  // Page Directory Pointer Table (PDPT)

boot_pd:
    .skip 4096                  // Page Directory (PD)

// ============================================================================
// GDT for Long Mode
// ============================================================================

.section .rodata
.align 16

gdt64:
    .quad 0                     // Null descriptor

gdt64_code:
    // Code segment (64-bit)
    .quad (1<<43) | (1<<44) | (1<<47) | (1<<53)

gdt64_data:
    // Data segment
    .quad (1<<44) | (1<<47)

gdt64_pointer:
    .word gdt64_pointer - gdt64 - 1  // Limit
    .quad gdt64                       // Base

// ============================================================================
// 32-bit Entry Point (Protected Mode)
// ============================================================================

.section .text
.code32
.global _start
.type _start, @function

_start:
    // Disable interrupts
    cli

    // Save Multiboot2 information
    // EAX contains magic number (0x36d76289)
    // EBX contains physical address of Multiboot2 information structure
    movl %eax, multiboot2_magic
    movl %ebx, multiboot2_info

    // Setup initial stack
    movl $stack_top, %esp
    movl %esp, %ebp

    // Reset EFLAGS
    pushl $0
    popf

    // Check if we can use CPUID
    call check_cpuid
    testl %eax, %eax
    jz .no_cpuid

    // Check if long mode is available
    call check_long_mode
    testl %eax, %eax
    jz .no_long_mode

    // Setup page tables for identity mapping
    call setup_page_tables

    // Enable PAE (Physical Address Extension)
    movl %cr4, %eax
    orl $(1 << 5), %eax         // Set PAE bit
    movl %eax, %cr4

    // Load PML4 address into CR3
    movl $boot_pml4, %eax
    movl %eax, %cr3

    // Enable long mode in EFER MSR
    movl $0xC0000080, %ecx      // EFER MSR number
    rdmsr
    orl $(1 << 8), %eax         // Set LM (Long Mode) bit
    wrmsr

    // Enable paging and protected mode
    movl %cr0, %eax
    orl $(1 << 31) | (1 << 0), %eax  // Set PG (Paging) and PE (Protection Enable)
    movl %eax, %cr0

    // Load 64-bit GDT
    lgdt (gdt64_pointer)

    // Far jump to 64-bit code segment
    ljmp $0x08, $long_mode_start

.no_cpuid:
    // Print error message (CPUID not supported)
    movl $0xb8000, %edi
    movl $0x4f214f45, (%edi)    // "E!" in red
    hlt

.no_long_mode:
    // Print error message (Long mode not supported)
    movl $0xb8000, %edi
    movl $0x4f4d4f4c, (%edi)    // "LM" in red
    hlt

// ============================================================================
// Check if CPUID is supported
// ============================================================================

check_cpuid:
    // Try to flip ID bit (bit 21) in EFLAGS
    pushfl
    popl %eax
    movl %eax, %ecx             // Save original EFLAGS
    xorl $(1 << 21), %eax       // Flip ID bit
    pushl %eax
    popfl
    pushfl
    popl %eax

    // Check if bit was flipped
    xorl %ecx, %eax
    andl $(1 << 21), %eax

    // Restore original EFLAGS
    pushl %ecx
    popfl

    ret

// ============================================================================
// Check if long mode is available
// ============================================================================

check_long_mode:
    // Check if extended CPUID functions are available
    movl $0x80000000, %eax
    cpuid
    cmpl $0x80000001, %eax
    jb .no_extended_cpuid

    // Check if long mode is available
    movl $0x80000001, %eax
    cpuid
    testl $(1 << 29), %edx      // Check LM bit
    jz .no_long_mode_bit

    movl $1, %eax
    ret

.no_extended_cpuid:
.no_long_mode_bit:
    xorl %eax, %eax
    ret

// ============================================================================
// Setup Identity-Mapped Page Tables
// ============================================================================

setup_page_tables:
    // Zero out page tables
    movl $boot_pml4, %edi
    movl $3, %ecx               // 3 pages (PML4, PDPT, PD)
    xorl %eax, %eax
.zero_loop:
    movl $1024, %edx            // 1024 entries per page (4 bytes each)
.zero_inner:
    movl %eax, (%edi)
    addl $4, %edi
    decl %edx
    jnz .zero_inner
    decl %ecx
    jnz .zero_loop

    // Setup PML4[0] -> PDPT
    movl $boot_pml4, %edi
    movl $boot_pdpt, %eax
    orl $0x03, %eax             // Present + Writable
    movl %eax, (%edi)

    // Setup PDPT[0] -> PD
    movl $boot_pdpt, %edi
    movl $boot_pd, %eax
    orl $0x03, %eax             // Present + Writable
    movl %eax, (%edi)

    // Setup PD entries (identity map first 2 MB with 2MB pages)
    movl $boot_pd, %edi
    movl $0x83, %eax            // Present + Writable + Huge (2MB pages)
    movl $512, %ecx             // 512 entries (1 GB total)
.pd_loop:
    movl %eax, (%edi)
    addl $0x200000, %eax        // Next 2MB
    addl $8, %edi
    decl %ecx
    jnz .pd_loop

    ret

// ============================================================================
// 64-bit Entry Point (Long Mode)
// ============================================================================

.code64
.global long_mode_start
.type long_mode_start, @function

long_mode_start:
    // Clear segment registers
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    // Setup 64-bit stack
    movq $stack_top, %rsp
    movq %rsp, %rbp

    // Pass Multiboot2 info to kernel
    movl multiboot2_magic, %edi      // First argument: magic
    movl multiboot2_info, %esi       // Second argument: info address

    // Call kernel main function
    call kernel_main

    // If kernel returns, halt
    cli
.hang:
    hlt
    jmp .hang

// ============================================================================
// Data Section
// ============================================================================

.section .data

multiboot2_magic:
    .long 0

multiboot2_info:
    .long 0

// ============================================================================
// Symbol Exports
// ============================================================================

.global multiboot2_magic
.global multiboot2_info
