"""
Home Video Library - Python Bindings
Uses ctypes to call the native library from Python
"""

import ctypes
import os
from typing import Optional, Tuple
from enum import IntEnum


# ============================================================================
# Find and load the library
# ============================================================================

def find_library():
    """Find the video library in zig-out/lib"""
    lib_names = [
        'libvideo.so',      # Linux
        'libvideo.dylib',   # macOS
        'video.dll',        # Windows
    ]

    # Look in ../../zig-out/lib relative to this file
    script_dir = os.path.dirname(os.path.abspath(__file__))
    lib_dir = os.path.join(script_dir, '..', '..', '..', 'zig-out', 'lib')

    for lib_name in lib_names:
        lib_path = os.path.join(lib_dir, lib_name)
        if os.path.exists(lib_path):
            return lib_path

    raise RuntimeError(f"Could not find video library in {lib_dir}")


# Load the library
_lib_path = find_library()
_lib = ctypes.CDLL(_lib_path)


# ============================================================================
# Error Codes
# ============================================================================

class VideoError(IntEnum):
    OK = 0
    INVALID_ARGUMENT = -1
    OUT_OF_MEMORY = -2
    FILE_NOT_FOUND = -3
    INVALID_FORMAT = -4
    UNSUPPORTED_CODEC = -5
    DECODE_ERROR = -6
    ENCODE_ERROR = -7
    IO_ERROR = -8
    UNKNOWN_ERROR = -999


class VideoException(Exception):
    """Exception raised by video operations"""
    def __init__(self, error_code: int, message: str = None):
        self.error_code = VideoError(error_code)
        self.message = message or get_last_error()
        super().__init__(f"{self.error_code.name}: {self.message}")


# ============================================================================
# Library Functions
# ============================================================================

# Initialization
_lib.video_init.argtypes = []
_lib.video_init.restype = ctypes.c_int

_lib.video_cleanup.argtypes = []
_lib.video_cleanup.restype = None

_lib.video_get_last_error.argtypes = []
_lib.video_get_last_error.restype = ctypes.c_char_p

# Version
_lib.video_version_major.argtypes = []
_lib.video_version_major.restype = ctypes.c_uint32

_lib.video_version_minor.argtypes = []
_lib.video_version_minor.restype = ctypes.c_uint32

_lib.video_version_patch.argtypes = []
_lib.video_version_patch.restype = ctypes.c_uint32

_lib.video_version_string.argtypes = []
_lib.video_version_string.restype = ctypes.c_char_p

# Audio
_lib.video_audio_load.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_audio_load.restype = ctypes.c_int

_lib.video_audio_load_from_memory.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_audio_load_from_memory.restype = ctypes.c_int

_lib.video_audio_save.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.video_audio_save.restype = ctypes.c_int

_lib.video_audio_encode.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.POINTER(ctypes.POINTER(ctypes.c_uint8)), ctypes.POINTER(ctypes.c_size_t)]
_lib.video_audio_encode.restype = ctypes.c_int

_lib.video_audio_duration.argtypes = [ctypes.c_void_p]
_lib.video_audio_duration.restype = ctypes.c_double

_lib.video_audio_sample_rate.argtypes = [ctypes.c_void_p]
_lib.video_audio_sample_rate.restype = ctypes.c_uint32

_lib.video_audio_channels.argtypes = [ctypes.c_void_p]
_lib.video_audio_channels.restype = ctypes.c_uint8

_lib.video_audio_total_samples.argtypes = [ctypes.c_void_p]
_lib.video_audio_total_samples.restype = ctypes.c_uint64

_lib.video_audio_free.argtypes = [ctypes.c_void_p]
_lib.video_audio_free.restype = None

# Video Frame
_lib.video_frame_create.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_frame_create.restype = ctypes.c_int

_lib.video_frame_width.argtypes = [ctypes.c_void_p]
_lib.video_frame_width.restype = ctypes.c_uint32

_lib.video_frame_height.argtypes = [ctypes.c_void_p]
_lib.video_frame_height.restype = ctypes.c_uint32

_lib.video_frame_free.argtypes = [ctypes.c_void_p]
_lib.video_frame_free.restype = None

# Filters
_lib.video_filter_scale.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_filter_scale.restype = ctypes.c_int

_lib.video_filter_crop.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_filter_crop.restype = ctypes.c_int

_lib.video_filter_grayscale.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_filter_grayscale.restype = ctypes.c_int

