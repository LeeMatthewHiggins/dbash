import 'package:dbash/src/fs/path_utils.dart';
import 'package:test/test.dart';

void main() {
  group('normalizePath', () {
    test('root and empty', () {
      expect(normalizePath('/'), '/');
      expect(normalizePath(''), '/');
    });

    test('resolves . and ..', () {
      expect(normalizePath('/a/./b'), '/a/b');
      expect(normalizePath('/a/b/../c'), '/a/c');
      expect(normalizePath('/a/../../b'), '/b');
    });

    test('adds leading slash and strips trailing', () {
      expect(normalizePath('a/b'), '/a/b');
      expect(normalizePath('/a/b/'), '/a/b');
    });
  });

  group('dirname', () {
    test('cases', () {
      expect(dirname('/a/b/c'), '/a/b');
      expect(dirname('/a'), '/');
      expect(dirname('/'), '/');
    });
  });

  group('resolvePath', () {
    test('absolute returns normalized', () {
      expect(resolvePath('/base', '/abs/path'), '/abs/path');
    });

    test('relative resolves against base', () {
      expect(resolvePath('/base', 'child'), '/base/child');
      expect(resolvePath('/', 'child'), '/child');
      expect(resolvePath('/base', '../sib'), '/sib');
    });
  });

  group('resolveSymlinkTarget', () {
    test('absolute and relative targets', () {
      expect(resolveSymlinkTarget('/a/link', '/abs'), '/abs');
      expect(resolveSymlinkTarget('/a/link', 'sub'), '/a/sub');
      expect(resolveSymlinkTarget('/a/b/link', '../x'), '/a/x');
    });
  });

  group('validatePath', () {
    test('throws on null byte', () {
      expect(
        () => validatePath('a${String.fromCharCode(0)}b', 'open'),
        throwsA(isA<FsException>()),
      );
    });

    test('passes clean path', () {
      expect(() => validatePath('/a/b', 'open'), returnsNormally);
    });
  });
}
