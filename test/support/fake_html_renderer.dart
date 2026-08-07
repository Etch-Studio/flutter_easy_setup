import 'package:easy_setup/easy_setup.dart';
import 'package:image/image.dart' as img;

/// Records what would have been rendered and returns a flat bitmap of the
/// requested size, so the asset pipelines can be tested without a browser.
class FakeHtmlRenderer implements HtmlRenderer {
  final List<RenderCall> calls = [];

  /// Optional painter, for tests that need specific pixels back.
  final img.Image Function(RenderCall call)? painter;

  FakeHtmlRenderer({this.painter});

  RenderCall get last => calls.last;

  @override
  Future<img.Image> render({
    required String html,
    required int width,
    required int height,
    bool transparent = false,
  }) async {
    final call = RenderCall(
        html: html, width: width, height: height, transparent: transparent);
    calls.add(call);
    if (painter != null) return painter!(call);
    // Rendered pages are opaque unless the caller asked otherwise; mirror
    // that so alpha handling is exercised realistically.
    final image = img.Image(width: width, height: height, numChannels: 4);
    img.fill(image,
        color: img.ColorRgba8(24, 32, 48, transparent ? 0 : 255));
    return image;
  }
}

class RenderCall {
  final String html;
  final int width;
  final int height;
  final bool transparent;

  RenderCall({
    required this.html,
    required this.width,
    required this.height,
    required this.transparent,
  });
}
