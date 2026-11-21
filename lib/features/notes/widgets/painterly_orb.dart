import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';

/// Hand-painted ink / watercolor / dry-brush tumbling hollow orb.
///
/// **Spec Details**:
/// - NOT a glossy 3D sphere or neon ring; looks like deep ultramarine-cobalt
///   ink on paper, a rolling brush-stroke hollow bowl/torus tumbling in 3D.
/// - Dark navy core strokes: `#0B1550` to `#0A1A6B` (almost black blue) at thick rim.
/// - Main body blue: cobalt/ultramarine `#1F3FC0` to `#2A4FD6`.
/// - Light highlight blue: `#5FA8E8` (light sky/cyan tint) at inner hollow rim.
/// - Hollow/cavity center: soft transparent opening showing background through.
/// - Dry-brush feathered edge with bristle speckles and pigment grain.
/// - Directional wet-ink motion smear opposite movement direction.
/// - Looped ~3.4s 3D tumble cycle: closed ball -> wide ring -> tilted oval -> wide ring -> closed ball.
class VoicePoweredOrb extends StatefulWidget {
  const VoicePoweredOrb({
    super.key,
    this.size = 220.0,
    this.animating = true,
    this.enableVoiceControl = false,
    this.voiceLevel = 0.0,
    this.voiceSensitivity = 1.5,
    this.maxRotationSpeed = 1.2,
    this.maxHoverIntensity = 0.8,
    this.onVoiceDetected,
    // Optional compatibility props
    this.colors,
    this.hue = 0.0,
    this.glow = 1.0,
    this.bleed = 1.0,
    this.wobble = 1.0,
    this.highlight = 1.0,
    this.trail = 1.0,
    this.speed = 1.0,
    this.clickPulse = true,
    this.followTouch = true,
    this.intro = true,
  });

  /// Diameter of the orb in logical pixels.
  final double size;

  /// Whether the idle tumble animation is actively playing.
  final bool animating;

  /// Whether microphone/voice activity scales the pulse and rotation speed.
  final bool enableVoiceControl;

  /// Normalized audio input level (0.0 to 1.0).
  final double voiceLevel;

  final double voiceSensitivity;
  final double maxRotationSpeed;
  final double maxHoverIntensity;
  final ValueChanged<bool>? onVoiceDetected;

  // Compatibility parameters
  final List<Color>? colors;
  final double hue;
  final double glow;
  final double bleed;
  final double wobble;
  final double highlight;
  final double trail;
  final double speed;
  final bool clickPulse;
  final bool followTouch;
  final bool intro;

  @override
  State<VoicePoweredOrb> createState() => _VoicePoweredOrbState();
}

/// Backwards-compatible aliases for existing consumers and tests.
typedef PainterlyOrb = VoicePoweredOrb;
typedef Orb = VoicePoweredOrb;

