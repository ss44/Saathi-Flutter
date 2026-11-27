import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/saathi_core.dart' show ChatPhoto;

/// Picks a local still photo without uploading or retaining the picker path.
Future<ChatPhoto?> pickChatPhoto() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1280,
    maxHeight: 1280,
    imageQuality: 80,
    requestFullMetadata: false,
  );
  if (file == null) return null;
  if (await file.length() > ChatPhoto.maxBytes) {
    throw const FormatException('Choose a photo of 1 MB or less.');
  }
  final photo = ChatPhoto.fromBytes(await file.readAsBytes());
  final buffer = await ui.ImmutableBuffer.fromUint8List(photo.bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > 16 * 1024 * 1024) {
        throw const FormatException('Choose a smaller photo.');
      }
      final codec =
          await descriptor.instantiateCodec(targetWidth: 64, targetHeight: 64);
      try {
        if (codec.frameCount != 1) {
          throw const FormatException('Choose a still photo.');
        }
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  return photo;
}

/// A horizontally scrolling filmstrip for draft or posted photos.
class ChatPhotoStrip extends StatelessWidget {
  const ChatPhotoStrip({
    super.key,
    required this.photos,
    this.onRemove,
  });

  final List<ChatPhoto> photos;
  final ValueChanged<int>? onRemove;

  @override
  Widget build(BuildContext context) {
    final size = onRemove == null ? 112.0 : 56.0;
    final colors = Theme.of(context).colorScheme;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, photo) in photos.indexed)
            Padding(
              padding: EdgeInsetsDirectional.only(
                  end: index == photos.length - 1 ? 0 : 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    Image(
                      image: ResizeImage(
                        MemoryImage(photo.bytes),
                        width: pixels,
                        height: pixels,
                        policy: ResizeImagePolicy.fit,
                      ),
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      semanticLabel: 'Photo ${index + 1}',
                      errorBuilder: (_, __, ___) => SizedBox.square(
                        dimension: size,
                        child: const Icon(
                          Icons.broken_image_outlined,
                          semanticLabel: 'Photo preview unavailable',
                        ),
                      ),
                    ),
                    if (onRemove case final remove?)
                      PositionedDirectional(
                        end: 0,
                        top: 0,
                        child: IconButton(
                          tooltip: 'Remove photo ${index + 1}',
                          constraints: const BoxConstraints.tightFor(
                              width: 48, height: 48),
                          alignment: AlignmentDirectional.topEnd,
                          padding: const EdgeInsets.all(2),
                          onPressed: () => remove(index),
                          icon: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.inverseSurface,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(Icons.close,
                                  size: 16, color: colors.onInverseSurface),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
