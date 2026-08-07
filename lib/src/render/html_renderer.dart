import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../exceptions.dart';
import '../utils/process_runner.dart';

/// Renders an HTML page to a pixel-exact bitmap.
///
/// The store asset pipelines (app icon SVGs, marketing screenshots) all
/// describe their design in HTML/CSS/SVG — text that lives in git, can be
/// diffed, and can be rewritten by an AI skill — and rely on this to turn
/// that into the exact pixel sizes Apple and Google require.
abstract class HtmlRenderer {
  /// Renders [html] in a [width]×[height] viewport.
  ///
  /// When [transparent] is true the page background starts fully
  /// transparent (Android adaptive icon layers); otherwise it starts
  /// opaque white so a page that paints nothing still yields a valid
  /// store asset instead of a transparent hole.
  Future<img.Image> render({
    required String html,
    required int width,
    required int height,
    bool transparent = false,
  });
}

/// [HtmlRenderer] backed by a locally installed Chrome/Chromium.
///
/// Deliberately driven through Chrome's own command-line screenshot mode
/// rather than a CDP client: it needs no Node toolchain, no npm install
/// and no browser download — just a browser the developer already has.
class ChromeRenderer implements HtmlRenderer {
  /// Env var pointing at a specific browser binary, checked first.
  static const executableEnvVar = 'CHROME_PATH';

  /// macOS application bundles, in preference order.
  static const macOsCandidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
  ];

  /// Names looked up on PATH (Linux, and non-standard macOS installs).
  static const pathCandidates = [
    'google-chrome',
    'google-chrome-stable',
    'chromium',
    'chromium-browser',
    'chrome',
  ];

  static const installHint =
      'Install Google Chrome (https://google.com/chrome), or point '
      '$executableEnvVar at an existing Chromium-based browser.';

  final ProcessRunner processes;
  final Map<String, String> env;

  /// How long to wait for a single page to be captured.
  final Duration timeout;

  String? _executable;

  ChromeRenderer({
    ProcessRunner? processes,
    this.env = const {},
    this.timeout = const Duration(seconds: 60),
  }) : processes = processes ?? const ProcessRunner();

  /// Locates the browser binary, or null when none is installed.
  /// The result is cached for the lifetime of this renderer.
  Future<String?> findExecutable() async {
    if (_executable != null) return _executable;
    final configured = env[executableEnvVar];
    if (configured != null && configured.isNotEmpty) {
      if (!File(configured).existsSync()) {
        throw SetupException(
          '$executableEnvVar points at $configured, which does not exist.',
        );
      }
      return _executable = configured;
    }
    if (Platform.isMacOS) {
      for (final candidate in macOsCandidates) {
        if (File(candidate).existsSync()) return _executable = candidate;
      }
    }
    for (final candidate in pathCandidates) {
      final resolved = await processes.which(candidate);
      if (resolved != null) return _executable = resolved;
    }
    return null;
  }

  @override
  Future<img.Image> render({
    required String html,
    required int width,
    required int height,
    bool transparent = false,
  }) async {
    final executable = await findExecutable();
    if (executable == null) {
      throw SetupException(
        'No Chrome/Chromium found — it renders the store assets. '
        '$installHint',
      );
    }

    final workDir = Directory.systemTemp.createTempSync('easy_setup_render');
    try {
      final page = File(p.join(workDir.path, 'page.html'))
        ..writeAsStringSync(html);
      final output = File(p.join(workDir.path, 'shot.png'));
      final bytes = await _capture(executable, [
        '--headless=new',
        '--disable-gpu',
        '--hide-scrollbars',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        // Containers (CI) default to a 64MB /dev/shm, which Chrome outgrows.
        '--disable-dev-shm-usage',
        // A private profile: without it Chrome would attach to the
        // developer's already-running instance and never take the shot.
        '--user-data-dir=${p.join(workDir.path, 'profile')}',
        '--allow-file-access-from-files',
        '--force-device-scale-factor=1',
        '--run-all-compositor-stages-before-draw',
        // Fast-forwards timers and font loading.
        '--virtual-time-budget=5000',
        if (transparent) '--default-background-color=00000000',
        '--window-size=$width,$height',
        '--screenshot=${output.path}',
        Uri.file(page.path).toString(),
      ], output);

      final image = img.decodePng(bytes);
      if (image == null) {
        throw SetupException('Chrome wrote a PNG that could not be decoded.');
      }
      if (image.width != width || image.height != height) {
        throw SetupException(
          'Expected a $width×$height render but Chrome produced '
          '${image.width}×${image.height}. Update Chrome, or report this '
          'with your Chrome version.',
        );
      }
      return image;
    } finally {
      try {
        workDir.deleteSync(recursive: true);
      } on FileSystemException {
        // A killed browser may still hold profile files; the OS reclaims
        // the temp directory either way.
      }
    }
  }

  /// Runs Chrome and returns the captured PNG.
  ///
  /// Chrome writes the file and then, since 130-ish, keeps running instead
  /// of exiting — so the file is what is waited on, not the process. The
  /// PNG is only accepted once its terminating IEND chunk has landed, so a
  /// partially flushed capture is never decoded.
  Future<Uint8List> _capture(
      String executable, List<String> arguments, File output) async {
    final Process process;
    try {
      process = await Process.start(executable, arguments);
    } on ProcessException catch (e) {
      throw SetupException('Could not start $executable: ${e.message}');
    }
    final stderrBuffer = StringBuffer();
    final drained = Future.wait([
      process.stderr
          .transform(utf8.decoder)
          .forEach(stderrBuffer.write)
          .catchError((_) {}),
      process.stdout.drain<void>().catchError((_) {}),
    ]);

    try {
      final deadline = DateTime.now().add(timeout);
      var exited = false;
      unawaited(process.exitCode.then((_) => exited = true));
      while (DateTime.now().isBefore(deadline)) {
        if (output.existsSync()) {
          final bytes = output.readAsBytesSync();
          if (isCompletePng(bytes)) return bytes;
        }
        if (exited) break;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      throw SetupException(
        'Chrome did not produce a screenshot within '
        '${timeout.inSeconds}s.\n${_tail(stderrBuffer)}',
      );
    } finally {
      process.kill();
      await process.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      });
      // Bounded: a browser whose pipes never close must not turn a
      // render timeout into a hang.
      await drained.timeout(const Duration(seconds: 5),
          onTimeout: () => const <void>[]);
    }
  }

  /// True once [bytes] is a PNG terminated by its IEND chunk.
  static bool isCompletePng(Uint8List bytes) {
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    const iendChunk = [
      0, 0, 0, 0, // length
      0x49, 0x45, 0x4E, 0x44, // 'IEND'
      0xAE, 0x42, 0x60, 0x82, // CRC
    ];
    if (bytes.length < signature.length + iendChunk.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    final start = bytes.length - iendChunk.length;
    for (var i = 0; i < iendChunk.length; i++) {
      if (bytes[start + i] != iendChunk[i]) return false;
    }
    return true;
  }

  /// Chrome is chatty on stderr; only the last few lines are useful.
  static String _tail(Object? stderr) {
    final lines = '$stderr'
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.length <= 8 ? lines.join('\n') : lines.sublist(lines.length - 8).join('\n');
  }
}
