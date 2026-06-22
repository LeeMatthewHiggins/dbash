import 'dart:typed_data';

import 'package:dbash/src/fs/file_system.dart';
import 'package:dbash/src/fs/in_memory_fs.dart';
import 'package:dbash/src/fs/path_utils.dart';
import 'package:test/test.dart';

void main() {
  group('buffer and encoding', () {
    test('write and read Uint8Array', () async {
      final fs = InMemoryFs();
      final data = Uint8List.fromList([0x48, 0x65, 0x6c, 0x6c, 0x6f]);
      await fs.writeFile('/binary.bin', data);
      expect(await fs.readFileBuffer('/binary.bin'), data);
    });

    test('write bytes, read as string', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', Uint8List.fromList([0x48, 0x69]));
      expect(await fs.readFile('/t.txt'), 'Hi');
    });

    test('write string, read as bytes', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', 'Hello');
      expect(
        await fs.readFileBuffer('/t.txt'),
        Uint8List.fromList([0x48, 0x65, 0x6c, 0x6c, 0x6f]),
      );
    });

    test('binary data with null bytes preserved', () async {
      final fs = InMemoryFs();
      final data = Uint8List.fromList([0x00, 0x01, 0x00, 0xff, 0x00]);
      await fs.writeFile('/b.bin', data);
      expect(await fs.readFileBuffer('/b.bin'), data);
    });

    test('utf8 roundtrip', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', 'Hello 世界');
      expect(await fs.readFile('/t.txt'), 'Hello 世界');
    });

    test('base64 write and utf8 read', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', 'SGVsbG8=', encoding: BufferEncoding.base64);
      expect(await fs.readFile('/t.txt'), 'Hello');
    });

    test('read as base64', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', 'Hello');
      expect(
        await fs.readFile('/t.txt', encoding: BufferEncoding.base64),
        'SGVsbG8=',
      );
    });

    test('hex write and read', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', '48656c6c6f', encoding: BufferEncoding.hex);
      expect(await fs.readFile('/t.txt'), 'Hello');
      expect(
        await fs.readFile('/t.txt', encoding: BufferEncoding.hex),
        '48656c6c6f',
      );
    });

    test('latin1 write', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', 'café', encoding: BufferEncoding.latin1);
      expect(
        await fs.readFileBuffer('/t.txt'),
        Uint8List.fromList([0x63, 0x61, 0x66, 0xe9]),
      );
    });

    test('binary file size', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/b.bin', Uint8List.fromList([0, 1, 2, 3, 4]));
      expect((await fs.stat('/b.bin')).size, 5);
    });
  });

  group('append', () {
    test('append to existing file', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/t.txt', 'Hello');
      await fs.appendFile('/t.txt', ', World');
      expect(await fs.readFile('/t.txt'), 'Hello, World');
    });

    test('append creates file', () async {
      final fs = InMemoryFs();
      await fs.appendFile('/t.txt', 'new');
      expect(await fs.readFile('/t.txt'), 'new');
    });
  });

  group('directories', () {
    test('mkdir recursive and readdir sorted', () async {
      final fs = InMemoryFs();
      await fs.mkdir('/a/b/c', recursive: true);
      await fs.writeFile('/a/z.txt', 'z');
      await fs.writeFile('/a/m.txt', 'm');
      expect(await fs.readdir('/a'), ['b', 'm.txt', 'z.txt']);
    });

    test('mkdir non-recursive on missing parent throws', () async {
      final fs = InMemoryFs();
      expect(
        () => fs.mkdir('/x/y'),
        throwsA(isA<FsException>()),
      );
    });

    test('readdirWithFileTypes reports types', () async {
      final fs = InMemoryFs();
      await fs.mkdir('/d');
      await fs.writeFile('/f.txt', 'f');
      final entries = await fs.readdirWithFileTypes('/');
      final byName = {for (final e in entries) e.name: e};
      expect(byName['d']!.isDirectory, isTrue);
      expect(byName['f.txt']!.isFile, isTrue);
    });
  });

  group('rm / cp / mv', () {
    test('rm non-empty without recursive throws', () async {
      final fs = InMemoryFs();
      await fs.mkdir('/d');
      await fs.writeFile('/d/f', 'x');
      expect(() => fs.rm('/d'), throwsA(isA<FsException>()));
    });

    test('rm recursive removes tree', () async {
      final fs = InMemoryFs();
      await fs.mkdir('/d/e', recursive: true);
      await fs.writeFile('/d/e/f', 'x');
      await fs.rm('/d', recursive: true);
      expect(await fs.exists('/d'), isFalse);
    });

    test('rm force on missing is silent', () async {
      final fs = InMemoryFs();
      await fs.rm('/nope', force: true);
    });

    test('cp file deep-copies content', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/a', 'data');
      await fs.cp('/a', '/b');
      await fs.writeFile('/a', 'changed');
      expect(await fs.readFile('/b'), 'data');
    });

    test('cp directory requires recursive', () async {
      final fs = InMemoryFs();
      await fs.mkdir('/d');
      expect(() => fs.cp('/d', '/e'), throwsA(isA<FsException>()));
    });

    test('mv moves file', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/a', 'data');
      await fs.mv('/a', '/b');
      expect(await fs.exists('/a'), isFalse);
      expect(await fs.readFile('/b'), 'data');
    });
  });

  group('symlinks', () {
    test('symlink + readlink + follow on read', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/target.txt', 'hi');
      await fs.symlink('/target.txt', '/link');
      expect(await fs.readlink('/link'), '/target.txt');
      expect(await fs.readFile('/link'), 'hi');
    });

    test('lstat does not follow, stat follows', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/target.txt', 'hi');
      await fs.symlink('/target.txt', '/link');
      expect((await fs.lstat('/link')).isSymbolicLink, isTrue);
      expect((await fs.stat('/link')).isFile, isTrue);
    });

    test('readlink on non-symlink throws EINVAL', () async {
      final fs = InMemoryFs();
      await fs.writeFile('/f', 'x');
      expect(() => fs.readlink('/f'), throwsA(isA<FsException>()));
    });
  });

  group('lazy files', () {
    test('lazy provider materializes on read', () async {
      var calls = 0;
      final fs = InMemoryFs({
        '/lazy.txt': () {
          calls++;
          return 'lazy-content';
        },
      });
      expect(await fs.readFile('/lazy.txt'), 'lazy-content');
      expect(await fs.readFile('/lazy.txt'), 'lazy-content');
      expect(calls, 1);
    });

    test('async lazy provider', () async {
      final fs = InMemoryFs({
        '/lazy.txt': () async => 'async-content',
      });
      expect(await fs.readFile('/lazy.txt'), 'async-content');
    });
  });

  group('initial files', () {
    test('FileInit with mode', () async {
      final fs = InMemoryFs({
        '/f.txt': const FileInit('content', mode: 0x1ff),
      });
      expect(await fs.readFile('/f.txt'), 'content');
      expect((await fs.stat('/f.txt')).mode, 0x1ff);
    });

    test('missing file throws ENOENT', () async {
      final fs = InMemoryFs();
      expect(() => fs.readFile('/missing'), throwsA(isA<FsException>()));
    });
  });
}
