import 'dart:io';

import '../config/project_config.dart';
import '../utils/http_json_client.dart';
import '../utils/process_runner.dart';

/// Everything a Setup Kit step may use. Fully injectable for tests.
class SetupContext {
  final String projectRoot;
  final ProjectConfig config;
  final Map<String, String> env;
  final ProcessRunner processes;
  final HttpJsonClient http;
  final bool dryRun;
  final StringSink out;

  SetupContext({
    required this.projectRoot,
    required this.config,
    required this.env,
    ProcessRunner? processes,
    HttpJsonClient? http,
    this.dryRun = false,
    StringSink? out,
  })  : processes = processes ?? const ProcessRunner(),
        http = http ?? IoHttpJsonClient(),
        out = out ?? stdout;
}

/// One idempotent Setup Kit step (`easy_setup setup --only <name>`).
abstract class SetupStep {
  /// Step name used by --only and in the run log.
  String get name;

  /// Whether the config declares the section this step acts on.
  bool isConfigured(ProjectConfig config);

  /// Converges the project to the declared state. Must be idempotent.
  Future<void> run(SetupContext context);
}
