import 'dart:convert';
import 'dart:typed_data';

/// 64-bit FNV-1a over the given chunks, as a 16-char hex string.
///
/// Used to stamp generated assets with the fingerprint of everything that
/// produced them, so an unchanged input can skip an expensive re-render.
/// Not a security primitive — collisions here would only mean a stale
/// asset, and FNV-1a is deterministic across Dart SDK versions (unlike
/// `Object.hash`, whose seed is an implementation detail).
String contentHash(Iterable<Object> chunks) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final chunk in chunks) {
    final bytes = switch (chunk) {
      Uint8List value => value,
      List<int> value => Uint8List.fromList(value),
      _ => utf8.encode('$chunk'),
    };
    // Dart ints are 64-bit two's complement, so the multiply wraps exactly
    // the way FNV-1a expects.
    for (final byte in bytes) {
      hash = (hash ^ byte) * prime;
    }
    // Length-delimit so ['ab','c'] and ['a','bc'] hash differently.
    hash = (hash ^ bytes.length) * prime;
  }
  // Rendered as two unsigned halves — a negative int has no 16-char hex.
  return (hash >> 32).toUnsigned(32).toRadixString(16).padLeft(8, '0') +
      hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}