_lib.video_filter_blur.argtypes = [ctypes.c_void_p, ctypes.c_float, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_filter_blur.restype = ctypes.c_int

_lib.video_filter_rotate.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p)]
_lib.video_filter_rotate.restype = ctypes.c_int

# Codec Info
_lib.video_codec_name.argtypes = [ctypes.c_int32]
_lib.video_codec_name.restype = ctypes.c_char_p

_lib.video_codec_is_supported.argtypes = [ctypes.c_int32]
_lib.video_codec_is_supported.restype = ctypes.c_bool


# ============================================================================
# Helper Functions
# ============================================================================

def get_last_error() -> str:
    """Get the last error message from the library"""
    msg = _lib.video_get_last_error()
    return msg.decode('utf-8') if msg else "Unknown error"


def check_error(code: int):
    """Raise exception if error code is not OK"""
    if code != VideoError.OK:
        raise VideoException(code)


# ============================================================================
# Enums
# ============================================================================

class AudioFormat(IntEnum):
    WAV = 0
    MP3 = 1
    AAC = 2
    FLAC = 3
    OPUS = 4
    VORBIS = 5


class PixelFormat(IntEnum):
    RGB24 = 0
    RGBA32 = 1
    YUV420P = 2
    YUV422P = 3
    YUV444P = 4
    GRAY8 = 5


class VideoCodec(IntEnum):
    H264 = 0
    HEVC = 1
    VP9 = 2
    AV1 = 3
    VVC = 4


class ScaleAlgorithm(IntEnum):
    NEAREST = 0
    BILINEAR = 1
    BICUBIC = 2
    LANCZOS = 3


class RotationAngle(IntEnum):
    ROTATE_0 = 0
    ROTATE_90 = 1
    ROTATE_180 = 2
    ROTATE_270 = 3


# ============================================================================
# Python API
# ============================================================================

class Audio:
    """Audio file wrapper"""

    def __init__(self, handle: ctypes.c_void_p):
        self._handle = handle

    @classmethod
    def load(cls, path: str) -> 'Audio':
        """Load audio from file"""
        handle = ctypes.c_void_p()
        code = _lib.video_audio_load(path.encode('utf-8'), ctypes.byref(handle))
        check_error(code)
        return cls(handle)

    @classmethod
    def load_from_memory(cls, data: bytes) -> 'Audio':
        """Load audio from memory buffer"""
        handle = ctypes.c_void_p()
        buffer = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
        code = _lib.video_audio_load_from_memory(buffer, len(data), ctypes.byref(handle))
        check_error(code)
        return cls(handle)

    def save(self, path: str):
        """Save audio to file"""
        code = _lib.video_audio_save(self._handle, path.encode('utf-8'))
        check_error(code)

    def encode(self, format: AudioFormat) -> bytes:
        """Encode audio to bytes"""
        data_ptr = ctypes.POINTER(ctypes.c_uint8)()
        data_len = ctypes.c_size_t()
        code = _lib.video_audio_encode(self._handle, format, ctypes.byref(data_ptr), ctypes.byref(data_len))
        check_error(code)

        # Copy data to Python bytes
        result = bytes(data_ptr[:data_len.value])
        return result

    @property
    def duration(self) -> float:
        """Get audio duration in seconds"""
        return _lib.video_audio_duration(self._handle)

    @property
    def sample_rate(self) -> int:
        """Get sample rate in Hz"""
        return _lib.video_audio_sample_rate(self._handle)

    @property
    def channels(self) -> int:
        """Get channel count"""
        return _lib.video_audio_channels(self._handle)

    @property
    def total_samples(self) -> int:
        """Get total sample count"""
        return _lib.video_audio_total_samples(self._handle)

    def __del__(self):
        if hasattr(self, '_handle') and self._handle:
            _lib.video_audio_free(self._handle)


