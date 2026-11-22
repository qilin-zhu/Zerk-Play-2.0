import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Local loopback HTTP range proxy for Quark CDN direct links.
///
/// The Quark CDN throttles every TCP connection (measured against a real
/// server: ~0.09 MB/s on the file head, ~6 MB/s mid-file on the same URL), so
/// a single mpv connection starves 4K playback — the screen stays black while
/// the demuxer trickles data. FlyNarwhal solves this with a local proxy that
/// splits each player range request into parallel CDN sub-requests; this is
/// the lean port: 10 MB chunks, 3 chunks in flight per reader, streamed to
/// the player in order, up to 3 attempts per chunk, and response headers sent
/// before the first body byte so a second mpv reader never waits on media.
final class QuarkCdnProxy {
  QuarkCdnProxy({required Uri upstream, required Map<String, String> upstreamHeaders})
      : _upstream = upstream,
        _upstreamHeaders = upstreamHeaders;

  static const int chunkSize = 10 * 1024 * 1024;
  static const int maxChunksInFlight = 3;
  static const int maxChunkAttempts = 3;
  static const Duration idleTimeout = Duration(seconds: 30);

  final Uri _upstream;
  final Map<String, String> _upstreamHeaders;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  final Set<HttpClientRequest> _inflight = {};
  final Set<Socket> _sockets = {};
  HttpServer? _server;
  Uri? _localUri;
  int? _totalLength;
  String? _contentType;
  bool _closed = false;
  late final String _path = '/${_token()}/media';

  static String _token() {
    final random = Random.secure();
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '${random.nextInt(1 << 32).toRadixString(36)}';
  }

