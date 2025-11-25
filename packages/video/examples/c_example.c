/**
 * Home Video Library - C Usage Example
 * Demonstrates how to use the video library from C
 */

#include "../include/video.h"
#include <stdio.h>
#include <stdlib.h>

void example_audio(void) {
    printf("\n=== Audio Processing Example ===\n");

    void* audio_handle = NULL;
    video_error_t err;

    // Load audio file
    err = video_audio_load("input.wav", &audio_handle);
    if (err != VIDEO_OK) {
        fprintf(stderr, "Failed to load audio: %s\n", video_get_last_error());
        return;
    }

    // Get audio properties
    double duration = video_audio_duration(audio_handle);
    uint32_t sample_rate = video_audio_sample_rate(audio_handle);
    uint8_t channels = video_audio_channels(audio_handle);
    uint64_t total_samples = video_audio_total_samples(audio_handle);

    printf("Duration: %.2fs\n", duration);
    printf("Sample rate: %u Hz\n", sample_rate);
    printf("Channels: %u\n", channels);
    printf("Total samples: %llu\n", (unsigned long long)total_samples);

    // Encode to AAC
    uint8_t* aac_data = NULL;
    size_t aac_len = 0;
    err = video_audio_encode(audio_handle, 2, &aac_data, &aac_len); // 2 = AAC
    if (err == VIDEO_OK) {
        printf("AAC encoded: %zu bytes\n", aac_len);
        video_free(aac_data, aac_len);
    }

    // Save to file
    err = video_audio_save(audio_handle, "output.wav");
    if (err == VIDEO_OK) {
        printf("Saved to output.wav\n");
    }

    // Cleanup
    video_audio_free(audio_handle);
}

void example_video_filters(void) {
    printf("\n=== Video Filter Example ===\n");

    void* frame = NULL;
    video_error_t err;

    // Create a 1920x1080 RGB frame
    err = video_frame_create(1920, 1080, 0, &frame); // 0 = RGB24
    if (err != VIDEO_OK) {
        fprintf(stderr, "Failed to create frame: %s\n", video_get_last_error());
        return;
    }

    uint32_t width = video_frame_width(frame);
    uint32_t height = video_frame_height(frame);
    printf("Created frame: %ux%u\n", width, height);

    // Scale to 1280x720
    void* scaled = NULL;
    err = video_filter_scale(frame, 1280, 720, 3, &scaled); // 3 = Lanczos
    if (err == VIDEO_OK) {
        printf("Scaled to: %ux%u\n", video_frame_width(scaled), video_frame_height(scaled));

        // Apply grayscale
        void* gray = NULL;
        err = video_filter_grayscale(scaled, &gray);
        if (err == VIDEO_OK) {
            printf("Applied grayscale filter\n");

            // Apply blur
            void* blurred = NULL;
            err = video_filter_blur(gray, 1.5f, &blurred);
            if (err == VIDEO_OK) {
                printf("Applied blur filter (sigma=1.5)\n");
                video_frame_free(blurred);
            }

            video_frame_free(gray);
        }

        video_frame_free(scaled);
    }

    video_frame_free(frame);
}

void example_codec_info(void) {
    printf("\n=== Codec Information ===\n");

    const int codecs[] = {0, 1, 2, 3, 4}; // H264, HEVC, VP9, AV1, VVC
    const int num_codecs = sizeof(codecs) / sizeof(codecs[0]);

    for (int i = 0; i < num_codecs; i++) {
        const char* name = video_codec_name(codecs[i]);
        bool supported = video_codec_is_supported(codecs[i]);

        printf("%s: %s\n", name, supported ? "✓ supported" : "✗ not supported");
        // Note: Don't free name - it's a static string from the library
    }
}

void example_crop_and_rotate(void) {
    printf("\n=== Crop and Rotate Example ===\n");

    void* frame = NULL;
    video_error_t err;

    // Create frame
    err = video_frame_create(1920, 1080, 0, &frame);
    if (err != VIDEO_OK) {
        fprintf(stderr, "Failed to create frame\n");
        return;
    }

    // Crop to center 1280x720
    void* cropped = NULL;
    err = video_filter_crop(frame, 320, 180, 1280, 720, &cropped);
    if (err == VIDEO_OK) {
        printf("Cropped to: %ux%u\n", video_frame_width(cropped), video_frame_height(cropped));

        // Rotate 90 degrees
        void* rotated = NULL;
        err = video_filter_rotate(cropped, 1, &rotated); // 1 = 90 degrees
        if (err == VIDEO_OK) {
            printf("Rotated to: %ux%u\n", video_frame_width(rotated), video_frame_height(rotated));
            video_frame_free(rotated);
        }

        video_frame_free(cropped);
    }

    video_frame_free(frame);
}

void example_audio_memory(void) {
    printf("\n=== Audio from Memory Example ===\n");

    // Simulate loading file into memory
    FILE* f = fopen("input.wav", "rb");
    if (!f) {
        fprintf(stderr, "Failed to open input.wav\n");
        return;
    }

    // Get file size
    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    // Allocate buffer
    uint8_t* buffer = (uint8_t*)malloc(file_size);
    if (!buffer) {
        fclose(f);
        fprintf(stderr, "Out of memory\n");
        return;
    }

    // Read file
    size_t read = fread(buffer, 1, file_size, f);
    fclose(f);

    if (read != (size_t)file_size) {
        free(buffer);
        fprintf(stderr, "Failed to read file\n");
        return;
    }

    // Load audio from memory
    void* audio = NULL;
    video_error_t err = video_audio_load_from_memory(buffer, file_size, &audio);
    free(buffer); // Can free buffer after loading

    if (err == VIDEO_OK) {
        double duration = video_audio_duration(audio);
        printf("Loaded from memory: %.2fs\n", duration);
        video_audio_free(audio);
    } else {
        fprintf(stderr, "Failed to load from memory: %s\n", video_get_last_error());
    }
}

int main(void) {
    // Initialize library
    video_error_t err = video_init();
    if (err != VIDEO_OK) {
        fprintf(stderr, "Failed to initialize: %s\n", video_get_last_error());
        return 1;
    }

    // Print version
    printf("Home Video Library v%s\n", video_version_string());
    printf("Version: %u.%u.%u\n",
           video_version_major(),
           video_version_minor(),
           video_version_patch());

    // Run examples
    example_audio();
    example_video_filters();
    example_codec_info();
    example_crop_and_rotate();
    example_audio_memory();

    // Cleanup
    video_cleanup();

    printf("\nAll examples completed!\n");
    return 0;
}

/**
 * Compilation instructions:
 *
 * 1. Build the video library first:
 *    cd packages/video
 *    zig build
 *
 * 2. Compile this example:
 *    gcc c_example.c -I../include -L../../zig-out/lib -lvideo -o c_example
 *
 * 3. Run:
 *    ./c_example
 *
 * Note: You may need to set LD_LIBRARY_PATH or DYLD_LIBRARY_PATH
 * to find the shared library at runtime:
 *
 * Linux:
 *   export LD_LIBRARY_PATH=../../zig-out/lib:$LD_LIBRARY_PATH
 *   ./c_example
 *
 * macOS:
 *   export DYLD_LIBRARY_PATH=../../zig-out/lib:$DYLD_LIBRARY_PATH
 *   ./c_example
 */
