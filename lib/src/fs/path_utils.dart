/// Pure path utilities for virtual filesystems.
///
/// No `dart:io` dependencies — safe for web bundles. Ported from
/// `fs/path-utils.ts` in the upstream just-bash project.
library;

/// Maximum depth for symlink resolution loops.
const int maxSymlinkDepth = 40;

/// Default directory permissions.
const int defaultDirMode = 0x1ed; // 0o755

/// Default file permissions.
const int defaultFileMode = 0x1a4; // 0o644

/// Default symlink permissions.
const int symlinkMode = 0x1ff; // 0o777

/// Normalize a virtual path: resolve `.` and `..`, ensure it starts with `/`,
/// and strip trailing slashes. Pure function, no I/O.
String normalizePath(String path) {
  if (path.isEmpty || path == '/') return '/';

  var normalized = path.endsWith('/') && path != '/'
      ? path.substring(0, path.length - 1)
      : path;

  if (!normalized.startsWith('/')) {
    normalized = '/$normalized';
  }

  final parts =
      normalized.split('/').where((p) => p.isNotEmpty && p != '.').toList();
  final resolved = <String>[];

  for (final part in parts) {
    if (part == '..') {
      if (resolved.isNotEmpty) resolved.removeLast();
    } else {
      resolved.add(part);
    }
  }

  final joined = '/${resolved.join('/')}';
  return joined.isEmpty ? '/' : joined;
}

/// Validate that a path does not contain null bytes.
///
/// Null bytes in paths can be used to truncate filenames or bypass security
/// filters. Throws [FsException] when a null byte is present.
void validatePath(String path, String operation) {
  if (path.codeUnits.contains(0)) {
    throw FsException(
      "ENOENT: path contains null byte, $operation '$path'",
    );
  }
}

/// Get the directory name of a normalized virtual path.
String dirname(String path) {
  final normalized = normalizePath(path);
  if (normalized == '/') return '/';
  final lastSlash = normalized.lastIndexOf('/');
  return lastSlash == 0 ? '/' : normalized.substring(0, lastSlash);
}

/// Resolve a relative [path] against a [base] directory.
///
/// If [path] is absolute it is normalized and returned directly.
String resolvePath(String base, String path) {
  if (path.startsWith('/')) {
    return normalizePath(path);
  }
  final combined = base == '/' ? '/$path' : '$base/$path';
  return normalizePath(combined);
}

/// Join a [parent] path with a [child] name.
///
/// Handles the root-path edge case (`"/" + "child"` → `"/child"`).
String joinPath(String parent, String child) {
  return parent == '/' ? '/$child' : '$parent/$child';
}

/// Resolve a symlink [target] relative to the symlink's location.
///
/// Absolute targets are normalized directly; relative targets are resolved
/// from the symlink's parent directory ([symlinkPath]).
String resolveSymlinkTarget(String symlinkPath, String target) {
  if (target.startsWith('/')) {
    return normalizePath(target);
  }
  final dir = dirname(symlinkPath);
  return normalizePath(joinPath(dir, target));
}

/// Error thrown by filesystem operations, mirroring the Node-style messages
/// (`ENOENT: ...`, `EISDIR: ...`) the upstream project emits so command output
/// matches byte-for-byte.
class FsException implements Exception {
  /// Creates a filesystem exception with the given [message].
  FsException(this.message);

  /// The Node-style error message.
  final String message;

  @override
  String toString() => message;
}
