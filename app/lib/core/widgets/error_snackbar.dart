import 'package:flutter/material.dart';
import '../errors/app_error.dart';
import '../theme/design_tokens.dart';

void showAppError(BuildContext context, AppError error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error.userMessage),
      backgroundColor: BrandColors.error,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
