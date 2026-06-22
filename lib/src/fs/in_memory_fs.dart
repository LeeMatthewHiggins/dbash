/// In-memory virtual filesystem.
///
/// Ported from `fs/in-memory-fs/in-memory-fs.ts` in upstream just-bash.
library;

import 'dart:typed_data';

import 'package:dbash/src/fs/encoding.dart';
import 'package:dbash/src/fs/file_system.dart';
import 'package:dbash/src/fs/path_utils.dart' hide resolvePath;
import 'package:dbash/src/fs/path_utils.dart' as pu show resolvePath;

/// Base class for in-memory filesystem entries.
sealed class _FsEntry {
  _FsEntry(this.mode, this.mtime);
  int mode;
  DateTime mtime;
}

class _FileEntry extends _FsEntry {
  _FileEntry(this.content, super.mode, super.mtime);
  Uint8List content;
}

class _LazyFileEntry extends _FsEntry {
  _LazyFileEntry(this.lazy, super.mode, super.mtime);
  final LazyFileProvider lazy;
}

class _DirectoryEntry extends _FsEntry {
  _DirectoryEntry(super.mode, super.mtime);
}

class _SymlinkEntry extends _FsEntry {
  _SymlinkEntry(this.target, super.mode, super.mtime);
  final String target;
}

/// A pure in-memory [FileSystem]. Safe for web (no `dart:io`).
class InMemoryFs implements FileSystem {
  /// Creates an in-memory filesystem, optionally pre-populated with
  /// [initialFiles] (path → [String] / bytes / [FileInit] / [LazyFileProvider]).
  InMemoryFs([InitialFiles? initialFiles]) {
    _data['/'] = _DirectoryEntry(defaultDirMode, DateTime.now());

    if (initialFiles != null) {
      initialFiles.forEach((path, value) {
        if (value is LazyFileProvider) {
          writeFileLazy(path, value);
        } else if (value is FileInit) {
          _writeFileSync(
            path,
            value.content,
            mode: value.mode,
            mtime: value.mtime,
          );
        } else {
          _writeFileSync(path, value);
        }
      });
    }
  }

  final Map<String, _FsEntry> _data = {};

  void _ensureParentDirs(String path) {
    final dir = dirname(path);
    if (dir == '/') return;
    if (!_data.containsKey(dir)) {
      _ensureParentDirs(dir);
      _data[dir] = _DirectoryEntry(defaultDirMode, DateTime.now());
    }
  }

  void _writeFileSync(
    String path,
    Object content, {
    BufferEncoding? encoding,
    int? mode,
    DateTime? mtime,
  }) {
    validatePath(path, 'write');
    final normalized = normalizePath(path);
    _ensureParentDirs(normalized);
    final buffer = contentToBuffer(content, encoding);
    _data[normalized] = _FileEntry(
      buffer,
      mode ?? defaultFileMode,
      mtime ?? DateTime.now(),
    );
  }

  /// Store a lazy file entry whose content is produced by [lazy] on first read.
  void writeFileLazy(
    String path,
    LazyFileProvider lazy, {
    int? mode,
    DateTime? mtime,
  }) {
    validatePath(path, 'write');
    final normalized = normalizePath(path);
    _ensureParentDirs(normalized);
    _data[normalized] = _LazyFileEntry(
      lazy,
      mode ?? defaultFileMode,
      mtime ?? DateTime.now(),
    );
  }

  Future<_FileEntry> _materializeLazy(String path, _LazyFileEntry entry) async {
    final content = await entry.lazy();
    final buffer = contentToBuffer(content);
    final materialized = _FileEntry(buffer, entry.mode, entry.mtime);
    _data[path] = materialized;
    return materialized;
  }

  @override
  Future<String> readFile(String path, {BufferEncoding? encoding}) async {
    final buffer = await readFileBuffer(path);
    return fromBuffer(buffer, encoding);
  }

  @override
  Future<Uint8List> readFileBuffer(String path) async {
    validatePath(path, 'open');
    final resolvedPath = _resolvePathWithSymlinks(path);
    final entry = _data[resolvedPath];

    if (entry == null) {
      throw FsException(
        "ENOENT: no such file or directory, open '$path'",
      );
    }
    if (entry is _DirectoryEntry || entry is _SymlinkEntry) {
      throw FsException(
        "EISDIR: illegal operation on a directory, read '$path'",
      );
    }
    if (entry is _LazyFileEntry) {
      final materialized = await _materializeLazy(resolvedPath, entry);
      return materialized.content;
    }
    return (entry as _FileEntry).content;
  }

