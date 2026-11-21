abstract final class AssetValues {
  static const String _vectors = 'assets/vectors';
  static const String _images = 'assets/images';

  // The 2025 gradient "Super G" — official conic-gradient SVG isn't
  // renderable by flutter_svg, so it's rasterized once at 340px.
  static const String googleG = '$_images/google-g.png';
  static const String appleLogo = '$_vectors/apple-logo.svg';
}
