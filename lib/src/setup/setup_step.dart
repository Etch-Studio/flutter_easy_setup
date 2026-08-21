import 'dart:io';

import '../config/project_config.dart';
import '../render/html_renderer.dart';
import '../utils/http_json_client.dart';
import '../utils/process_runner.dart';

/// Everything a Setup Kit step may use. Fully injectable for tests.
class SetupContext {
  final String projectRoot;
  final ProjectConfig config;
  final Map<String, String> env;
  final ProcessRunner processes;
  final HttpJsonClient http;

  /// Turns the HTML/SVG design sources into store-sized bitmaps.
  final HtmlRenderer renderer;

  final bool dryRun;

  /// Read the world back into easy_setup.yaml instead of only applying it.
  ///
  /// A bootstrap, never the default: the yaml is the intent every step
  /// converges on, so a run that quietly re-added whatever a console holds
  /// would make an ad unit impossible to delete.
  final bool adopt;

  final StringSink out;

  SetupContext({
    required this.projectRoot,
    required this.config,
    required this.env,
    ProcessRunner? processes,
    HttpJsonClient? http,
    HtmlRenderer? renderer,
    this.dryRun = false,
    this.adopt = false,
    StringSink? out,
  })  : processes = processes ?? const ProcessRunner(),
        http = http ?? IoHttpJsonClient(),
        renderer = renderer ??
            ChromeRenderer(processes: processes, env: env),
        out = out ?? stdout;
}

/// One idempotent Setup Kit step (`easy_setup setup --only <name>`).
abstract class SetupStep {
  /// Step name used by --only and in the run log.
  String get name;

  /// Whether the config declares the section this step acts on.
  bool isConfigured(ProjectConfig config);

  /// Whether the step has anything to act on. Defaults to [isConfigured];
  /// steps activated by a file's presence (not a yaml section) override
  /// this.
  bool isActive(SetupContext context) => isConfigured(context.config);

  /// What the user must add to activate the step — used in error/skip
  /// messages.
  String get configurationHint => 'its section in easy_setup.yaml';

  /// Converges the project to the declared state. Must be idempotent.
  Future<void> run(SetupContext context);
}
