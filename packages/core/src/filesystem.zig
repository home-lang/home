// Home Language - Core Filesystem Module
// Re-export basics/filesystem

const basics_fs = @import("../../basics/src/filesystem.zig");

pub const File = basics_fs.File;
pub const Dir = basics_fs.Dir;
pub const exists = basics_fs.exists;
pub const isDirectory = basics_fs.isDirectory;
pub const isFile = basics_fs.isFile;
pub const readFile = basics_fs.readFile;
pub const writeFile = basics_fs.writeFile;
pub const appendFile = basics_fs.appendFile;
pub const deleteFile = basics_fs.deleteFile;
pub const createDirectory = basics_fs.createDirectory;
pub const deleteDirectory = basics_fs.deleteDirectory;
pub const copyFile = basics_fs.copyFile;
pub const moveFile = basics_fs.moveFile;
pub const fileSize = basics_fs.fileSize;
pub const getCurrentDirectory = basics_fs.getCurrentDirectory;
pub const setCurrentDirectory = basics_fs.setCurrentDirectory;
pub const absolutePath = basics_fs.absolutePath;
pub const joinPath = basics_fs.joinPath;
pub const dirname = basics_fs.dirname;
pub const basename = basics_fs.basename;
pub const extension = basics_fs.extension;
pub const DirectoryIterator = basics_fs.DirectoryIterator;
pub const listDirectory = basics_fs.listDirectory;
