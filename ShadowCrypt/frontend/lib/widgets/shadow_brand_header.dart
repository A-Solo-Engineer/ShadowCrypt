import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Reusable branding header with SVG logo and monospaced app title.
class ShadowBrandHeader extends StatelessWidget {
  const ShadowBrandHeader({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SvgPicture.asset(
          'assets/logo/double_ratchet_logo_no_text.svg',
          height: 32,
          colorFilter: const ColorFilter.mode(
            Colors.white,
            BlendMode.srcIn,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'SHADOWCRYPT',
          style: TextStyle(
            color: Colors.cyanAccent,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            fontFamily: 'Courier',
            letterSpacing: 1.6,
          ),
        ),
      ],
    );
  }
}