  @override
  Future<void> writeFile(
    String path,
    Object content, {
    BufferEncoding? encoding,
  }) async {
    _writeFileSync(path, content, encoding: encoding);
  }

  @override
  Future<void> appendFile(
    String path,
    Object content, {
    BufferEncoding? encoding,
  }) async {
    validatePath(path, 'append');
    final normalized = normalizePath(path);
    final existing = _data[normalized];

    if (existing is _DirectoryEntry) {
      throw FsException(
        "EISDIR: illegal operation on a directory, write '$path'",
      );
    }

    final newBuffer = contentToBuffer(content, encoding);

    if (existing is _FileEntry || existing is _LazyFileEntry) {
      var materialized = existing!;
      if (materialized is _LazyFileEntry) {
        materialized = await _materializeLazy(normalized, materialized);
      }
      final existingBuffer = (materialized as _FileEntry).content;
      final total = existingBuffer.length + newBuffer.length;
      final combined = Uint8List(total)
        ..setRange(0, existingBuffer.length, existingBuffer)
        ..setRange(existingBuffer.length, total, newBuffer);
      _data[normalized] =
          _FileEntry(combined, materialized.mode, DateTime.now());
    } else {
      _writeFileSync(path, content, encoding: encoding);
    }
  }

  @override
  Future<bool> exists(String path) async {
    if (path.codeUnits.contains(0)) return false;
    try {
      final resolvedPath = _resolvePathWithSymlinks(path);
      return _data.containsKey(resolvedPath);
    } on FsException {
      return false;
    }
  }

  @override
  Future<FsStat> stat(String path) async {
    validatePath(path, 'stat');
    final resolvedPath = _resolvePathWithSymlinks(path);
    var entry = _data[resolvedPath];

    if (entry == null) {
      throw FsException("ENOENT: no such file or directory, stat '$path'");
    }
    if (entry is _LazyFileEntry) {
      entry = await _materializeLazy(resolvedPath, entry);
    }
    return _statFrom(entry, followSymlink: true);
  }

  @override
  Future<FsStat> lstat(String path) async {
    validatePath(path, 'lstat');
    final resolvedPath = _resolveIntermediateSymlinks(path);
    var entry = _data[resolvedPath];

    if (entry == null) {
      throw FsException("ENOENT: no such file or directory, lstat '$path'");
    }
    if (entry is _SymlinkEntry) {
      return FsStat(
        isFile: false,
        isDirectory: false,
        isSymbolicLink: true,
        mode: entry.mode,
        size: entry.target.length,
        mtime: entry.mtime,
      );
    }
    if (entry is _LazyFileEntry) {
      entry = await _materializeLazy(resolvedPath, entry);
    }
    return _statFrom(entry, followSymlink: true);
  }

  FsStat _statFrom(_FsEntry entry, {required bool followSymlink}) {
    final size = entry is _FileEntry ? entry.content.length : 0;
    return FsStat(
      isFile: entry is _FileEntry,
      isDirectory: entry is _DirectoryEntry,
      isSymbolicLink: false,
      mode: entry.mode,
      size: size,
      mtime: entry.mtime,
    );
  }

  String _resolveIntermediateSymlinks(String path) {
    final normalized = normalizePath(path);
    if (normalized == '/') return '/';

    final parts = normalized.substring(1).split('/');
    if (parts.length <= 1) return normalized;

    var resolvedPath = '';
    final seen = <String>{};

    for (var i = 0; i < parts.length - 1; i++) {
      // ignore: use_string_buffers, accumulator carries symlink resolution
      resolvedPath = '$resolvedPath/${parts[i]}';
      var entry = _data[resolvedPath];
      var loopCount = 0;
      while (entry is _SymlinkEntry && loopCount < maxSymlinkDepth) {
        if (seen.contains(resolvedPath)) {
          throw FsException(
            "ELOOP: too many levels of symbolic links, lstat '$path'",
          );
        }
        seen.add(resolvedPath);
        resolvedPath = resolveSymlinkTarget(resolvedPath, entry.target);
        entry = _data[resolvedPath];
        loopCount++;
      }
      if (loopCount >= maxSymlinkDepth) {
        throw FsException(
          "ELOOP: too many levels of symbolic links, lstat '$path'",
        );
      }
    }
    return '$resolvedPath/${parts[parts.length - 1]}';
  }

