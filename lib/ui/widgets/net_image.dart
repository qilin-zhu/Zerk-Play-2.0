import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../../core/log/logging_http_client.dart';
import '../core/tv_scale.dart';
import 'image_disk_cache.dart';

@immutable
class NetImageProvider extends ImageProvider<NetImageProvider> {
  const NetImageProvider(this.url, {this.decodeWidth, this.headers});

  final Uri url;
  final int? decodeWidth;
  final Map<String, String>? headers;

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
    final cached = await readCachedImage(url);
    if (cached != null) return cached;
    final request = http.Request('GET', url);
    final extra = headers;
    if (extra != null && extra.isNotEmpty) request.headers.addAll(extra);
    final res = await _client.send(request).then(http.Response.fromStream).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw NetworkImageLoadException(statusCode: res.statusCode, uri: url);
    }
    writeCachedImage(url, res.bodyBytes);
    return res.bodyBytes;
  }

  @override
  bool operator ==(Object other) =>
      other is NetImageProvider &&
      other.url == url &&
      other.decodeWidth == decodeWidth &&
      other.headers == headers;

  @override
  int get hashCode => Object.hash(url, decodeWidth, headers);
}

class NetImage extends StatelessWidget {
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
  });

  final Uri? url;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final Widget? fallback;
  final Duration fadeDuration;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null) return fallback ?? const SizedBox.shrink();
    final ratio = TvScale.decodeRatio(context);
    final decode = width == null ? null : (width! * ratio).round();
    return Image(
      image: NetImageProvider(u, decodeWidth: decode, headers: headers),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, error, _) {
        debugPrint('[image] $u: $error');
        return fallback ?? const SizedBox.shrink();
      },
      frameBuilder: (context, child, frame, sync) {
        if (sync) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: fadeDuration,
          curve: Curves.easeOut,
          child: child,
        );
      },
    );
  }
}
