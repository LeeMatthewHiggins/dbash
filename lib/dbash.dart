/// A pure Dart port of just-bash: a simulated bash environment with a virtual
/// filesystem.
///
/// This is the web-safe entry point. It never imports `dart:io`. For
/// real-filesystem mounts (overlay / read-write over disk) and the CLI, use
/// `package:dbash/dbash_io.dart`.
library;

export 'src/fs/file_system.dart';
export 'src/fs/in_memory_fs.dart';
export 'src/fs/path_utils.dart';
export 'src/parser/lexer.dart' show Lexer, LexerOptions, readHeredocDelimiter;
export 'src/parser/token.dart';
