/// `{{PLACEHOLDER}}` substitution for the generated HTML templates.
///
/// The templates are owned by the user (and rewritten by the AI skills),
/// so the contract between Dart and HTML is deliberately this one dumb
/// rule: an uppercase token in double braces is replaced by a value. New
/// palette entries become new placeholders without any Dart change.
library;

final _placeholderPattern = RegExp(r'\{\{([A-Z0-9_]+)\}\}');

/// Replaces every `{{KEY}}` in [template] that has an entry in [values].
///
/// Substituted values are never rescanned, so copy that happens to contain
/// `{{...}}` survives as the literal text the author wrote.
String fillTemplate(String template, Map<String, String> values) =>
    template.replaceAllMapped(_placeholderPattern,
        (match) => values[match.group(1)!] ?? match.group(0)!);

/// Every distinct placeholder name [template] refers to, sorted.
List<String> placeholderNames(String template) => _placeholderPattern
    .allMatches(template)
    .map((match) => match.group(1)!)
    .toSet()
    .toList()
  ..sort();
