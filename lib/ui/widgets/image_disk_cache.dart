import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<Directory>? _dir;

Future<Directory> _cacheDir() => _dir ??= () async {
      final base = await getApplicationCacheDirectory();
      final dir = Directory(p.join(base.path, 'images'));
      await dir.create(recursive: true);
      return dir;
    }();

Future<File> _file(Uri url) async => File(p.join((await _cacheDir()).path, _hash(url.toString())));

/// Whether [bytes] starts with a signature this app can decode.
///
/// The cache used to hand back whatever the image endpoint answered, and the
/// endpoint does not always answer with an image: an XML/JSON error page, a
/// placeholder SVG, or - when the disk was full - a zero-byte file left behind
/// by an interrupted write. Those bytes decode to `Invalid image data` forever,
/// because a file on disk counts as a cache hit and nothing ever asks again.
/// That is exactly the "every poster is a title card, even after a restart"
/// report. Validate on the way in and on the way out.
bool looksLikeImage(Uint8List bytes) {
  // Nothing shorter than this is a real frame; it is a failed or partial write.
  if (bytes.length < 128) return false;
  bool at(int i, int v) => i < bytes.length && bytes[i] == v;
  // JPEG
  if (at(0, 0xFF) && at(1, 0xD8) && at(2, 0xFF)) return true;
  // PNG
  if (at(0, 0x89) && at(1, 0x50) && at(2, 0x4E) && at(3, 0x47)) return true;
  // GIF
  if (at(0, 0x47) && at(1, 0x49) && at(2, 0x46)) return true;
  // WebP: "RIFF....WEBP" - Emby and the media servers both answer with it.
  if (at(0, 0x52) && at(1, 0x49) && at(2, 0x46) && at(3, 0x46) &&
      at(8, 0x57) && at(9, 0x45) && at(10, 0x42) && at(11, 0x50)) {
    return true;
  }
  // BMP
  if (at(0, 0x42) && at(1, 0x4D)) return true;
  // AVIF / HEIC: an ISO-BMFF box whose brand follows `ftyp`.
  if (at(4, 0x66) && at(5, 0x74) && at(6, 0x79) && at(7, 0x70)) return true;
  return false;
}

/// A JPEG whose end-of-image marker is missing was cut short. The head still
/// looks valid, so this is the only way to tell a truncated frame from a whole
/// one, and a truncated frame decodes to a grey half image or an error.
bool _jpegComplete(Uint8List bytes) {
  if (!(bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8)) return true;
  for (var i = bytes.length - 1; i > 1; i--) {
    if (bytes[i] != 0xD9) continue;
    return bytes[i - 1] == 0xFF;
  }
  return false;
}

Future<Uint8List?> readCachedImage(Uri url) async {
  try {
    final file = await _file(url);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (looksLikeImage(bytes) && _jpegComplete(bytes)) return bytes;
    // Poisoned entry: drop it so this same call falls through to the network
    // and the next start does not read it again.
    await file.delete();
  } catch (_) {}
  return null;
}

Future<void> dropCachedImage(Uri url) async {
  try {
    final file = await _file(url);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

void writeCachedImage(Uri url, Uint8List bytes) {
  // Only whole images ever reach the disk. An error page written here would be
  // served as a cache hit for the rest of the installation's life.
  if (!looksLikeImage(bytes) || !_jpegComplete(bytes)) return;
  unawaited(() async {
    try {
      final file = await _file(url);
      // Write to a sibling and rename: a crash, a full disk or a kill in the
      // middle leaves the `.part` behind instead of a half image under the
      // real name.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {
      try {
        final file = await _file(url);
        final tmp = File('${file.path}.part');
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }());
}

/// One pass over the image cache: forget entries that are not images (the
/// 0-byte / XML / SVG leftovers from before validation existed) and keep the
/// folder under [maxBytes] by dropping the oldest files.
///
/// Runs in the background at start-up. It is deliberately forgiving: anything
/// it cannot read is skipped, never fatal.
Future<({int removed, int kept, int bytes})> pruneImageCache({int maxBytes = 320 << 20}) async {
  final dir = await _cacheDir();
  final files = <File>[];
  final stats = <File, (int size, DateTime at)>{};
  var bytes = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (name.endsWith('.part')) {
      // Leftover of an interrupted write.
      try {
        await entity.delete();
      } catch (_) {}
      continue;
    }
    try {
      final stat = await entity.stat();
      if (stat.size == 0) {
        await entity.delete();
        continue;
      }
      if (stat.size < 128 || !await _isImageFile(entity)) {
        await entity.delete();
        continue;
      }
      files.add(entity);
      stats[entity] = (stat.size, stat.modified);
      bytes += stat.size;
    } catch (_) {}
  }
  var removed = 0;
  if (bytes > maxBytes) {
    files.sort((a, b) => stats[a]!.$2.compareTo(stats[b]!.$2));
    for (final f in files) {
      if (bytes <= maxBytes) break;
      try {
        final size = stats[f]!.$1;
        await f.delete();
        bytes -= size;
        removed++;
      } catch (_) {}
    }
  }
  return (removed: removed, kept: files.length - removed, bytes: bytes);
}

Future<bool> _isImageFile(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final length = await raf.length();
    final head = await raf.read(length < 128 ? length : 128);
    if (!looksLikeImage(head)) return false;
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8) {
      // Truncated JPEG: the tail decides, the head cannot.
      await raf.setPosition(length > 2 ? length - 2 : 0);
      final tail = await raf.read(2);
      return tail.length == 2 && tail[1] == 0xD9;
    }
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

String _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16);
}
