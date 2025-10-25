/* Home OS - ARM64 Kernel Linker Script */
/* For Raspberry Pi 3/4 (AArch64) */

OUTPUT_FORMAT(elf64-littleaarch64)
OUTPUT_ARCH(aarch64)
ENTRY(_start)

/* Kernel is loaded at 0x80000 physical (512KB) */
/* This is the standard load address for ARM64 kernels on Raspberry Pi */
KERNEL_PHYS_BASE = 0x80000;

/* Virtual mapping offset - we can use identity mapping initially */
/* or higher-half mapping at -2GB like x86-64 */
KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

SECTIONS
{
    /* Start at physical address 0x80000, mapped to higher-half virtual */
    . = KERNEL_VIRT_BASE + KERNEL_PHYS_BASE;
    kernel_start = .;

    /* Boot code - early initialization, runs before MMU is enabled */
    /* This must use position-independent code or physical addresses */
    .text.boot ALIGN(4K) : AT(ADDR(.text.boot) - KERNEL_VIRT_BASE)
    {
        *(.text.boot)
        *(.text.boot.*)
    }

    /* Exception vector table - must be aligned to 2KB */
    .vectors ALIGN(2K) : AT(ADDR(.vectors) - KERNEL_VIRT_BASE)
    {
        KEEP(*(.vectors))
    }

    /* Main text section - kernel code */
    .text ALIGN(4K) : AT(ADDR(.text) - KERNEL_VIRT_BASE)
    {
        *(.text)
        *(.text.*)
    }

    /* Read-only data */
    .rodata ALIGN(4K) : AT(ADDR(.rodata) - KERNEL_VIRT_BASE)
    {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    }

    /* Initialized data */
    .data ALIGN(4K) : AT(ADDR(.data) - KERNEL_VIRT_BASE)
    {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    }

    /* Uninitialized data (BSS) */
    .bss ALIGN(4K) : AT(ADDR(.bss) - KERNEL_VIRT_BASE)
    {
        bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        bss_end = .;
    }

    /* Thread-local storage */
    .tdata ALIGN(4K) : AT(ADDR(.tdata) - KERNEL_VIRT_BASE)
    {
        *(.tdata)
        *(.tdata.*)
    }

    .tbss ALIGN(4K) : AT(ADDR(.tbss) - KERNEL_VIRT_BASE)
    {
        *(.tbss)
        *(.tbss.*)
    }

    /* GCC exception handling data */
    .gcc_except_table ALIGN(4K) : AT(ADDR(.gcc_except_table) - KERNEL_VIRT_BASE)
    {
        *(.gcc_except_table)
        *(.gcc_except_table.*)
    }

    /* ARM-specific unwind tables */
    .ARM.exidx ALIGN(4K) : AT(ADDR(.ARM.exidx) - KERNEL_VIRT_BASE)
    {
        __exidx_start = .;
        *(.ARM.exidx*)
        __exidx_end = .;
    }

    .ARM.extab ALIGN(4K) : AT(ADDR(.ARM.extab) - KERNEL_VIRT_BASE)
    {
        *(.ARM.extab*)
    }

    /* Page table space - allocate space for initial page tables */
    /* We need space for:
     * - Level 1 (512GB per entry): 1 table
     * - Level 2 (1GB per entry): 1 table
     * - Level 3 (2MB per entry): 1 table
     * - Level 4 (4KB per entry): multiple tables
     */
    .page_tables ALIGN(4K) : AT(ADDR(.page_tables) - KERNEL_VIRT_BASE)
    {
        page_tables_start = .;
        . += 64K; /* 16 pages for initial page tables */
        page_tables_end = .;
    }

    /* Stack space - allocate initial kernel stack */
    .stack ALIGN(4K) : AT(ADDR(.stack) - KERNEL_VIRT_BASE)
    {
        stack_bottom = .;
        . += 64K; /* 64KB stack per CPU core */
        stack_top = .;
    }

    kernel_end = .;
    kernel_size = kernel_end - kernel_start;

    /* Discard unwanted sections */
    /DISCARD/ :
    {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.note*)
        *(.comment)
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
        *(.gnu.version*)
    }
}

/* Define symbols for use in kernel code */
PROVIDE(kernel_phys_start = KERNEL_PHYS_BASE);
PROVIDE(kernel_virt_start = KERNEL_VIRT_BASE + KERNEL_PHYS_BASE);
PROVIDE(kernel_phys_end = kernel_end - KERNEL_VIRT_BASE);

/* Stack guards */
PROVIDE(__stack_chk_guard = 0xDEADBEEF);
PROVIDE(__stack_chk_fail = 0x0);
