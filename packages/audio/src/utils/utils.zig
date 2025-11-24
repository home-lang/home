// Home Audio Library - Utilities Module
// Playlist parsing, batch conversion, and other utilities

pub const playlist = @import("playlist.zig");
pub const batch = @import("batch.zig");

// Re-export main types
pub const Playlist = playlist.Playlist;
pub const PlaylistEntry = playlist.PlaylistEntry;
pub const PlaylistFormat = playlist.PlaylistFormat;
pub const M3uParser = playlist.M3uParser;
pub const PlsParser = playlist.PlsParser;
pub const M3uWriter = playlist.M3uWriter;
pub const PlsWriter = playlist.PlsWriter;

pub const BatchConverter = batch.BatchConverter;
pub const BatchOptions = batch.BatchOptions;
pub const BatchStatistics = batch.BatchStatistics;
pub const ConversionJob = batch.ConversionJob;
pub const ConversionPreset = batch.ConversionPreset;
pub const OutputFormat = batch.OutputFormat;
pub const QualityLevel = batch.QualityLevel;
pub const JobStatus = batch.JobStatus;

test "utils module" {
    _ = playlist;
    _ = batch;
}