  /// Probes the CDN for the total length, then starts the loopback server.
  Future<Uri> start() async {
    await _probe();
    if (_closed) throw StateError('proxy closed');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('proxy closed');
    }
    _server = server;
    server.listen((request) => unawaited(_serve(request)), onError: (_) {});
    final uri = Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: _path);
    _localUri = uri;
    return uri;
  }

  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    for (final req in _inflight.toList()) {
      req.abort();
    }
    _inflight.clear();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
    _localUri = null;
  }

  /// One tiny range request to learn `Content-Range: bytes 0-0/TOTAL`.
  Future<void> _probe() async {
    HttpClientResponse? res;
    HttpClientRequest? req;
    try {
      req = await _http.openUrl('GET', _upstream);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      _upstreamHeaders.forEach((k, v) => req!.headers.add(k, v));
      _inflight.add(req);
      res = await req.close();
      final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
      if (res.statusCode == HttpStatus.partialContent && contentRange != null) {
        final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
        if (match != null) _totalLength = int.parse(match.group(1)!);
      }
      _contentType = res.headers.contentType?.toString();
      if (_totalLength == null && res.statusCode == HttpStatus.ok) {
        final length = res.headers.contentLength;
        if (length >= 0) _totalLength = length;
      }
      if (_totalLength == null || _totalLength! <= 0) {
        throw HttpException('CDN probe: total length unknown (HTTP ${res.statusCode})');
      }
    } finally {
      _inflight.remove(req);
      try {
        await res?.drain<void>().timeout(const Duration(seconds: 10), onTimeout: () {});
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    Socket? socket;
    var detached = false;
    try {
      if (_closed) return;
      if (request.uri.path != _path) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final total = _totalLength!;
      int start;
      int end;
      var partial = true;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader == null || rangeHeader.trim().isEmpty) {
        start = 0;
        end = total - 1;
        partial = false;
      } else {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$', caseSensitive: false)
            .firstMatch(rangeHeader.trim());
        final first = match?.group(1);
        final last = match?.group(2);
        if (match == null || (first!.isEmpty && last!.isEmpty)) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await response.close();
          return;
        }
        if (first.isEmpty) {
          final suffix = int.parse(last!);
          start = suffix >= total ? 0 : total - suffix;
          end = total - 1;
        } else {
          start = int.parse(first);
          end = last!.isEmpty ? total - 1 : min(int.parse(last), total - 1);
        }
        if (start > end || start >= total) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await response.close();
          return;
        }
      }
      response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers
          .set(HttpHeaders.contentTypeHeader, _contentType ?? 'application/octet-stream');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = end - start + 1;
      if (partial) {
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      // Detach with the headers: mpv/ffmpeg keep the old connection open
      // until the new range response headers arrive, so sending them ahead of
      // the (possibly slow) first upstream byte keeps new readers unblocked.
      response.persistentConnection = false;
      socket = await response.detachSocket(writeHeaders: true);
      detached = true;
      _sockets.add(socket);
      try {
        await _pump(socket, start, end);
      } finally {
        _sockets.remove(socket);
        try {
          await socket.flush();
          await socket.close();
        } catch (_) {
          socket.destroy();
        }
      }
    } catch (_) {
      if (!detached) {
        try {
          await response.close();
        } catch (_) {
          // Already disconnected.
        }
      }
    }
  }

  /// Streams [start..end] to the player socket through an ordered chunk
  /// window: always `maxChunksInFlight` downloads ahead of the byte being
  /// written, so per-connection throttling is multiplied away.
  Future<void> _pump(Socket socket, int start, int end) async {
    var aborted = false;
    socket.listen((_) {}, onError: (Object _) => aborted = true, onDone: () => aborted = true);
    final futures = <int, Future<Uint8List?>>{};
    var nextFetch = 0;
    bool moreToFetch(int index) => start + index * chunkSize <= end;

    try {
      for (var i = 0; moreToFetch(i); i++) {
        if (aborted || _closed) return;
        while (nextFetch - i < maxChunksInFlight && moreToFetch(nextFetch)) {
          final index = nextFetch++;
          final chunkStart = start + index * chunkSize;
          final chunkEnd = min(chunkStart + chunkSize, end + 1) - 1;
          futures[index] = _fetchChunk(chunkStart, chunkEnd);
        }
        final data = await futures[i]!;
        if (aborted || _closed) return;
        if (data == null) {
          // All attempts for this chunk failed — close this connection and
          // let mpv re-request the range.
          return;
        }
        socket.add(data);
        await socket.flush();
      }
    } catch (_) {
      // Player went away mid-stream; nothing to salvage.
    }
  }

  /// Downloads one chunk with retries and an idle watchdog (a throttled CDN
  /// connection can stall forever — abort and retry instead).
  ///
  /// The CDN is allowed to answer with *more* than was asked for: Quark always
  /// aligns a `bytes=0-0` probe out to 64 bytes, and some edges pad small
  /// ranges the same way. Insisting on an exact length made those responses
  /// look like failures and starved the player, so anything at or past the
  /// requested range is accepted (and trimmed) and only a genuine short read
  /// is retried.
  Future<Uint8List?> _fetchChunk(int start, int endIncl) async {
    final expected = endIncl - start + 1;
    for (var attempt = 0; attempt < maxChunkAttempts; attempt++) {
      if (_closed) return null;
      HttpClientRequest? req;
      HttpClientResponse? res;
      var idle = DateTime.now();
      Timer? watchdog;
      try {
        req = await _http.openUrl('GET', _upstream);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endIncl');
        _upstreamHeaders.forEach((k, v) => req!.headers.add(k, v));
        _inflight.add(req);
        res = await req.close();
        if (res.statusCode != HttpStatus.partialContent &&
            res.statusCode != HttpStatus.ok) {
          throw HttpException('CDN HTTP ${res.statusCode}');
        }
        final builder = BytesBuilder(copy: false);
        var got = 0;
        watchdog = Timer.periodic(idleTimeout ~/ 2, (_) {
          if (DateTime.now().difference(idle) > idleTimeout) req?.abort();
        });
        await for (final chunk in res) {
          idle = DateTime.now();
          builder.add(chunk);
          got += chunk.length;
          // Enough already: stop pulling so an over-long (or un-ranged)
          // response cannot hold the reader hostage for the whole file.
          if (got >= expected) break;
        }
        if (got < expected) {
          throw HttpException('CDN short read $got/$expected');
        }
        final bytes = builder.takeBytes();
        return bytes.length == expected
            ? bytes
            : Uint8List.sublistView(bytes, 0, expected);
      } catch (_) {
        if (_closed) return null;
        if (attempt + 1 < maxChunkAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        }
      } finally {
        watchdog?.cancel();
        _inflight.remove(req);
        try {
          await res?.drain<void>().timeout(const Duration(seconds: 5), onTimeout: () {});
        } catch (_) {}
      }
    }
    return null;
  }

  /// Fetches the first bytes back through the loopback server.
  ///
  /// A TV gives us nothing but an on-screen error string, so the proxy checks
  /// itself before the player ever touches it: if the bytes that come out of
  /// `127.0.0.1` do not look like the container the CDN is serving, the
  /// caller falls back to the NAS proxy instead of showing a black screen.
  Future<String> selfCheck() async {
    final local = _localUri;
    if (local == null) return 'not started';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(local);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-15');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length >= 16) break;
      }
      final head = bytes.take(16).toList();
      final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final ok = _looksLikeMedia(head);
      return '${ok ? 'ok' : 'bad'} http=${res.statusCode} '
          'ctype=${res.headers.contentType} len=${res.contentLength} head=$hex';
    } catch (e) {
      return 'error $e';
    } finally {
      client.close(force: true);
    }
  }

  /// EBML (mkv/webm), ISO-BMFF (`ftyp` at offset 4), RIFF, MPEG-TS, FLV, Ogg —
  /// the containers a 飞牛 library can hand out directly.
  static bool _looksLikeMedia(List<int> h) {
    bool at(int i, List<int> sig) {
      if (h.length < i + sig.length) return false;
      for (var k = 0; k < sig.length; k++) {
        if (h[i + k] != sig[k]) return false;
      }
      return true;
    }

    return at(0, [0x1a, 0x45, 0xdf, 0xa3]) || // EBML / matroska
        at(4, [0x66, 0x74, 0x79, 0x70]) || // ....ftyp
        at(0, [0x52, 0x49, 0x46, 0x46]) || // RIFF
        at(0, [0x47]) || // MPEG-TS sync byte
        at(0, [0x46, 0x4c, 0x56]) || // FLV
        at(0, [0x4f, 0x67, 0x67, 0x53]) || // OggS
        at(0, [0x49, 0x44, 0x33]); // ID3 (mp3/aac with tags)
  }
}
