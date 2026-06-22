/// Abstract virtual filesystem interface and supporting value types.
///
/// Ported from `fs/interface.ts` in upstream just-bash. All operations are
/// asynchronous; synchronous variants are intentionally not part of the
/// interface.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dbash/src/fs/encoding.dart';

export 'package:dbash/src/fs/encoding.dart' show BufferEncoding;

/// A producer for lazily-materialized file content. Returns a [String] or a
/// list of bytes, either synchronously or as a [Future].
typedef LazyFileProvider = FutureOr<Object> Function();

/// Stat result describing a filesystem entry.
class FsStat {
  /// Creates a stat result.
  const FsStat({
    required this.isFile,
    required this.isDirectory,
    required this.isSymbolicLink,
    required this.mode,
    required this.size,
    required this.mtime,
  });

  /// Whether the entry is a regular file.
  final bool isFile;

  /// Whether the entry is a directory.
  final bool isDirectory;

  /// Whether the entry is a symbolic link.
  final bool isSymbolicLink;

  /// The permission bits.
  final int mode;

  /// The size in bytes (0 for directories).
  final int size;

  /// The modification time.
  final DateTime mtime;
}

/// A directory entry with type information, returned by
/// [FileSystem.readdirWithFileTypes] to avoid a stat per child.
class DirentEntry {
  /// Creates a directory entry.
  const DirentEntry({
    required this.name,
    required this.isFile,
    required this.isDirectory,
    required this.isSymbolicLink,
  });

  /// The entry name (not a full path).
  final String name;

  /// Whether the entry is a regular file.
  final bool isFile;

  /// Whether the entry is a directory.
  final bool isDirectory;

  /// Whether the entry is a symbolic link.
  final bool isSymbolicLink;
}

/// Extended file initialization with optional metadata.
class FileInit {
  /// Creates a file initializer with [content] and optional [mode]/[mtime].
  const FileInit(this.content, {this.mode, this.mtime});

  /// The file content (a [String] or list of bytes).
  final Object content;

  /// The permission bits, or `null` for the default.
  final int? mode;

  /// The modification time, or `null` for "now".
  final DateTime? mtime;
}

/// Abstract filesystem interface that can be backed by different
/// implementations (in-memory, mountable, real-FS overlay, etc.).
abstract class FileSystem {
  /// Read the contents of a file as decoded text (default UTF-8).
  Future<String> readFile(String path, {BufferEncoding? encoding});

  /// Read the raw bytes of a file.
  Future<Uint8List> readFileBuffer(String path);

  /// Write [content] (a [String] or list of bytes) to a file, creating it if
  /// it does not exist.
  Future<void> writeFile(
    String path,
    Object content, {
    BufferEncoding? encoding,
  });

  /// Append [content] to a file, creating it if it does not exist.
  Future<void> appendFile(
    String path,
    Object content, {
    BufferEncoding? encoding,
  });

  /// Whether [path] exists.
  Future<bool> exists(String path);

  /// Get information about [path], following symlinks.
  Future<FsStat> stat(String path);

  /// Get information about [path] without following the final symlink.
  Future<FsStat> lstat(String path);

  /// Create a directory at [path].
  Future<void> mkdir(String path, {bool recursive = false});

  /// List the names of the entries in directory [path].
  Future<List<String>> readdir(String path);

  /// List the entries of directory [path] with type information.
  Future<List<DirentEntry>> readdirWithFileTypes(String path);

  /// Remove the file or directory at [path].
  Future<void> rm(String path, {bool recursive = false, bool force = false});

  /// Copy [src] to [dest].
  Future<void> cp(String src, String dest, {bool recursive = false});

  /// Move/rename [src] to [dest].
  Future<void> mv(String src, String dest);

  /// Resolve a relative [path] against [base].
  String resolvePath(String base, String path);

  /// All known paths (used for glob matching). May be empty if unsupported.
  List<String> getAllPaths();

  /// Change the permission bits of [path].
  Future<void> chmod(String path, int mode);

  /// Create a symbolic link at [linkPath] pointing to [target].
  Future<void> symlink(String target, String linkPath);

  /// Create a hard link at [newPath] referring to [existingPath].
  Future<void> link(String existingPath, String newPath);

  /// Read the target of the symbolic link at [path].
  Future<String> readlink(String path);

  /// Resolve all symlinks in [path] to its canonical physical path.
  Future<String> realpath(String path);

  /// Set the modification time of [path]. The access time is accepted for API
  /// compatibility but ignored.
  Future<void> utimes(String path, DateTime atime, DateTime mtime);
}

/// Initial files for a filesystem: maps a path to content. Each value may be a
/// [String], a list of bytes, a [FileInit], or a [LazyFileProvider].
typedef InitialFiles = Map<String, Object>;
