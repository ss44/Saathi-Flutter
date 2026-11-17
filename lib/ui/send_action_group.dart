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
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.bottomRight,
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                label: 'Send actions',
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
                          tooltip: 'Enhance prompt',
                          constraints: const BoxConstraints.tightFor(
                              width: 48, height: 48),
                          style: IconButton.styleFrom(
                            foregroundColor:
                                Theme.of(context).colorScheme.onPrimary,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => Navigator.of(context).pop(true),
                          icon: const Icon(Icons.auto_fix_high_outlined),
                        ),
                        IconButton(
                          tooltip: 'Close send actions',
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
