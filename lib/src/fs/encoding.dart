/// Encoding helpers for converting between text and bytes, mirroring the
/// behavior of `fs/encoding.ts` in upstream just-bash.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Supported buffer encodings (mirrors Node's `BufferEncoding` subset used by
/// upstream).
enum BufferEncoding {
  /// UTF-8 text.
  utf8,

  /// 7-bit ASCII text.
  ascii,

  /// Raw bytes, one char per byte (alias of [latin1]).
  binary,

  /// Base64-encoded text.
  base64,

  /// Hexadecimal text.
  hex,

  /// Latin-1 (ISO-8859-1) text, one char per byte.
  latin1,
}

/// Parse an encoding name (e.g. `"utf-8"`) into a [BufferEncoding].
///
/// Returns `null` for an unknown or empty name.
BufferEncoding? parseEncoding(String? name) {
  switch (name) {
    case 'utf8':
    case 'utf-8':
      return BufferEncoding.utf8;
    case 'ascii':
      return BufferEncoding.ascii;
    case 'binary':
      return BufferEncoding.binary;
    case 'base64':
      return BufferEncoding.base64;
    case 'hex':
      return BufferEncoding.hex;
    case 'latin1':
      return BufferEncoding.latin1;
    default:
      return null;
  }
}

/// Convert string [content] to bytes using [encoding] (defaults to UTF-8).
Uint8List toBuffer(String content, [BufferEncoding? encoding]) {
  switch (encoding) {
    case BufferEncoding.base64:
      return base64.decode(_normalizeBase64(content));
    case BufferEncoding.hex:
      final bytes = Uint8List(content.length ~/ 2);
      for (var i = 0; i < content.length - 1; i += 2) {
        bytes[i ~/ 2] = int.parse(content.substring(i, i + 2), radix: 16);
      }
      return bytes;
    case BufferEncoding.binary:
    case BufferEncoding.latin1:
    case BufferEncoding.ascii:
      final result = Uint8List(content.length);
      for (var i = 0; i < content.length; i++) {
        result[i] = content.codeUnitAt(i) & 0xff;
      }
      return result;
    case BufferEncoding.utf8:
    case null:
      return Uint8List.fromList(utf8.encode(content));
  }
}

/// Convert [buffer] to a string using [encoding] (defaults to UTF-8).
String fromBuffer(Uint8List buffer, [BufferEncoding? encoding]) {
  switch (encoding) {
    case BufferEncoding.base64:
      return base64.encode(buffer);
    case BufferEncoding.hex:
      final sb = StringBuffer();
      for (final b in buffer) {
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    case BufferEncoding.binary:
    case BufferEncoding.latin1:
    case BufferEncoding.ascii:
      return String.fromCharCodes(buffer);
    case BufferEncoding.utf8:
    case null:
      return utf8.decode(buffer, allowMalformed: true);
  }
}

/// Coerce file [content] (a [String] or list of bytes) to bytes, honoring
/// [encoding] for string input.
Uint8List contentToBuffer(Object content, [BufferEncoding? encoding]) {
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  if (content is String) return toBuffer(content, encoding);
  throw ArgumentError(
    'File content must be a String or List<int>, got ${content.runtimeType}',
  );
}

String _normalizeBase64(String input) {
  final cleaned = input.replaceAll(RegExp(r'\s'), '');
  final pad = cleaned.length % 4;
  if (pad == 0) return cleaned;
  return cleaned + '=' * (4 - pad);
}
