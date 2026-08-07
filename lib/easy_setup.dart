/// Defines the public API of the easy_setup library.
///
/// This file re-exports the public symbols accessible via
/// `import 'package:easy_setup/easy_setup.dart'`.
library;

export 'src/appstore/asc_api_client.dart';
export 'src/appstore/asc_jwt.dart';

export 'src/commands/ci_cd_command.dart';
export 'src/commands/deploy_command.dart';
export 'src/commands/doctor_command.dart';
export 'src/commands/flavor_command.dart';
export 'src/commands/init_command.dart';
export 'src/commands/setup_command.dart';

export 'src/appstore/asc_api_key_file.dart';
export 'src/config/project_config.dart';
export 'src/config/store_info_config.dart';
export 'src/deploy/android_deployer.dart';
export 'src/deploy/deploy_steps.dart';
export 'src/deploy/ios_deployer.dart';
export 'src/deploy/version_resolver.dart';
export 'src/doctor/check.dart';
export 'src/doctor/checks/android_deploy_checks.dart';
export 'src/doctor/checks/environment_checks.dart';
export 'src/doctor/checks/integration_checks.dart';
export 'src/doctor/checks/ios_deploy_checks.dart';
export 'src/doctor/checks/project_checks.dart';
export 'src/doctor/doctor_runner.dart';

export 'src/exceptions.dart';
export 'src/setup/admob_step.dart';
export 'src/setup/branding_step.dart';
export 'src/setup/captions_config.dart';
export 'src/setup/env_json_writer.dart';
export 'src/setup/firebase_step.dart';
export 'src/setup/ios_capabilities_step.dart';
export 'src/setup/plist_text.dart';
export 'src/setup/screenshots_step.dart';
export 'src/setup/sentry_step.dart';
export 'src/setup/setup_step.dart';
export 'src/setup/store_step.dart';
export 'src/ios/app_icon_generator.dart';
export 'src/ios/info_plist_strings_generator.dart';
export 'src/ios/xcodegen_generator.dart';
export 'src/ios/xcodegen_scripts_generator.dart';
export 'src/firebase/firebase_copier.dart' show FirebaseConfigurator;
export 'src/firebase/firebase_options_generator.dart';
export 'src/models/ci_cd_config.dart';
// v1 FirebaseConfig is hidden — the name now belongs to the v2 schema
// (src/config/project_config.dart). Import the v1 model file directly if
// the legacy class is needed.
export 'src/models/flavor_config.dart' hide FirebaseConfig;
export 'src/utils/fastlane_runner.dart';
export 'src/utils/http_json_client.dart';
export 'src/utils/process_runner.dart';
export 'src/utils/project_finder.dart';
export 'src/utils/xcodegen_runner.dart';