class VideoFrame:
    """Video frame wrapper"""

    def __init__(self, handle: ctypes.c_void_p):
        self._handle = handle

    @classmethod
    def create(cls, width: int, height: int, pixel_format: PixelFormat) -> 'VideoFrame':
        """Create a new video frame"""
        handle = ctypes.c_void_p()
        code = _lib.video_frame_create(width, height, pixel_format, ctypes.byref(handle))
        check_error(code)
        return cls(handle)

    @property
    def width(self) -> int:
        """Get frame width"""
        return _lib.video_frame_width(self._handle)

    @property
    def height(self) -> int:
        """Get frame height"""
        return _lib.video_frame_height(self._handle)

    def scale(self, width: int, height: int, algorithm: ScaleAlgorithm = ScaleAlgorithm.LANCZOS) -> 'VideoFrame':
        """Scale frame to new dimensions"""
        out_handle = ctypes.c_void_p()
        code = _lib.video_filter_scale(self._handle, width, height, algorithm, ctypes.byref(out_handle))
        check_error(code)
        return VideoFrame(out_handle)

    def crop(self, x: int, y: int, width: int, height: int) -> 'VideoFrame':
        """Crop frame"""
        out_handle = ctypes.c_void_p()
        code = _lib.video_filter_crop(self._handle, x, y, width, height, ctypes.byref(out_handle))
        check_error(code)
        return VideoFrame(out_handle)

    def grayscale(self) -> 'VideoFrame':
        """Convert to grayscale"""
        out_handle = ctypes.c_void_p()
        code = _lib.video_filter_grayscale(self._handle, ctypes.byref(out_handle))
        check_error(code)
        return VideoFrame(out_handle)

    def blur(self, sigma: float) -> 'VideoFrame':
        """Apply gaussian blur"""
        out_handle = ctypes.c_void_p()
        code = _lib.video_filter_blur(self._handle, sigma, ctypes.byref(out_handle))
        check_error(code)
        return VideoFrame(out_handle)

    def rotate(self, angle: RotationAngle) -> 'VideoFrame':
        """Rotate frame"""
        out_handle = ctypes.c_void_p()
        code = _lib.video_filter_rotate(self._handle, angle, ctypes.byref(out_handle))
        check_error(code)
        return VideoFrame(out_handle)

    def __del__(self):
        if hasattr(self, '_handle') and self._handle:
            _lib.video_frame_free(self._handle)


class CodecInfo:
    """Codec information utilities"""

    @staticmethod
    def name(codec: VideoCodec) -> str:
        """Get codec name"""
        name = _lib.video_codec_name(codec)
        return name.decode('utf-8')

    @staticmethod
    def is_supported(codec: VideoCodec) -> bool:
        """Check if codec is supported"""
        return _lib.video_codec_is_supported(codec)


# ============================================================================
# Initialization
# ============================================================================

def init():
    """Initialize the video library"""
    code = _lib.video_init()
    check_error(code)


def cleanup():
    """Cleanup the video library"""
    _lib.video_cleanup()


def version() -> Tuple[int, int, int]:
    """Get library version as (major, minor, patch)"""
    return (
        _lib.video_version_major(),
        _lib.video_version_minor(),
        _lib.video_version_patch()
    )


def version_string() -> str:
    """Get library version as string"""
    ver = _lib.video_version_string()
    return ver.decode('utf-8')


# ============================================================================
# Example Usage
# ============================================================================

if __name__ == "__main__":
    # Initialize
    init()

    print(f"Home Video Library v{version_string()}")
    print(f"Version: {version()}")

    # Example: Audio processing
    print("\n=== Audio Processing ===")
    try:
        audio = Audio.load("input.wav")
        print(f"Duration: {audio.duration:.2f}s")
        print(f"Sample rate: {audio.sample_rate}Hz")
        print(f"Channels: {audio.channels}")
        print(f"Total samples: {audio.total_samples}")

        # Encode to different formats
        wav_data = audio.encode(AudioFormat.WAV)
        print(f"WAV encoded: {len(wav_data)} bytes")

        aac_data = audio.encode(AudioFormat.AAC)
        print(f"AAC encoded: {len(aac_data)} bytes")

        audio.save("output.wav")
        print("Saved to output.wav")

        del audio  # Explicit cleanup
    except VideoException as e:
        print(f"Error: {e}")

    # Example: Video frame processing
    print("\n=== Video Frame Processing ===")
    try:
        frame = VideoFrame.create(1920, 1080, PixelFormat.RGB24)
        print(f"Created frame: {frame.width}x{frame.height}")

        # Chain filters
        processed = (frame
                    .scale(1280, 720, ScaleAlgorithm.LANCZOS)
                    .crop(100, 100, 1080, 520)
                    .grayscale()
                    .blur(1.5))

        print(f"Processed frame: {processed.width}x{processed.height}")

        del processed
        del frame
    except VideoException as e:
        print(f"Error: {e}")

    # Example: Codec info
    print("\n=== Codec Information ===")
    for codec in VideoCodec:
        name = CodecInfo.name(codec)
        supported = CodecInfo.is_supported(codec)
        status = "✓ supported" if supported else "✗ not supported"
        print(f"{name}: {status}")

    # Cleanup
    cleanup()
    print("\nDone!")