  String _resolvePathWithSymlinks(String path) {
    final normalized = normalizePath(path);
    if (normalized == '/') return '/';

    final parts = normalized.substring(1).split('/');
    var resolvedPath = '';
    final seen = <String>{};

    for (final part in parts) {
      // ignore: use_string_buffers, accumulator carries symlink resolution
      resolvedPath = '$resolvedPath/$part';
      var entry = _data[resolvedPath];
      var loopCount = 0;
      while (entry is _SymlinkEntry && loopCount < maxSymlinkDepth) {
        if (seen.contains(resolvedPath)) {
          throw FsException(
            "ELOOP: too many levels of symbolic links, open '$path'",
          );
        }
        seen.add(resolvedPath);
        resolvedPath = resolveSymlinkTarget(resolvedPath, entry.target);
        entry = _data[resolvedPath];
        loopCount++;
      }
      if (loopCount >= maxSymlinkDepth) {
        throw FsException(
          "ELOOP: too many levels of symbolic links, open '$path'",
        );
      }
    }
    return resolvedPath;
  }

  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {
    _mkdirSync(path, recursive: recursive);
  }

  void _mkdirSync(String path, {required bool recursive}) {
    validatePath(path, 'mkdir');
    final normalized = normalizePath(path);

    if (_data.containsKey(normalized)) {
      final entry = _data[normalized];
      if (entry is _FileEntry || entry is _LazyFileEntry) {
        throw FsException("EEXIST: file already exists, mkdir '$path'");
      }
      if (!recursive) {
        throw FsException("EEXIST: directory already exists, mkdir '$path'");
      }
      return;
    }

    final parent = dirname(normalized);
    if (parent != '/' && !_data.containsKey(parent)) {
      if (recursive) {
        _mkdirSync(parent, recursive: true);
      } else {
        throw FsException(
          "ENOENT: no such file or directory, mkdir '$path'",
        );
      }
    }

    _data[normalized] = _DirectoryEntry(defaultDirMode, DateTime.now());
  }

  @override
  Future<List<String>> readdir(String path) async {
    final entries = await readdirWithFileTypes(path);
    return entries.map((e) => e.name).toList();
  }

