/* Home OS - Kernel Linker Script */
/* x86-64 Higher-half kernel */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* Kernel is loaded at 2MB physical, mapped to -2GB virtual */
KERNEL_PHYS_BASE = 0x200000;
KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

SECTIONS
{
    . = KERNEL_VIRT_BASE + KERNEL_PHYS_BASE;
    kernel_start = .;

    /* Multiboot2 header - must be in first 8KB */
    .multiboot ALIGN(4K) : AT(ADDR(.multiboot) - KERNEL_VIRT_BASE)
    {
        KEEP(*(.multiboot))
        KEEP(*(.multiboot2))
    }

    /* Boot code - early initialization */
    .text.boot ALIGN(4K) : AT(ADDR(.text.boot) - KERNEL_VIRT_BASE)
    {
        *(.text.boot)
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

    kernel_end = .;
    kernel_size = kernel_end - kernel_start;

    /* Discard unwanted sections */
    /DISCARD/ :
    {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.note.*)
        *(.comment)
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
    }
}

/* Define symbols for use in kernel code */
PROVIDE(kernel_phys_start = KERNEL_PHYS_BASE);
PROVIDE(kernel_virt_start = KERNEL_VIRT_BASE + KERNEL_PHYS_BASE);
