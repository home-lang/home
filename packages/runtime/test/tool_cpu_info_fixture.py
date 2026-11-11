"""Compare the tool's CPU snapshot with native reads, never another JS runtime."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys


def darwin():
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    def sysctl(name, size):
        buffer = ctypes.create_string_buffer(size)
        length = ctypes.c_size_t(size)
        if libc.sysctlbyname(name, buffer, ctypes.byref(length), None, 0):
            return None
        return buffer.raw[:length.value]
    model = sysctl(b'machdep.cpu.brand_string', 512) or sysctl(b'hw.model', 512)
    assert model, 'native CPU model unavailable'
    raw_frequency = sysctl(b'hw.cpufrequency', 8)
    frequency = int.from_bytes(raw_frequency, sys.byteorder) if raw_frequency else 0
    host = libc.mach_host_self()
    task = ctypes.c_uint.in_dll(libc, 'mach_task_self_').value
    processors = ctypes.c_uint()
    words = ctypes.c_uint()
    info = ctypes.POINTER(ctypes.c_uint)()
    libc.host_processor_info.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.POINTER(ctypes.c_uint)), ctypes.POINTER(ctypes.c_uint)]
    libc.vm_deallocate.argtypes = [ctypes.c_uint, ctypes.c_size_t, ctypes.c_size_t]
    libc.mach_port_deallocate.argtypes = [ctypes.c_uint, ctypes.c_uint]
    try:
        assert libc.host_processor_info(host, 2, ctypes.byref(processors), ctypes.byref(info), ctypes.byref(words)) == 0
        try:
            assert processors.value > 0 and words.value == processors.value * 4
            hz = os.sysconf('SC_CLK_TCK')
            return [{'model': model.rstrip(b'\0').decode(), 'speed': frequency // 1_000_000,
                     'times': {key: info[i * 4 + field] * 1000 // hz for key, field in
                               [('user', 0), ('nice', 3), ('sys', 1), ('idle', 2)]} | {'irq': 0}}
                    for i in range(processors.value)]
        finally:
            assert libc.vm_deallocate(task, ctypes.cast(info, ctypes.c_void_p).value, words.value * 4) == 0
    finally:
        assert libc.mach_port_deallocate(task, host) == 0


def linux():
    hz = os.sysconf('SC_CLK_TCK')
    models = {}
    for block in Path('/proc/cpuinfo').read_text().split('\n\n'):
        fields = dict(line.split(':', 1) for line in block.splitlines() if ':' in line)
        fields = {key.strip(): value.strip() for key, value in fields.items()}
        if fields.get('processor', '').isdigit():
            models[int(fields['processor'])] = next((fields[k] for k in ['model name', 'cpu model', 'CPU part', 'Processor', 'cpu', 'cpu family'] if fields.get(k)), 'unknown')
    result = {}
    for line in Path('/proc/stat').read_text().splitlines():
        columns = line.split()
        if not columns or not columns[0].startswith('cpu') or not columns[0][3:].isdigit():
            continue
        cpu_id = int(columns[0][3:])
        result[cpu_id] = {'model': models.get(cpu_id, 'unknown'),
                          'times': {key: int(columns[field]) * 1000 // hz for key, field in
                                    [('user', 1), ('nice', 2), ('sys', 3), ('idle', 4), ('irq', 6)]}}
    assert result
    return [result[cpu_id] for cpu_id in sorted(result)]


def main():
    native = {'darwin': darwin, 'linux': linux}[sys.platform]
    before = native()
    run = subprocess.run([sys.argv[1], 'run', sys.argv[2]], capture_output=True, text=True, timeout=30)
    if run.returncode:
        raise RuntimeError(run.stdout + run.stderr)
    after = native()
    lines = run.stdout.splitlines()
    assert len(lines) == 2 and lines[0] == 'NODE CPU INFORMATION 14 CHECKS OK', run.stdout
    actual = json.loads(lines[1])
    assert len(before) == len(actual) == len(after), 'CPU count differs from kernel'
    for low, cpu, high in zip(before, actual, after, strict=True):
        assert low['model'] == cpu['model'] == high['model'], 'model differs from kernel'
        if sys.platform == 'darwin':
            assert low['speed'] == cpu['speed'] == high['speed'], 'clock differs from sysctl'
        for key in ['user', 'nice', 'sys', 'idle', 'irq']:
            assert low['times'][key] <= cpu['times'][key] <= high['times'][key], (key, low, cpu, high)
    print(lines[0])
    print('NATIVE CPU SNAPSHOT MATCHES HOST')


if __name__ == '__main__':
    main()
