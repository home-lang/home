/**
 * Home Video Library - C API
 * Native video/audio processing library with C-compatible interface
 *
 * This header provides a C API for applications written in C, C++, or other
 * languages that can interface with C libraries.
 */

#ifndef HOME_VIDEO_H
#define HOME_VIDEO_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Error Codes
// ============================================================================

typedef enum {
    VIDEO_OK = 0,
    VIDEO_INVALID_ARGUMENT = -1,
    VIDEO_OUT_OF_MEMORY = -2,
    VIDEO_FILE_NOT_FOUND = -3,
    VIDEO_INVALID_FORMAT = -4,
    VIDEO_UNSUPPORTED_CODEC = -5,
    VIDEO_DECODE_ERROR = -6,
    VIDEO_ENCODE_ERROR = -7,
    VIDEO_IO_ERROR = -8,
    VIDEO_UNKNOWN_ERROR = -999
} video_error_t;

/**
 * Get the last error message
 * @return Null-terminated error message string
 */
const char* video_get_last_error(void);

// ============================================================================
// Initialization and Cleanup
// ============================================================================

/**
 * Initialize the video library
 * Call this before using any other library functions
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_init(void);

/**
 * Cleanup and free all resources used by the library
 * Call this when you're done using the library
 */
void video_cleanup(void);

// ============================================================================
// Version Information
// ============================================================================

/**
 * Get library major version
 * @return Major version number
 */
uint32_t video_version_major(void);

/**
 * Get library minor version
 * @return Minor version number
 */
uint32_t video_version_minor(void);

/**
 * Get library patch version
 * @return Patch version number
 */
uint32_t video_version_patch(void);

/**
 * Get library version string
 * @return Version string (e.g., "0.1.0")
 */
const char* video_version_string(void);

// ============================================================================
// Memory Management
// ============================================================================

/**
 * Allocate memory using the library's allocator
 * @param size Number of bytes to allocate
 * @return Pointer to allocated memory, or NULL on failure
 */
void* video_alloc(size_t size);

/**
 * Free memory allocated by video_alloc
 * @param ptr Pointer to free
 * @param size Size of allocation
 */
void video_free(void* ptr, size_t size);

/**
 * Free a string returned by the library
 * @param str String to free
 */
void video_free_string(const char* str);

// ============================================================================
// Audio API
// ============================================================================

/**
 * Load audio from file
 * @param path File path
 * @param out_handle Output handle to audio object
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_audio_load(const char* path, void** out_handle);

/**
 * Load audio from memory buffer
 * @param data Audio data bytes
 * @param data_len Length of data
 * @param out_handle Output handle to audio object
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_audio_load_from_memory(const uint8_t* data, size_t data_len, void** out_handle);

/**
 * Save audio to file
 * @param handle Audio handle
 * @param path Output file path
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_audio_save(void* handle, const char* path);

/**
 * Encode audio to bytes in specified format
 * @param handle Audio handle
 * @param format Audio format (0=WAV, 1=MP3, 2=AAC, 3=FLAC, 4=Opus, 5=Vorbis)
 * @param out_data Output data pointer
 * @param out_len Output data length
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_audio_encode(void* handle, int32_t format, uint8_t** out_data, size_t* out_len);

/**
 * Get audio duration in seconds
 * @param handle Audio handle
 * @return Duration in seconds
 */
double video_audio_duration(void* handle);

/**
 * Get audio sample rate
 * @param handle Audio handle
 * @return Sample rate in Hz
 */
uint32_t video_audio_sample_rate(void* handle);

/**
 * Get audio channel count
 * @param handle Audio handle
 * @return Number of channels
 */
uint8_t video_audio_channels(void* handle);

/**
 * Get total sample count
 * @param handle Audio handle
 * @return Total number of samples (per channel)
 */
uint64_t video_audio_total_samples(void* handle);

/**
 * Free audio handle
 * @param handle Audio handle to free
 */
void video_audio_free(void* handle);

// ============================================================================
// Video Frame API
// ============================================================================

/**
 * Create a new video frame
 * @param width Frame width in pixels
 * @param height Frame height in pixels
 * @param pixel_format Pixel format (0=RGB24, 1=RGBA32, 2=YUV420P, etc.)
 * @param out_handle Output handle to frame object
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_frame_create(uint32_t width, uint32_t height, int32_t pixel_format, void** out_handle);

/**
 * Get frame width
 * @param handle Frame handle
 * @return Width in pixels
 */
uint32_t video_frame_width(void* handle);

/**
 * Get frame height
 * @param handle Frame handle
 * @return Height in pixels
 */
uint32_t video_frame_height(void* handle);

/**
 * Get frame pixel format
 * @param handle Frame handle
 * @return Pixel format code
 */