  @override
  Future<List<DirentEntry>> readdirWithFileTypes(String path) async {
    validatePath(path, 'scandir');
    var normalized = normalizePath(path);
    var entry = _data[normalized];

    if (entry == null) {
      throw FsException("ENOENT: no such file or directory, scandir '$path'");
    }

    final seen = <String>{};
    while (entry is _SymlinkEntry) {
      if (seen.contains(normalized)) {
        throw FsException(
          "ELOOP: too many levels of symbolic links, scandir '$path'",
        );
      }
      seen.add(normalized);
      normalized = resolveSymlinkTarget(normalized, entry.target);
      entry = _data[normalized];
    }

    if (entry == null) {
      throw FsException("ENOENT: no such file or directory, scandir '$path'");
    }
    if (entry is! _DirectoryEntry) {
      throw FsException("ENOTDIR: not a directory, scandir '$path'");
    }

    final prefix = normalized == '/' ? '/' : '$normalized/';
    final entriesMap = <String, DirentEntry>{};

    _data.forEach((p, fsEntry) {
      if (p == normalized) return;
      if (p.startsWith(prefix)) {
        final rest = p.substring(prefix.length);
        final name = rest.split('/')[0];
        if (name.isNotEmpty &&
            rest.indexOf('/', name.length) == -1 &&
            !entriesMap.containsKey(name)) {
          entriesMap[name] = DirentEntry(
            name: name,
            isFile: fsEntry is _FileEntry || fsEntry is _LazyFileEntry,
            isDirectory: fsEntry is _DirectoryEntry,
            isSymbolicLink: fsEntry is _SymlinkEntry,
          );
        }
      }
    });

    final result = entriesMap.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  @override
  Future<void> rm(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    validatePath(path, 'rm');
    final normalized = normalizePath(path);
    final entry = _data[normalized];

    if (entry == null) {
      if (force) return;
      throw FsException("ENOENT: no such file or directory, rm '$path'");
    }

    if (entry is _DirectoryEntry) {
      final children = await readdir(normalized);
      if (children.isNotEmpty) {
        if (!recursive) {
          throw FsException("ENOTEMPTY: directory not empty, rm '$path'");
        }
        for (final child in children) {
          await rm(joinPath(normalized, child), recursive: recursive,
              force: force);
        }
      }
    }
    _data.remove(normalized);
  }

  @override
  Future<void> cp(String src, String dest, {bool recursive = false}) async {
    validatePath(src, 'cp');
    validatePath(dest, 'cp');
    final srcNorm = normalizePath(src);
    final destNorm = normalizePath(dest);
    final srcEntry = _data[srcNorm];

    if (srcEntry == null) {
      throw FsException("ENOENT: no such file or directory, cp '$src'");
    }

    if (srcEntry is _FileEntry) {
      _ensureParentDirs(destNorm);
      _data[destNorm] = _FileEntry(
        Uint8List.fromList(srcEntry.content),
        srcEntry.mode,
        srcEntry.mtime,
      );
    } else if (srcEntry is _LazyFileEntry) {
      _ensureParentDirs(destNorm);
      _data[destNorm] =
          _LazyFileEntry(srcEntry.lazy, srcEntry.mode, srcEntry.mtime);
    } else if (srcEntry is _SymlinkEntry) {
      _ensureParentDirs(destNorm);
      _data[destNorm] =
          _SymlinkEntry(srcEntry.target, srcEntry.mode, srcEntry.mtime);
    } else if (srcEntry is _DirectoryEntry) {
      if (!recursive) {
        throw FsException("EISDIR: is a directory, cp '$src'");
      }
      await mkdir(destNorm, recursive: true);
      final children = await readdir(srcNorm);
      for (final child in children) {
        await cp(joinPath(srcNorm, child), joinPath(destNorm, child),
            recursive: recursive);
      }
    }
  }

  @override
  Future<void> mv(String src, String dest) async {
    await cp(src, dest, recursive: true);
    await rm(src, recursive: true);
  }

  @override
  List<String> getAllPaths() => _data.keys.toList();

  @override
  String resolvePath(String base, String path) => pu.resolvePath(base, path);

  @override
  Future<void> chmod(String path, int mode) async {
    validatePath(path, 'chmod');
    final normalized = normalizePath(path);
    final entry = _data[normalized];
    if (entry == null) {
      throw FsException("ENOENT: no such file or directory, chmod '$path'");
    }
    entry.mode = mode;
  }

  @override
  Future<void> symlink(String target, String linkPath) async {
    validatePath(linkPath, 'symlink');
    final normalized = normalizePath(linkPath);
    if (_data.containsKey(normalized)) {
      throw FsException("EEXIST: file already exists, symlink '$linkPath'");
    }
    _ensureParentDirs(normalized);
    _data[normalized] = _SymlinkEntry(target, symlinkMode, DateTime.now());
  }

  @override
  Future<void> link(String existingPath, String newPath) async {
    validatePath(existingPath, 'link');
    validatePath(newPath, 'link');
    final existingNorm = normalizePath(existingPath);
    final newNorm = normalizePath(newPath);

    final entry = _data[existingNorm];
    if (entry == null) {
      throw FsException(
        "ENOENT: no such file or directory, link '$existingPath'",
      );
    }
    if (entry is! _FileEntry && entry is! _LazyFileEntry) {
      throw FsException(
        "EPERM: operation not permitted, link '$existingPath'",
      );
    }
    if (_data.containsKey(newNorm)) {
      throw FsException("EEXIST: file already exists, link '$newPath'");
    }

    var resolved = entry;
    if (resolved is _LazyFileEntry) {
      resolved = await _materializeLazy(existingNorm, resolved);
    }
    final fileEntry = resolved as _FileEntry;
    _ensureParentDirs(newNorm);
    _data[newNorm] = _FileEntry(
      fileEntry.content,
      fileEntry.mode,
      fileEntry.mtime,
    );
  }

  @override
  Future<String> readlink(String path) async {
    validatePath(path, 'readlink');
    final normalized = normalizePath(path);
    final entry = _data[normalized];
    if (entry == null) {
      throw FsException(
        "ENOENT: no such file or directory, readlink '$path'",
      );
    }
    if (entry is! _SymlinkEntry) {
      throw FsException("EINVAL: invalid argument, readlink '$path'");
    }
    return entry.target;
  }

  @override
  Future<String> realpath(String path) async {
    validatePath(path, 'realpath');
    final resolved = _resolvePathWithSymlinks(path);
    if (!_data.containsKey(resolved)) {
      throw FsException(
        "ENOENT: no such file or directory, realpath '$path'",
      );
    }
    return resolved;
  }

  @override
  Future<void> utimes(String path, DateTime atime, DateTime mtime) async {
    validatePath(path, 'utimes');
    final normalized = normalizePath(path);
    final resolved = _resolvePathWithSymlinks(normalized);
    final entry = _data[resolved];
    if (entry == null) {
      throw FsException("ENOENT: no such file or directory, utimes '$path'");
    }
    entry.mtime = mtime;
  }
}
