import 'package:flutter/material.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.subtitle,
    this.titleAction,
    this.header,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? titleAction;
  final Widget? header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (header != null)
              header!
            else ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                  if (titleAction != null) ...<Widget>[
                    const SizedBox(width: 12),
                    titleAction!,
                  ],
                ],
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