int32_t video_frame_pixel_format(void* handle);

/**
 * Get frame data pointer for plane
 * @param handle Frame handle
 * @param plane Plane index (0 for packed formats)
 * @return Pointer to plane data
 */
uint8_t* video_frame_data(void* handle, uint8_t plane);

/**
 * Get frame linesize (stride) for plane
 * @param handle Frame handle
 * @param plane Plane index
 * @return Linesize in bytes
 */
size_t video_frame_linesize(void* handle, uint8_t plane);

/**
 * Free video frame
 * @param handle Frame handle to free
 */
void video_frame_free(void* handle);

// ============================================================================
// Video Filters
// ============================================================================

/**
 * Apply scale filter to video frame
 * @param src_handle Source frame handle
 * @param dst_width Destination width
 * @param dst_height Destination height
 * @param algorithm Scale algorithm (0=Nearest, 1=Bilinear, 2=Bicubic, 3=Lanczos)
 * @param out_handle Output frame handle
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_filter_scale(void* src_handle, uint32_t dst_width, uint32_t dst_height,
                                 int32_t algorithm, void** out_handle);

/**
 * Apply crop filter to video frame
 * @param src_handle Source frame handle
 * @param x Crop X position
 * @param y Crop Y position
 * @param width Crop width
 * @param height Crop height
 * @param out_handle Output frame handle
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_filter_crop(void* src_handle, uint32_t x, uint32_t y,
                                uint32_t width, uint32_t height, void** out_handle);

/**
 * Apply grayscale filter to video frame
 * @param src_handle Source frame handle
 * @param out_handle Output frame handle
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_filter_grayscale(void* src_handle, void** out_handle);

/**
 * Apply blur filter to video frame
 * @param src_handle Source frame handle
 * @param sigma Blur sigma (higher = more blur)
 * @param out_handle Output frame handle
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_filter_blur(void* src_handle, float sigma, void** out_handle);

/**
 * Apply rotate filter to video frame
 * @param src_handle Source frame handle
 * @param angle Rotation angle (0=0°, 1=90°, 2=180°, 3=270°)
 * @param out_handle Output frame handle
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_filter_rotate(void* src_handle, int32_t angle, void** out_handle);

// ============================================================================
// Media File API
// ============================================================================

/**
 * Open media file for reading
 * @param path File path
 * @param out_handle Output handle to media file object
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_media_open(const char* path, void** out_handle);

/**
 * Get stream count in media file
 * @param handle Media file handle
 * @return Number of streams
 */
uint32_t video_media_stream_count(void* handle);

/**
 * Get stream information
 * @param handle Media file handle
 * @param stream_index Stream index
 * @param out_type Output stream type (0=Video, 1=Audio, 2=Subtitle)
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_media_stream_info(void* handle, uint32_t stream_index, int32_t* out_type);

/**
 * Free media file handle
 * @param handle Media file handle to free
 */
void video_media_free(void* handle);

// ============================================================================
// Subtitle API
// ============================================================================

/**
 * Parse SRT subtitle data
 * @param data SRT data bytes
 * @param data_len Length of data
 * @param out_cue_count Output number of cues parsed
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_subtitle_parse_srt(const uint8_t* data, size_t data_len, size_t* out_cue_count);

/**
 * Convert SRT to VTT format
 * @param srt_data SRT data bytes
 * @param srt_len Length of SRT data
 * @param out_vtt Output VTT data (caller must free with video_free)
 * @param out_len Output VTT data length
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_subtitle_srt_to_vtt(const uint8_t* srt_data, size_t srt_len,
                                       uint8_t** out_vtt, size_t* out_len);

// ============================================================================
// Thumbnail API
// ============================================================================

/**
 * Extract thumbnail at timestamp
 * @param video_path Video file path
 * @param timestamp_us Timestamp in microseconds
 * @param width Thumbnail width
 * @param height Thumbnail height
 * @param out_handle Output frame handle
 * @return VIDEO_OK on success, error code otherwise
 */
video_error_t video_thumbnail_extract(const char* video_path, int64_t timestamp_us,
                                     uint32_t width, uint32_t height, void** out_handle);

// ============================================================================
// Codec Information
// ============================================================================

/**
 * Get codec name as string
 * @param codec Codec ID (0=H264, 1=HEVC, 2=VP9, 3=AV1, 4=VVC)
 * @return Codec name string
 */
const char* video_codec_name(int32_t codec);

/**
 * Check if codec is supported
 * @param codec Codec ID
 * @return true if supported, false otherwise
 */
bool video_codec_is_supported(int32_t codec);

#ifdef __cplusplus
}
#endif

#endif // HOME_VIDEO_H
