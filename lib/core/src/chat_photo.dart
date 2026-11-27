import 'dart:convert';
import 'dart:typed_data';

/// An inline draft photo. The bytes are owned by the message, independently of
/// the device picker and its temporary files.
class ChatPhoto {
  ChatPhoto._(this.bytes, this.mimeType);

  static const maxCount = 4;
  static const maxBytes = 1024 * 1024;
  final Uint8List bytes;
  final String mimeType;

  /// Copies a bounded JPEG, PNG or WebP into an immutable photo.
  factory ChatPhoto.fromBytes(Uint8List bytes) {
    bool startsWith(List<int> signature, [int offset = 0]) =>
        bytes.length >= offset + signature.length &&
        signature.indexed
            .every((entry) => bytes[offset + entry.$1] == entry.$2);

    if (bytes.length > maxBytes) {
      throw const FormatException('Photos must total 1 MB or less.');
    }
    final mimeType = switch (bytes) {
      _ when startsWith([0xff, 0xd8, 0xff]) => 'image/jpeg',
      _ when startsWith([137, 80, 78, 71, 13, 10, 26, 10]) => 'image/png',
      _ when startsWith([82, 73, 70, 70]) && startsWith([87, 69, 66, 80], 8) =>
        'image/webp',
      _ => throw const FormatException('Choose a JPEG, PNG or WebP photo.'),
    };
    return ChatPhoto._(
        Uint8List.fromList(bytes).asUnmodifiableView(), mimeType);
  }

  late final String base64Data = base64Encode(bytes);

  /// Inline representation accepted by OpenAI-style image input.
  String get dataUrl => 'data:$mimeType;base64,$base64Data';

  static int totalBytes(Iterable<ChatPhoto> photos) =>
      photos.fold(0, (size, photo) => size + photo.bytes.length);

  static bool fitsDraft(List<ChatPhoto> photos) =>
      photos.length <= maxCount && totalBytes(photos) <= maxBytes;

  /// Reads the whitelisted inline format used by local history and recovery.
  /// Validates the aggregate encoded size before allocating decoded buffers.
  static List<ChatPhoto> decodeList(Object? value) {
    if (value == null) return const [];
    if (value is! List ||
        value.length > maxCount ||
        value.any((item) => item is! String) ||
        value.cast<String>().fold(0, (size, item) => size + item.length) >
            ((maxBytes + 2) ~/ 3) * 4 + maxCount * 4) {
      throw const FormatException('Invalid saved photos');
    }
    final photos = [
      for (final data in value.cast<String>())
        ChatPhoto.fromBytes(base64Decode(data))
    ];
    if (!fitsDraft(photos)) throw const FormatException('Invalid saved photos');
    return photos;
  }
}
