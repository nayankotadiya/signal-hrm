import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../app/services.dart';
import '../data/api.dart';
import 'async_view.dart';

/// Renders an authenticated file by downloading `/files/$fileId/content`.
class AuthedImage extends StatelessWidget {
  const AuthedImage({
    super.key,
    required this.fileId,
    this.height = 320,
    this.width,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final String fileId;
  final double? height;
  final double? width;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final radius = borderRadius ?? BorderRadius.circular(t.radiusTile);

    return AsyncView<DownloadedFile>(
      load: () => context.api.download('/files/$fileId/content'),
      compact: true,
      builder: (context, f, _) => ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          f.bytes,
          height: height,
          width: width,
          fit: fit,
          semanticLabel: 'Attendance photo',
        ),
      ),
    );
  }
}
