import 'package:flutter/material.dart';

/// Expands the Send anchor upward, replacing Send with a dismiss action.
///
/// This modal surface deliberately has no send callback. The opening pointer's
/// release, sliding across actions, outside taps and Back can never send a draft.
/// The route owns focus traversal, Escape/Back and an accessible dismiss barrier;
/// the layer link follows the composer when its layout or keyboard inset changes.
/// The caller owns pushing this route and removing it if its anchor is disposed.
RawDialogRoute<bool> sendActionGroupRoute(
        BuildContext context, LayerLink anchor) =>
    _composerActionGroupRoute(
      context,
      anchor,
      alignment: Alignment.bottomRight,
      label: 'Send actions',
      actionLabel: 'Enhance prompt',
      actionIcon: Icons.auto_fix_high_outlined,
      closeLabel: 'Close send actions',
    );

/// Opens the photo action above the composer’s attachment button.
RawDialogRoute<bool> photoActionGroupRoute(
        BuildContext context, LayerLink anchor) =>
    _composerActionGroupRoute(
      context,
      anchor,
      alignment:
          AlignmentDirectional.bottomStart.resolve(Directionality.of(context)),
      label: 'Attachment actions',
      actionLabel: 'Photo',
      actionIcon: Icons.photo_outlined,
      closeLabel: 'Close attachment actions',
    );

RawDialogRoute<bool> _composerActionGroupRoute(
  BuildContext context,
  LayerLink anchor, {
  required Alignment alignment,
  required String label,
  required String actionLabel,
  required IconData actionIcon,
  required String closeLabel,
}) =>
    RawDialogRoute<bool>(
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (context, animation, secondaryAnimation) => Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: anchor,
              showWhenUnlinked: false,
              targetAnchor: alignment,
              followerAnchor: alignment,
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                label: label,
                child: Material(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  elevation: 4,
                  child: SizedBox(
                    width: 48,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          autofocus: true,
                          tooltip: actionLabel,
                          constraints: const BoxConstraints.tightFor(
                              width: 48, height: 48),
                          style: IconButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.onPrimary,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => Navigator.of(context).pop(true),
                          icon: Icon(actionIcon),
                        ),
                        IconButton(
                          tooltip: closeLabel,
                          constraints: const BoxConstraints.tightFor(
                              width: 48, height: 48),
                          style: IconButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.onPrimary,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => Navigator.of(context).pop(false),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
