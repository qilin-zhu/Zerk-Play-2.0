import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../../core/log/app_log.dart';
import '../../core/log/logging_http_client.dart';
import '../core/tv_scale.dart';
import 'image_disk_cache.dart';

@immutable
class NetImageProvider extends ImageProvider<NetImageProvider> {
  const NetImageProvider(this.url, {this.decodeWidth, this.headers, this.attempt = 0});

  final Uri url;
  final int? decodeWidth;
  final Map<String, String>? headers;

  /// Retry counter. Part of the cache identity on purpose: the failed attempt
  /// left a completer behind, and asking for the same key again would hand back
  /// that failure instead of going to the server.
  final int attempt;

  static final _client = LoggingHttpClient(tag: 'image', quiet: true);

  @override
  Future<NetImageProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      debugLabel: url.toString(),
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await _bytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer, getTargetSize: (w, h) {
      final target = decodeWidth;
      if (target == null || w <= target) return ui.TargetImageSize(width: w, height: h);
      return ui.TargetImageSize(width: target);
    });
  }

  Future<Uint8List> _bytes() async {
    if (attempt == 0) {
      final cached = await readCachedImage(url);
      if (cached != null) return cached;
    } else {
      // A retry must not trust the disk: whatever is there is either the frame
      // that just failed to decode or a poisoned entry (empty, an error page).
      await dropCachedImage(url);
    }
    final request = http.Request('GET', url);
    final extra = headers;
    if (extra != null && extra.isNotEmpty) request.headers.addAll(extra);
    final res = await _client.send(request).then(http.Response.fromStream).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw NetworkImageLoadException(statusCode: res.statusCode, uri: url);
    }
    if (!looksLikeImage(res.bodyBytes)) {
      // The endpoint answered 200 with something that is not a frame (an XML
      // error body from a proxy, a placeholder SVG). Never cache it.
      throw FormatException(
          'not an image: ${res.bodyBytes.length} bytes, ${res.headers['content-type'] ?? 'no content-type'}');
    }
    writeCachedImage(url, res.bodyBytes);
    return res.bodyBytes;
  }

  @override
  bool operator ==(Object other) =>
      other is NetImageProvider &&
      other.url == url &&
      other.decodeWidth == decodeWidth &&
      other.headers == headers &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(url, decodeWidth, headers, attempt);
}

/// Network image with a retry policy.
///
/// A failed load used to be final for the lifetime of the card: the title-card
/// fallback stayed on screen until the page was rebuilt, and after a restart the
/// same URL came straight back from the disk cache. Now a failure is retried a
/// few times with a growing pause (the cache entry is dropped first), and the
/// attempt counter is part of the image key, so a retry really does go out to the
/// server.
class NetImage extends StatefulWidget {
  const NetImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fallback,
    this.fadeDuration = const Duration(milliseconds: 260),
    this.headers,
    this.retries = 3,
  });

  final Uri? url;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? fallback;
  final Duration fadeDuration;
  final Map<String, String>? headers;

  /// Extra attempts after the first one. 3 means up to four requests, spread
  /// over ~7 seconds - long enough to ride out a server that is indexing or a
  /// Wi-Fi hiccup, short enough that a dead URL stops knocking.
  final int retries;

  @override
  State<NetImage> createState() => _NetImageState();
}

class _NetImageState extends State<NetImage> {
  int _attempt = 0;
  Timer? _retry;

  /// One line per URL per session: a broken poster is redrawn on every rebuild,
  /// and the log filled up with the same failure thousands of times.
  static final _reported = <String>{};

  @override
  void didUpdateWidget(covariant NetImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.headers != widget.headers) {
      _retry?.cancel();
      _retry = null;
      _attempt = 0;
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _onError(Object url, Object error) {
    if (_reported.length > 4000) _reported.clear();
    if (_reported.add('$url#$_attempt')) {
      if (_attempt == 0) {
        debugPrint('[image] $url: $error');
        AppLog.write('[image] $url: $error');
      }
    }
    if (_attempt >= widget.retries || _retry != null) return;
    final wait = Duration(milliseconds: 500 * (1 << _attempt));
    _retry = Timer(wait, () {
      _retry = null;
      if (!mounted) return;
      setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.url;
    if (u == null) return widget.fallback ?? const SizedBox.shrink();
    final ratio = TvScale.decodeRatio(context);
    final width = widget.width;
    final decode = width == null ? null : (width * ratio).round();
    return Image(
      image: NetImageProvider(u, decodeWidth: decode, headers: widget.headers, attempt: _attempt),
      width: width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, error, _) {
        _onError(u, error);
        return widget.fallback ?? const SizedBox.shrink();
      },
      frameBuilder: (context, child, frame, sync) {
        if (sync) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: widget.fadeDuration,
          curve: Curves.easeOut,
          child: child,
        );
      },
    );
  }
}
