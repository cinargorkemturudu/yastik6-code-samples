import 'package:flutter/material.dart';

/// A standardized, overflow-safe text widget for financial apps: it stops large numbers and long asset names
/// from overflowing the screen.
class AppSafeText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int maxLines;
  final bool flex; // Usually used inside a Row/Column, so flexibility (Flexible) is on by default.

  const AppSafeText(
      this.text, {
        super.key,
        this.style,
        this.maxLines = 1,
        this.flex = true,
      });

  @override
  Widget build(BuildContext context) {
    // 1. The original Text widget (overflow-safe)
    Widget content = Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );

    // 2. Layout protection
    // Inside a Row or Column it is wrapped in Flexible to keep it from pushing other widgets 
    // and causing a RenderFlex overflow.
    return flex ? Flexible(child: content) : content;
  }
}