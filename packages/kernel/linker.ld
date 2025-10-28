/* Home Programming Language - Kernel Linker Script
 * Memory layout and section placement for x86-64 kernel
 *
 * Memory Layout:
 * 0x0000000000000000 - 0x0000000000000fff : Null page (unmapped)
 * 0x0000000000001000 - 0x00000000000fffff : Low memory (BIOS, VGA, etc.)
 * 0x0000000000100000 - 0x00000000ffffffff : Kernel space
 * 0xffff800000000000 - 0xffffffffffffffff : Higher half kernel
 */

/* Entry point for the kernel */
ENTRY(_start)

/* Define memory regions */
MEMORY
{
    /* Kernel loaded at 1 MB physical address */
    RAM (rwx) : ORIGIN = 0x100000, LENGTH = 2M
}

/* Define output sections */
SECTIONS
{
    /* Set kernel base address to 1 MB */
    . = 0x100000;

    /* Provide kernel start symbol */
    __kernel_start = .;

    /* ========================================================================
     * Multiboot Header Section
     * Must be in first 32KB of kernel for bootloader to find it
     * ======================================================================== */
    .multiboot ALIGN(8) : AT(ADDR(.multiboot))
    {
        KEEP(*(.multiboot))
    }

    /* Ensure multiboot header is within first 32KB */
    ASSERT(SIZEOF(.multiboot) < 32K, "Multiboot header must be within first 32KB")

    /* ========================================================================
     * Text Section (Code)
     * ======================================================================== */
    .text ALIGN(4K) : AT(ADDR(.text))
    {
        __text_start = .;
        *(.text._start)         /* Entry point first */
        *(.text.kernel_main)    /* Kernel main second */
        *(.text*)               /* All other code */
        __text_end = .;
    }

    /* ========================================================================
     * Read-Only Data Section
     * ======================================================================== */
    .rodata ALIGN(4K) : AT(ADDR(.rodata))
    {
        __rodata_start = .;
        *(.rodata*)
        __rodata_end = .;
    }

    /* ========================================================================
     * Data Section (Initialized Data)
     * ======================================================================== */
    .data ALIGN(4K) : AT(ADDR(.data))
    {
        __data_start = .;
        *(.data*)
        __data_end = .;
    }

    /* ========================================================================
     * BSS Section (Uninitialized Data)
     * ======================================================================== */
    .bss ALIGN(4K) : AT(ADDR(.bss))
    {
        __bss_start = .;
        *(COMMON)
        *(.bss*)
        __bss_end = .;
    }

    /* ========================================================================
     * TLS (Thread-Local Storage) Section
     * ======================================================================== */
    .tdata ALIGN(4K) : AT(ADDR(.tdata))
    {
        __tdata_start = .;
        *(.tdata*)
        __tdata_end = .;
    }

    .tbss ALIGN(4K) : AT(ADDR(.tbss))
    {
        __tbss_start = .;
        *(.tbss*)
        __tbss_end = .;
    }

    /* ========================================================================
     * Debugging Sections (not loaded into memory)
     * ======================================================================== */
    .debug_info     0 : { *(.debug_info) }
    .debug_abbrev   0 : { *(.debug_abbrev) }
    .debug_line     0 : { *(.debug_line) }
    .debug_str      0 : { *(.debug_str) }
    .debug_loc      0 : { *(.debug_loc) }
    .debug_ranges   0 : { *(.debug_ranges) }
    .debug_frame    0 : { *(.debug_frame) }

    /* ========================================================================
     * Symbol Table and String Table (for debugging)
     * ======================================================================== */
    .symtab         0 : { *(.symtab) }
    .strtab         0 : { *(.strtab) }
    .shstrtab       0 : { *(.shstrtab) }

    /* ========================================================================
     * Kernel End Marker
     * ======================================================================== */
    . = ALIGN(4K);
    __kernel_end = .;

    /* ========================================================================
     * Discard Sections (not needed for kernel)
     * ======================================================================== */
    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.note*)
        *(.gcc_except_table)
    }
}

/* ============================================================================
 * Exported Symbols for Kernel
 * ============================================================================ */

/* Kernel boundaries */
PROVIDE(__kernel_physical_start = __kernel_start);
PROVIDE(__kernel_physical_end = __kernel_end);
PROVIDE(__kernel_size = __kernel_end - __kernel_start);

/* Section boundaries */
PROVIDE(__text_size = __text_end - __text_start);
PROVIDE(__rodata_size = __rodata_end - __rodata_start);
PROVIDE(__data_size = __data_end - __data_start);
PROVIDE(__bss_size = __bss_end - __bss_start);

/* TLS boundaries */
PROVIDE(__tls_start = __tdata_start);
PROVIDE(__tls_end = __tbss_end);
PROVIDE(__tls_size = __tls_end - __tls_start);

/* ============================================================================
 * Assertions
 * ============================================================================ */

/* Ensure kernel doesn't exceed 2MB */
ASSERT(__kernel_size < 2M, "Kernel exceeds 2MB size limit")

/* Ensure sections are page-aligned */
ASSERT(__text_start % 4K == 0, ".text section not page-aligned")
ASSERT(__rodata_start % 4K == 0, ".rodata section not page-aligned")
ASSERT(__data_start % 4K == 0, ".data section not page-aligned")
ASSERT(__bss_start % 4K == 0, ".bss section not page-aligned")

/* Ensure kernel is loaded at 1MB */
ASSERT(__kernel_start == 0x100000, "Kernel not loaded at 1MB boundary")