class _VoicePoweredOrbState extends State<VoicePoweredOrb>
    with SingleTickerProviderStateMixin {
  /// Exactly 3.4 seconds per full 3D tumble cycle.
  static const Duration _cycleDuration = Duration(milliseconds: 3400);

  late final AnimationController _ctrl;
  DateTime? _lastTick;
  double _timeSeconds = 0.0;
  double _pulse = 0.0;
  double _pulseSpeed = 0.0;

  // Pre-calculated pigment grain & dry-brush bristle offsets (stable seed)
  static final List<_PigmentDot> _grain = _generateGrain(320);

  static List<_PigmentDot> _generateGrain(int count) {
    final math.Random rng = math.Random(0x0B1550);
    final List<_PigmentDot> dots = <_PigmentDot>[];
    for (int i = 0; i < count; i++) {
      final double angle = rng.nextDouble() * math.pi * 2.0;
      // Concentrate grain on outer body & rim
      final double r = 0.45 + rng.nextDouble() * 0.52;
      final double dotSize = 0.6 + rng.nextDouble() * 1.6;
      final double alpha = 0.12 + rng.nextDouble() * 0.28;
      dots.add(_PigmentDot(
        angle: angle,
        radius: r,
        size: dotSize,
        alpha: alpha,
        isDark: rng.nextBool(),
      ));
    }
    return dots;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: _cycleDuration,
    );

    _ctrl.addListener(_onTick);

    if (widget.animating) {
      _ctrl.repeat();
    }
  }

  void _onTick() {
    final DateTime now = DateTime.now();
    final double dt = _lastTick != null
        ? (now.difference(_lastTick!).inMicroseconds / 1000000.0).clamp(0.001, 0.05)
        : 1.0 / 60.0;
    _lastTick = now;

    double timeScale = widget.speed;
    if (widget.enableVoiceControl) {
      final double effectiveLevel =
          (widget.voiceLevel * widget.voiceSensitivity).clamp(0.0, 1.0);
      timeScale += effectiveLevel * 0.5 * widget.maxRotationSpeed;
      final bool detected = effectiveLevel > 0.08;
      widget.onVoiceDetected?.call(detected);
    }

    _timeSeconds += dt * timeScale;

    // Spring damping for tap pulse
    _pulseSpeed += (-170.0 * _pulse - 11.0 * _pulseSpeed) * dt;
    _pulse += _pulseSpeed * dt;
  }

  void _triggerPulse() {
    if (!widget.clickPulse) return;
    setState(() {
      _pulseSpeed += 0.7;
    });
  }

  @override
  void didUpdateWidget(VoicePoweredOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animating && !_ctrl.isAnimating) {
      _lastTick = DateTime.now();
      _ctrl.repeat();
    } else if (!widget.animating && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _triggerPulse(),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (BuildContext context, _) {
            // Normalized phase in [0, 1) through the 3.4s cycle
            final double phase = (_timeSeconds / 3.4) % 1.0;
            return CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _PainterlyInkOrbPainter(
                phase: phase,
                pulse: _pulse,
                grain: _grain,
                voiceLevel: widget.enableVoiceControl
                    ? (widget.voiceLevel * widget.voiceSensitivity).clamp(0.0, 1.0)
                    : 0.0,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PigmentDot {
  const _PigmentDot({
    required this.angle,
    required this.radius,
    required this.size,
    required this.alpha,
    required this.isDark,
  });

  final double angle;
  final double radius;
  final double size;
  final double alpha;
  final bool isDark;
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter: 3D Tumbling Dry-Brush Ink Orb
// ─────────────────────────────────────────────────────────────────────────────

class _PainterlyInkOrbPainter extends CustomPainter {
  _PainterlyInkOrbPainter({
    required this.phase,
    required this.pulse,
    required this.grain,
    required this.voiceLevel,
  });

  final double phase;
  final double pulse;
  final List<_PigmentDot> grain;
  final double voiceLevel;

  // ── Palette from spec ──────────────────────────────────────────────────────
  static const Color _darkNavy = Color(0xFF0B1550); // thick rim stroke
  static const Color _deepBlue = Color(0xFF0A1A6B); // dark gradient stop
  static const Color _cobalt1 = Color(0xFF1F3FC0); // main body ultramarine
  static const Color _cobalt2 = Color(0xFF2A4FD6); // vibrant cobalt
  static const Color _cyanHighlight = Color(0xFF5FA8E8); // inner hollow rim glow
  static const Color _cavityCream = Color(0xFFF2E8DE); // background hollow soft tone

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width * 0.5, size.height * 0.5);
    final double t = phase * 3.4; // time in seconds (0.0 to 3.4)

    // ── 1. 3.4s Timeline Keyframe Calculations ──────────────────────────────
    // Timeline breakdown from spec:
    // t=0.0s: cavity upper-left, small slanted oval, dark rim on right/bottom, smear on right.
    // t=0.2-0.4s: cavity closes (solid blue ball with soft lighter center).
    // t=0.6-0.8s: cavity opens in middle, cream center grows, rim becomes dark thick ring.
    // t=1.0-1.2s: wide open ring (hole ~55% diameter), cyan highlight on inner lower edge.
    // t=1.4-1.6s: tilts, hole shifts to left and narrows to slanted oval, thick body right with smear.
    // t=1.8s: tilts other way, flat oval at top.
    // t=2.0-2.4s: open ring again, hole big, rim thick on right.
    // t=2.6-2.8s: hole shrinks to left, smear on right.
    // t=3.0-3.2s: closes again (solid ball look with soft spot).
    // t=3.4s: loop point.

    // Cycle breathing (3-5% size change)
    final double breathing = 1.0 + 0.04 * math.sin(phase * math.pi * 4.0) + (pulse * 0.15);
    final double baseR = (size.width * 0.44) * breathing;

    // Openness: fraction of baseR that the cavity spans (0.05 when closed, up to 0.55 when open)
    // 2 open/close pulses per 3.4s cycle
    final double openWave = math.sin(phase * math.pi * 4.0 - 0.7);
    final double asymmetry = 0.12 * math.cos(phase * math.pi * 2.0);
    // Smooth clamped openness
    final double openness = (0.30 + 0.25 * openWave + asymmetry).clamp(0.04, 0.56);
    final bool isClosed = openness < 0.12;

    // Cavity center offset (cx, cy) relative to orb center
    final double angleP = phase * math.pi * 2.0;
    final double cx = baseR * (0.32 * math.sin(angleP - 0.5) + 0.10 * math.sin(angleP * 2.0));
    final double cy = baseR * (-0.24 * math.cos(angleP) + 0.08 * math.cos(angleP * 2.0));
    final Offset cavityCenter = Offset(center.dx + cx, center.dy + cy);

    // Cavity oval slant angle and aspect ratio
    final double tiltAngle = 0.45 * math.sin(angleP + 0.3) + 0.25 * math.cos(angleP * 2.0);
    final double aspectX = 1.0 + 0.22 * math.sin(angleP * 2.0);
    final double aspectY = 1.0 - 0.22 * math.sin(angleP * 2.0);
    final double cavRx = baseR * openness * aspectX;
    final double cavRy = baseR * openness * aspectY;

    // Motion velocity vector for directional smear fringe (side opposite motion)
    final double velX = math.cos(angleP - 0.5) + 0.6 * math.cos(angleP * 2.0);
    final double velY = math.sin(angleP) - 0.4 * math.sin(angleP * 2.0);
    final double velNorm = math.sqrt(velX * velX + velY * velY) + 0.001;
    // Smear trail extends opposite to velocity
    final Offset smearDir = Offset(-velX / velNorm, -velY / velNorm);

    // ── 2. Wet-Paint Directional Motion-Smear Fringe ─────────────────────────
    // "lighter transparent blue trail about 10-15% of the diameter, like wet paint dragged"
    final double smearDist = baseR * 0.15;
    final Offset smearCenter = Offset(
      center.dx + smearDir.dx * smearDist,
      center.dy + smearDir.dy * smearDist,
    );
    final Paint smearPaint = Paint()
      ..color = _cobalt2.withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14.0);

    canvas.drawCircle(smearCenter, baseR * 0.98, smearPaint);

    // ── 3. Main Painterly Body (Cobalt & Ultramarine) ────────────────────────
    // Feathered rough dry-brush contour path
    final Path bodyPath = Path();
    const int numPoints = 80;
    for (int i = 0; i <= numPoints; i++) {
      final double theta = (i / numPoints) * math.pi * 2.0;
      // Slight organic irregularity + dry-brush micro wobble
      final double jitter = math.sin(theta * 7.0 + t * 2.0) * 0.025 +
          math.cos(theta * 11.0 - t * 1.5) * 0.015 +
          math.sin(theta * 3.0 + angleP) * 0.035;
      final double r = baseR * (1.0 + jitter);
      final double x = center.dx + r * math.cos(theta);
      final double y = center.dy + r * math.sin(theta);

      if (i == 0) {
        bodyPath.moveTo(x, y);
      } else {
        bodyPath.lineTo(x, y);
      }
    }
    bodyPath.close();

    // Darker toward rim, lighter toward center (painterly gradient)
    final Paint bodyPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment(cx / baseR * 0.6, cy / baseR * 0.6),
        radius: 0.95,
        colors: [
          _cobalt2,
          _cobalt1,
          _deepBlue,
          _darkNavy,
        ],
        stops: const [0.15, 0.55, 0.85, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: baseR))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8);

    canvas.drawPath(bodyPath, bodyPaint);

    // ── 4. Thick Dark Navy Core Stroke at Rim (Opposite Cavity) ──────────────
    // When cavity is at (cx, cy), thickest rim is at (-cx, -cy)
    final double darkRimAngle = math.atan2(-cy, -cx);
    final Path rimArc = Path();
    final Rect rimRect = Rect.fromCircle(center: center, radius: baseR * 0.92);
    rimArc.addArc(rimRect, darkRimAngle - 1.3, 2.6);

    final Paint darkRimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = baseR * 0.28
      ..strokeCap = StrokeCap.round
      ..color = _darkNavy.withValues(alpha: 0.88)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0);

    canvas.drawPath(rimArc, darkRimPaint);

    // ── 5. Hollow Cavity / Center Opening ────────────────────────────────────
    if (isClosed) {
      // t=0.2-0.4s and t=3.0-3.2s: "solid blue ball with a soft lighter center, no clear hole"
      final Paint softSpotPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            _cobalt2.withValues(alpha: 0.85),
            _cobalt1.withValues(alpha: 0.40),
            Colors.transparent,
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: cavityCenter, radius: baseR * 0.32))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);

      canvas.drawCircle(cavityCenter, baseR * 0.30, softSpotPaint);
    } else {
      // Cavity opens: soft feathered opening revealing the background through
      canvas.save();
      canvas.translate(cavityCenter.dx, cavityCenter.dy);
      canvas.rotate(tiltAngle);

      // Cavity hole soft-edge gradient (showing paper/cream background)
      final Rect holeRect = Rect.fromCenter(
        center: Offset.zero,
        width: cavRx * 2.0,
        height: cavRy * 2.0,
      );

      final Paint holePaint = Paint()
        ..shader = RadialGradient(
          colors: [
            _cavityCream.withValues(alpha: 0.92),
            _cavityCream.withValues(alpha: 0.65),
            Colors.transparent,
          ],
          stops: const [0.45, 0.85, 1.0],
        ).createShader(holeRect)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

      canvas.drawOval(holeRect, holePaint);

      // ── 6. Thin Cyan Highlight Blue at Inner Hollow Rim ────────────────────
      // "about #5FA8E8, only where the dark rim meets the hollow, a thin soft glow"
      final Path highlightArc = Path();
      // Lower inner edge arc
      highlightArc.addArc(
        Rect.fromCenter(
          center: const Offset(0.0, 1.5),
          width: cavRx * 1.85,
          height: cavRy * 1.85,
        ),
        0.2,
        2.7,
      );

      final Paint cyanPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = _cyanHighlight.withValues(alpha: 0.78)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);

      canvas.drawPath(highlightArc, cyanPaint);

      canvas.restore();
    }

    // ── 7. Hand-Painted Dry-Brush Bristle Speckles & Pigment Grain ───────────
    // Subtle grainy noise on pigment, rough feathered speckles along the silhouette
    final Paint grainPaint = Paint();
    for (final _PigmentDot dot in grain) {
      final double gAngle = dot.angle + (phase * 0.3); // slow organic drift
      final double gR = baseR * dot.radius;
      final double gx = center.dx + gR * math.cos(gAngle);
      final double gy = center.dy + gR * math.sin(gAngle);

      grainPaint.color = dot.isDark
          ? _darkNavy.withValues(alpha: dot.alpha * 0.75)
          : _cobalt2.withValues(alpha: dot.alpha * 0.60);

      canvas.drawCircle(Offset(gx, gy), dot.size, grainPaint);
    }

    // ── 8. Dry-Brush Feathered Outer Rim Bristles ────────────────────────────
    final Paint bristlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = _darkNavy.withValues(alpha: 0.35);

    const int bristleCount = 42;
    for (int b = 0; b < bristleCount; b++) {
      final double bAngle = (b / bristleCount) * math.pi * 2.0 + (angleP * 0.2);
      final double rStart = baseR * (0.96 + (b % 3) * 0.015);
      final double rEnd = baseR * (1.02 + ((b * 7) % 5) * 0.012);
      final double x1 = center.dx + rStart * math.cos(bAngle);
      final double y1 = center.dy + rStart * math.sin(bAngle);
      final double x2 = center.dx + rEnd * math.cos(bAngle + 0.04);
      final double y2 = center.dy + rEnd * math.sin(bAngle + 0.04);

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), bristlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PainterlyInkOrbPainter old) {
    return old.phase != phase ||
        old.pulse != pulse ||
        old.voiceLevel != voiceLevel;
  }
}
