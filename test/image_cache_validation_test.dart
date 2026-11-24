import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/ui/widgets/image_disk_cache.dart';

Uint8List bytes(List<int> values, {int pad = 200}) =>
    Uint8List.fromList([...values, ...List.filled(pad, 0x20)]);

void main() {
  group('looksLikeImage', () {
    test('accepts a JPEG', () {
      expect(looksLikeImage(bytes([0xFF, 0xD8, 0xFF, 0xE0])), isTrue);
    });

    test('accepts PNG, WebP, GIF, BMP and AVIF', () {
      expect(looksLikeImage(bytes([0x89, 0x50, 0x4E, 0x47])), isTrue);
      expect(looksLikeImage(bytes([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])), isTrue);
      expect(looksLikeImage(bytes([0x47, 0x49, 0x46, 0x38])), isTrue);
      expect(looksLikeImage(bytes([0x42, 0x4D])), isTrue);
      expect(looksLikeImage(bytes([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70])), isTrue);
    });

    test('rejects what the media servers actually answered with', () {
      // A zero-byte file from an interrupted write.
      expect(looksLikeImage(Uint8List(0)), isFalse);
      // The trimemedia image proxy hands back an SVG placeholder while it warms.
      expect(looksLikeImage(bytes('<svg xmlns="http://www.w3.org/2000/svg">'.codeUnits)), isFalse);
      // An error body from a reverse proxy, 200 OK.
      expect(looksLikeImage(bytes('<?xml version="1.0"?><Error>'.codeUnits)), isFalse);
      expect(looksLikeImage(bytes('{"message":"not found"}'.codeUnits)), isFalse);
      // A truncated signature is not enough on its own.
      expect(looksLikeImage(bytes([0xFF, 0xD8])), isFalse);
    });

    test('rejects a payload too short to be a frame', () {
      expect(looksLikeImage(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), isFalse);
    });
  });
}
