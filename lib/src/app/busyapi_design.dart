// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// Modified for BusyAPI namespaces and contract authoring.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yaru/yaru.dart';

import '../platform/native_menu_service.dart';
import '../platform/gtk_header_icon_service.dart';
import 'busyapi_glyphs.dart';
import 'path_label.dart';

/// Resolve an explicit six-digit RGB color chosen in a document/export control.
/// This does not inherit the application's theme accent.
Color busyApiRgbHexColor(String value) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'value');
  }
  return Color(int.parse(value.substring(1), radix: 16) | 0xff000000);
}

abstract final class BusyApiSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double headerInset = 6;
  static const double sm = 8;
  static const double smPlus = 10;
  static const double md = 12;
  static const double mdPlus = 14;
  static const double lg = 16;
  static const double lgPlus = 18;
  static const double xl = 24;
  static const double xxl = 32;
  static const double tooltipHorizontal = 10;
  static const double tooltipVertical = 6;
}

abstract final class BusyApiRadius {
  static const double sm = 4;
  static const double tooltip = kYaruButtonRadius;
  static const double md = 8;
  static const double lg = kYaruContainerRadius;
  static const double headerButton = kYaruButtonRadius;
  // Compatibility name for sidebar callers; geometry remains Yaru-owned.
  static const double nativeHeaderButton = kYaruButtonRadius;
  static const double window = kYaruWindowRadius;
  static const double pill = 999;
}

abstract final class BusyApiSizes {
  static const double contentWidth = 760;
  static const double documentContentWidth = contentWidth;
  static const double sidebarWidth = 300;
  // The workspace header also needs room for document actions and window controls.
  static const double workspaceSidebarBreakpoint = sidebarWidth + 480;
  static const double sidebarRowHeight = 36;
  static const double settingsWidth = 760;
  static const double settingsSidebarBreakpoint = sidebarWidth + 520;
  static const double toolbarHeight = kYaruTitleBarHeight;
  static const double paneHeaderHeight = 38;
  static const double documentStatusBarHeight = 28;
  static const double iconButton = kYaruTitleBarItemHeight;
  static const double compactIconButton = 24;
  static const double compactIcon = 13;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double tooltipMinHeight = 30;
  static const double previewMinWidth = 320;
  static const double modalMaxWidth = 860;
  static const double modalHorizontalInset = 40;
  static const double modalVerticalInset = 24;
  static const double modalMaxHeightFraction = 0.86;
  static const double dialog = 520;
  static const double dialogNarrow = 480;
  static const double dialogCompact = 460;
  static const double dialogWide = 560;
  static const double popupMenuMinWidth = 180;
  static const double editorContextMenuWidth = 260;
  static const double languagePopupMinWidth = 220;
  static const double languagePopupMaxWidth = 280;
  static const double languageButtonMaxWidth = 256;
  static const double aboutLogoViewport = 136;
  static const double aboutLogoAsset = 216;
  static const double sidebarSeparatorHeight = 22;
  // The surrounding hairline insets bring tree rows to the same outer height
  // as sidebar header controls.
  static const double sidebarTreeRowHeight =
      iconButton - BusyApiStroke.hairline * 2;
  static const double sidebarTreeDepthBase = 4;
  static const double sidebarTreeDepthIndent = 14;
  static const double sidebarTreeControl = 18;
  static const double sidebarTreeArrow = 14;
  static const double problemsListWidth = 700;
  static const double problemsListHeight = 420;
  // BusyMark SourceAutocompletePopup's bounded viewport.
  static const double sourceAutocompleteMaxHeight = 280;
  static const double sourceGutterWidth = 50;
  static const double sourceFoldButton = 16;
  static const double sourceFoldButtonRightInset = 1;
  static const double documentHeadingTop = 18;
  static const double documentHeadingBottom = 6;
  static const double documentListMarkerWidth = 28;
  static const double documentListMarkerTopInset = 0;
  static const double documentListIndent =
      documentListMarkerWidth + BusyApiSpacing.sm;
  static const double documentImageMinWidth = 80;
  static const double documentImageMaxWidth = documentContentWidth;
  static const double documentImageMinHeight = iconButton;
  static const double previewInlineImageMaxHeight = 180;
  static const double previewInlineImageHeight = 96;
  static const double wysiwygToolbarReserve =
      iconButton + BusyApiSpacing.xs * 2;
  static const double wysiwygToolbarClearance =
      BusyApiSpacing.sm + wysiwygToolbarReserve + BusyApiSpacing.sm;
  static const double wysiwygPrefixWidth = 30;
  static const double tableDialogWidth = 360;
  static const double tablePickerHeight = 224;
  static const double tableMinWidth = 360;
  static const double markerDot = 6;
  static const double listMarkerTopInset = 7;
  static const double thematicBreakHandleWidth = 44;
  static const double controlRowWidth = 256;
  static const double sliderRowWidth = 260;
  static const double toolbarPlacementRowWidth = 430;
  static const double settingsControlBreakpoint = 560;
  static const double toolbarPlacementBreakpoint = 620;
  static const int tableMinColumns = 1;
  static const int tableMaxColumns = 12;
  static const int tableMinRows = 1;
  static const int tableMaxRows = 50;
}

abstract final class BusyApiFormLayout {
  static const double comboInlineMaxFraction = 0.46;
}

abstract final class BusyApiElevation {
  static const double none = 0;
  static const double surface = 2;
}

abstract final class BusyApiStroke {
  static const double hairline = 1;
  static const double tableGrid = 0.5;
  static const double focus = kYaruFocusBorderWidth;
  static const double sourceCursor = 1.4;
  static const double thematicBreak = 1.6;
}

abstract final class BusyApiAlpha {
  static const double groupedRowLightHoverStrength = 0.50;
  static const double tooltipBackground = 0.80;
  static const double tooltipBorder = 0.10;
  static const double textSelection = 0.32;
  static const double sourceCollapsedLine = 0.045;
  static const double sourceCursor = 0.82;
  static const double sourceSyntaxBackground = 0.10;
  static const double syntaxCommentDark = 0.82;
  static const double syntaxCommentLight = 0.76;
  static const double previewHighlight = 0.24;
  static const double thematicBreak = 0.34;
  static const double thematicBreakHandle = 0.24;
  static const double thematicBreakSelected = 0.72;
}

/// Native libadwaita/Yaru shadow layers shared by grouped card surfaces.
abstract final class BusyApiShadow {
  static List<BoxShadow> nativeCardShadows(Color semanticShadow) {
    Color layer(double opacity) {
      return semanticShadow.withValues(alpha: semanticShadow.a * opacity);
    }

    // ShapeDecoration paints later shadows over earlier ones. Keep the
    // perimeter last so the compact native edge remains above the broad layer.
    return [
      BoxShadow(
        color: layer(0.03),
        blurRadius: 6,
        spreadRadius: 2,
        offset: const Offset(0, 2),
      ),
      BoxShadow(
        color: layer(0.07),
        blurRadius: 3,
        spreadRadius: 1,
        offset: const Offset(0, 1),
      ),
      BoxShadow(color: layer(0.03), spreadRadius: 1),
    ];
  }

  static List<BoxShadow> nativeCardShadowsFor(BuildContext context) {
    final theme = Theme.of(context);
    return nativeCardShadows(
      CardTheme.of(context).shadowColor ?? theme.colorScheme.shadow,
    );
  }
}

abstract final class BusyApiTypography {
  static const String fontFamily = 'Ubuntu';
  static const String monoFontFamily = 'Ubuntu Mono';
  static const List<String> fontFamilyFallback = [
    'Noto Sans Arabic',
    'Noto Sans',
    'DejaVu Sans',
  ];
  static const List<String> monoFontFamilyFallback = [
    'Noto Sans Arabic',
    'Noto Sans Mono',
    'DejaVu Sans Mono',
    'DejaVu Sans',
  ];
  static const double codeLineHeight = 1.45;
  static const double sourceEditorLineHeight = 1.6;
  static const double bodyLineHeight = 1.5;
  static const double defaultFontSize = 14;
  static const double tooltipFontSize = defaultFontSize;
  static const double sourceCursorHeightScale = 1.34;
  static const double sourceLineNumberScale = 0.92;
  static const double hiddenLayoutFontSize = 0.01;
  static const double hiddenLayoutHeight = 0.01;

  static double markdownHeadingScale(int level) {
    return switch (level) {
      1 => 1.55,
      2 => 1.36,
      3 => 1.22,
      4 => 1.10,
      5 => 1.08,
      _ => 1.06,
    };
  }

  static double markdownHeadingLineHeight(int level) {
    return switch (level) {
      1 => 1.20,
      2 => 1.23,
      3 => 1.28,
      4 => 1.37,
      5 => 1.39,
      _ => 1.42,
    };
  }
}

/// Keeps a known left-to-right value stable inside surrounding RTL text.
String busyApiLtrIsolate(Object value) => '\u2066$value\u2069';

/// Isolates a machine value only when the surrounding interface is RTL.
String busyApiLtrIsolateFor(BuildContext context, Object value) {
  return Directionality.maybeOf(context) == TextDirection.rtl
      ? busyApiLtrIsolate(value)
      : value.toString();
}

/// Lets the first strong character choose direction without affecting neighbors.
String busyApiBidiIsolate(Object value) => '\u2068$value\u2069';

/// Applies first-strong isolation only inside an RTL interface.
String busyApiBidiIsolateFor(BuildContext context, Object value) {
  return Directionality.maybeOf(context) == TextDirection.rtl
      ? busyApiBidiIsolate(value)
      : value.toString();
}

abstract final class BusyApiMotion {
  static const Duration fast = Duration(milliseconds: 100);
  static const Duration sidebar = Duration(milliseconds: 200);
  static const Duration search = Duration(milliseconds: 160);
  static const Duration crossfade = Duration(milliseconds: 140);
  static const Curve presentationCurve = Curves.easeOutCubic;
  static const Duration dialogInsets = Duration(milliseconds: 160);
  static const Duration bannerReveal = Duration(milliseconds: 250);
  static const Duration sidebarExpand = Duration(milliseconds: 120);
  static const Duration scroll = Duration(milliseconds: 180);
  static const Duration previewSearchDelay = Duration(milliseconds: 80);
  static const Duration tooltipWait = Duration(milliseconds: 450);
  static const Curve dialogInsetsCurve = Curves.easeOutCubic;
  static const Curve bannerRevealCurve = Curves.easeOutCubic;
}

abstract final class BusyApiInsets {
  static const input = EdgeInsets.symmetric(
    horizontal: BusyApiSpacing.md,
    vertical: BusyApiSpacing.smPlus,
  );
  static const listTile = EdgeInsets.symmetric(horizontal: BusyApiSpacing.md);
  static const settingsPage = EdgeInsets.fromLTRB(
    BusyApiSpacing.xl,
    BusyApiSpacing.mdPlus,
    BusyApiSpacing.xl,
    BusyApiSpacing.xxl,
  );
  static const welcomePage = EdgeInsets.fromLTRB(
    BusyApiSpacing.xl,
    BusyApiSpacing.lgPlus,
    BusyApiSpacing.xl,
    BusyApiSpacing.xxl,
  );
  static const sidebarTabs = EdgeInsets.fromLTRB(
    BusyApiSpacing.smPlus,
    0,
    BusyApiSpacing.smPlus,
    BusyApiSpacing.sm,
  );
  static const sidebarHeader = EdgeInsetsDirectional.fromSTEB(
    BusyApiSpacing.mdPlus,
    BusyApiSpacing.mdPlus,
    BusyApiSpacing.sm,
    BusyApiSpacing.sm - BusyApiSpacing.xxs,
  );
  static const sidebarList = EdgeInsets.fromLTRB(
    BusyApiSpacing.sm,
    BusyApiSpacing.xxs,
    BusyApiSpacing.sm,
    BusyApiSpacing.smPlus,
  );
  static const tocHeader = EdgeInsetsDirectional.fromSTEB(
    0,
    0,
    0,
    BusyApiSpacing.sm,
  );
  static const documentCodeBlock = EdgeInsets.symmetric(
    vertical: BusyApiSpacing.sm,
  );
  static const documentCodeContent = EdgeInsets.all(BusyApiSpacing.mdPlus);
  static const documentCalloutBlock = EdgeInsets.symmetric(
    vertical: BusyApiSpacing.sm,
  );
  static const documentCalloutContent = EdgeInsets.all(BusyApiSpacing.md);
  static const documentTableCell = EdgeInsets.all(BusyApiSpacing.smPlus);
  static const sectionLabel = EdgeInsets.fromLTRB(
    BusyApiSpacing.md,
    BusyApiSpacing.mdPlus,
    BusyApiSpacing.md,
    6,
  );
  static const documentHeadingBlock = EdgeInsets.only(
    top: BusyApiSizes.documentHeadingTop,
    bottom: BusyApiSizes.documentHeadingBottom,
  );
  static const documentParagraphBlock = EdgeInsets.symmetric(
    vertical: BusyApiSizes.documentHeadingBottom,
  );
  static const documentImageBlock = EdgeInsets.symmetric(
    vertical: BusyApiSpacing.smPlus,
  );
  static const documentThematicBreakBlock = EdgeInsets.symmetric(
    vertical: BusyApiSpacing.mdPlus,
  );
  static const wysiwygContainerBlock = documentCalloutBlock;
  static const wysiwygTableBlock = EdgeInsets.symmetric(
    vertical: BusyApiSpacing.md,
  );
  static const wysiwygDefaultBlock = EdgeInsets.symmetric(
    vertical: BusyApiSpacing.xs,
  );
  static const wysiwygContainerContent = documentCalloutContent;
  static const sourceEditor = EdgeInsets.fromLTRB(
    BusyApiSourceEditorMetrics.paddingLeft,
    BusyApiSourceEditorMetrics.paddingTop,
    BusyApiSourceEditorMetrics.paddingRight,
    BusyApiSourceEditorMetrics.paddingBottom,
  );
  static const searchResultRow = EdgeInsets.symmetric(
    horizontal: BusyApiSpacing.lg,
    vertical: BusyApiSpacing.sm,
  );
}

abstract final class BusyApiSourceEditorMetrics {
  static const double paddingTop = BusyApiSpacing.lg;
  static const double paddingBottom = BusyApiSpacing.lg;
  static const double paddingLeft = BusyApiSpacing.md;
  static const double paddingRight = BusyApiSpacing.lg;
}

abstract final class BusyApiLinuxPalette {
  static Color fromArgb(int value) => Color(value);

  static const transparent = Color(0x00000000);
  static const white = Color(0xFFFFFFFF);
  static const blueAccent = Color(0xFF3584E4);
  static const ubuntuBlueAccent = Color(0xFF0073E5);
  static const ubuntuTealAccent = Color(0xFF2190A4);
  static const ubuntuGreenAccent = Color(0xFF3A944A);
  static const ubuntuYellowAccent = Color(0xFFC88800);
  static const ubuntuOrangeAccent = Color(0xFFED5B00);
  static const ubuntuRedAccent = Color(0xFFDA3450);
  static const ubuntuPinkAccent = Color(0xFFD56199);
  static const ubuntuPurpleAccent = Color(0xFF7764D8);
  static const ubuntuSlateAccent = Color(0xFF6F8396);
  static const ubuntuBrownAccent = Color(0xFF986A44);
  static const ubuntuMagentaAccent = Color(0xFFB34CB3);
  static const ubuntuOliveAccent = Color(0xFF4B8501);
  static const ubuntuPrussianGreenAccent = Color(0xFF308280);
  static const ubuntuSageAccent = Color(0xFF657B69);
  static const ubuntuWartyBrownAccent = Color(0xFFB39169);
  static const destructiveForegroundLight = Color(0xFFC30000);
  static const destructiveForegroundDark = Color(0xFFFF938C);
  static const red = Color(0xFFC01C28);
  static const yellow = Color(0xFFE5A50A);
  static const green = Color(0xFF2EC27E);
  static const light2 = Color(0xFFF6F5F4);
  static const light4 = Color(0xFFC0BFBC);
  static const dark4 = Color(0xFF242424);
  static const black = Color(0xFF000000);
}

/// Cross-toolkit tooltip visuals.
///
/// Flutter and the native GTK header bar render their own tooltip widgets.
/// Keeping the palette and shape here lets each toolkit retain its native
/// layout, positioning, focus, and motion while presenting the same surface.
abstract final class BusyApiTooltipStyle {
  static final Color background = BusyApiLinuxPalette.black.withValues(
    alpha: BusyApiAlpha.tooltipBackground,
  );
  static const Color foreground = BusyApiLinuxPalette.white;
  static final Color border = BusyApiLinuxPalette.white.withValues(
    alpha: BusyApiAlpha.tooltipBorder,
  );
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: BusyApiSpacing.tooltipHorizontal,
    vertical: BusyApiSpacing.tooltipVertical,
  );
  static const BorderRadius borderRadius = BorderRadius.all(
    Radius.circular(BusyApiRadius.tooltip),
  );
  static const BoxConstraints constraints = BoxConstraints(
    minHeight: BusyApiSizes.tooltipMinHeight,
  );
}

/// Filled destructive actions use Yaru's dark red button treatment.
///
/// The dark theme's generic error role is intentionally a light tint with
/// black content, which is appropriate for error text but not for destructive
/// push buttons.
abstract final class BusyApiDestructiveButtonStyle {
  static Color background(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? BusyApiLinuxPalette.red
      : theme.colorScheme.error;

  static Color foreground(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? BusyApiLinuxPalette.white
      : theme.colorScheme.onError;
}

@immutable
class BusyApiSyntaxColors extends ThemeExtension<BusyApiSyntaxColors> {
  const BusyApiSyntaxColors({
    required this.heading,
    required this.keyword,
    required this.tag,
    required this.attribute,
    required this.string,
    required this.literal,
    required this.link,
    required this.comment,
    required this.punctuation,
  });

  factory BusyApiSyntaxColors.fromSurfaceColors(
    Brightness brightness,
    BusyApiSurfaceColors colors,
  ) {
    final dark = brightness == Brightness.dark;
    return BusyApiSyntaxColors(
      heading: dark ? _darkHeading : _lightHeading,
      keyword: dark ? _darkKeyword : _lightKeyword,
      tag: dark ? _darkTag : _lightTag,
      attribute: dark ? _darkAttribute : _lightAttribute,
      string: dark ? _darkString : _lightString,
      literal: dark ? _darkLiteral : _lightLiteral,
      link: dark ? _darkLink : _lightLink,
      comment: colors.mutedForeground.withValues(
        alpha: dark
            ? BusyApiAlpha.syntaxCommentDark
            : BusyApiAlpha.syntaxCommentLight,
      ),
      punctuation: colors.mutedForeground,
    );
  }

  static BusyApiSyntaxColors of(BuildContext context) {
    return Theme.of(context).extension<BusyApiSyntaxColors>() ??
        BusyApiSyntaxColors.fromSurfaceColors(
          Theme.of(context).brightness,
          BusyApiSurfaceColors.of(context),
        );
  }

  static const _darkHeading = Color(0xFF99C1F1);
  static const _lightHeading = Color(0xFF1A5FB4);
  static const _darkKeyword = Color(0xFFFFBE6F);
  static const _lightKeyword = Color(0xFF9C6B00);
  static const _darkTag = Color(0xFF8FF0A4);
  static const _lightTag = Color(0xFF2A7B43);
  static const _darkAttribute = Color(0xFFF9F06B);
  static const _lightAttribute = Color(0xFF865E00);
  static const _darkString = Color(0xFFF66151);
  static const _lightString = Color(0xFFC01C28);
  static const _darkLiteral = Color(0xFFDC8ADD);
  static const _lightLiteral = Color(0xFF813D9C);
  static const _darkLink = Color(0xFF62A0EA);
  static const _lightLink = Color(0xFF1C71D8);

  final Color heading;
  final Color keyword;
  final Color tag;
  final Color attribute;
  final Color string;
  final Color literal;
  final Color link;
  final Color comment;
  final Color punctuation;

  @override
  BusyApiSyntaxColors copyWith({
    Color? heading,
    Color? keyword,
    Color? tag,
    Color? attribute,
    Color? string,
    Color? literal,
    Color? link,
    Color? comment,
    Color? punctuation,
  }) {
    return BusyApiSyntaxColors(
      heading: heading ?? this.heading,
      keyword: keyword ?? this.keyword,
      tag: tag ?? this.tag,
      attribute: attribute ?? this.attribute,
      string: string ?? this.string,
      literal: literal ?? this.literal,
      link: link ?? this.link,
      comment: comment ?? this.comment,
      punctuation: punctuation ?? this.punctuation,
    );
  }

  @override
  BusyApiSyntaxColors lerp(covariant BusyApiSyntaxColors? other, double t) {
    if (other == null) {
      return this;
    }
    return BusyApiSyntaxColors(
      heading: Color.lerp(heading, other.heading, t)!,
      keyword: Color.lerp(keyword, other.keyword, t)!,
      tag: Color.lerp(tag, other.tag, t)!,
      attribute: Color.lerp(attribute, other.attribute, t)!,
      string: Color.lerp(string, other.string, t)!,
      literal: Color.lerp(literal, other.literal, t)!,
      link: Color.lerp(link, other.link, t)!,
      comment: Color.lerp(comment, other.comment, t)!,
      punctuation: Color.lerp(punctuation, other.punctuation, t)!,
    );
  }
}

enum BusyApiVcsFileColor {
  modified,
  added,
  deleted,
  untracked,
  conflicted,
  copied,
  renamed,
}

Color busyApiDestructiveForeground(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? BusyApiLinuxPalette.destructiveForegroundDark
      : BusyApiLinuxPalette.destructiveForegroundLight;
}

Color busyApiVcsFileStatusColor(
  BuildContext context,
  BusyApiVcsFileColor status,
) {
  final brightness = Theme.of(context).brightness;
  final dark = brightness == Brightness.dark;
  return switch (status) {
    BusyApiVcsFileColor.modified =>
      dark ? const Color(0xFF99C1F1) : BusyApiLinuxPalette.ubuntuBlueAccent,
    BusyApiVcsFileColor.added =>
      dark ? const Color(0xFF8FF0A4) : BusyApiLinuxPalette.ubuntuGreenAccent,
    BusyApiVcsFileColor.deleted =>
      dark ? const Color(0xFFFF7B63) : BusyApiLinuxPalette.red,
    BusyApiVcsFileColor.untracked =>
      dark ? const Color(0xFFFFBE6F) : BusyApiLinuxPalette.ubuntuBrownAccent,
    BusyApiVcsFileColor.conflicted =>
      dark ? const Color(0xFFFF7B63) : BusyApiLinuxPalette.ubuntuRedAccent,
    BusyApiVcsFileColor.copied =>
      dark ? const Color(0xFF8FF0A4) : BusyApiLinuxPalette.ubuntuOliveAccent,
    BusyApiVcsFileColor.renamed =>
      dark ? const Color(0xFFDC8ADD) : BusyApiLinuxPalette.ubuntuPurpleAccent,
  };
}

BusyApiSurfaceColors _busyApiSemanticSurfaceColors(Brightness brightness) {
  final window = switch (brightness) {
    Brightness.light => const Color(0xFFFAFAFA),
    Brightness.dark => const Color(0xFF2C2C2C),
  };
  final view = switch (brightness) {
    Brightness.light => const Color(0xFFFFFFFF),
    Brightness.dark => const Color(0xFF272727),
  };
  final floatingSurface = switch (brightness) {
    // Installed Yaru/libadwaita owns this neutral role independently from the
    // window and content-view elevation ladder.
    Brightness.light => const Color(0xFFFAFAFA),
    Brightness.dark => const Color(0xFF3E3E3E),
  };
  final foreground = switch (brightness) {
    Brightness.light => const Color(0xFF3D3D3D),
    Brightness.dark => const Color(0xFFF7F7F7),
  };
  // These colors are used by non-disabled 10–14 px labels. Keep them opaque so
  // their contrast is stable across every neutral surface instead of stacking
  // a dim-label alpha on whichever view happens to be underneath.
  final mutedForeground = switch (brightness) {
    Brightness.light => const Color(0xFF666666),
    Brightness.dark => const Color(0xFFB5B5B5),
  };
  final card = switch (brightness) {
    Brightness.light => const Color(0xFFFFFFFF),
    Brightness.dark => const Color(0xFF3D3D3D),
  };
  final groupedSurface = switch (brightness) {
    Brightness.light => const Color(0xFFFFFFFF),
    Brightness.dark => const Color.fromRGBO(255, 255, 255, 0.08),
  };
  // Yaru renders the split-view boundary as a recessed divider in both
  // brightness modes. A foreground tint in dark mode produces a light seam.
  final sidebarBorder = switch (brightness) {
    Brightness.light => const Color.fromRGBO(24, 24, 24, 0.08),
    Brightness.dark => const Color.fromRGBO(16, 16, 16, 0.35),
  };

  Color tintedSurface(Color tint) {
    final alpha = brightness == Brightness.dark ? 0.16 : 0.08;
    return Color.alphaBlend(tint.withValues(alpha: alpha), card);
  }

  return switch (brightness) {
    Brightness.light => BusyApiSurfaceColors(
      // Modern Yaru/libadwaita semantic roles. Flutter's Yaru theme exposes
      // geometry and interaction behavior, but not every contemporary
      // surface role, so these neutral fallbacks live in one resolver.
      window: window,
      view: view,
      sidebar: const Color(0xFFEBEBEB),
      secondarySidebar: const Color(0xFFF0F0F0),
      headerbar: const Color(0xFFFAFAFA),
      headerbarFlat: const Color(0xFFFFFFFF),
      panel: const Color(0xFFF0F0F0),
      card: card,
      groupedSurface: groupedSurface,
      dialog: floatingSurface,
      popover: floatingSurface,
      control: const Color.fromRGBO(0, 0, 0, 0.10),
      controlHover: const Color.fromRGBO(0, 0, 0, 0.14),
      controlActive: const Color.fromRGBO(0, 0, 0, 0.18),
      foreground: foreground,
      mutedForeground: mutedForeground,
      disabledForeground: foreground.withValues(alpha: 0.38),
      disabledControl: const Color.fromRGBO(0, 0, 0, 0.04),
      border: const Color.fromRGBO(0, 0, 0, 0.18),
      subtleBorder: const Color.fromRGBO(0, 0, 0, 0.10),
      divider: const Color.fromRGBO(0, 0, 0, 0.10),
      cardShade: const Color.fromRGBO(24, 24, 24, 0.08),
      // Dialogs use libadwaita's restrained inside highlight. This is
      // intentionally distinct from the darker popover perimeter.
      dialogOutline: const Color.fromRGBO(255, 255, 255, 0.07),
      floatingBorder: const Color.fromRGBO(0, 0, 0, 0.14),
      sidebarBorder: sidebarBorder,
      shade: const Color.fromRGBO(0, 0, 0, 0.07),
      muted: mutedForeground,
      admonitionNote: tintedSurface(BusyApiLinuxPalette.ubuntuBlueAccent),
      admonitionTip: tintedSurface(BusyApiLinuxPalette.ubuntuGreenAccent),
      admonitionWarning: tintedSurface(BusyApiLinuxPalette.ubuntuYellowAccent),
    ),
    Brightness.dark => BusyApiSurfaceColors(
      window: window,
      view: view,
      sidebar: const Color(0xFF393939),
      secondarySidebar: const Color(0xFF323232),
      headerbar: const Color(0xFF393939),
      headerbarFlat: const Color(0xFF272727),
      panel: const Color(0xFF323232),
      card: card,
      groupedSurface: groupedSurface,
      dialog: floatingSurface,
      popover: floatingSurface,
      control: const Color.fromRGBO(255, 255, 255, 0.10),
      controlHover: const Color.fromRGBO(255, 255, 255, 0.14),
      controlActive: const Color.fromRGBO(255, 255, 255, 0.18),
      foreground: foreground,
      mutedForeground: mutedForeground,
      disabledForeground: foreground.withValues(alpha: 0.38),
      disabledControl: const Color.fromRGBO(255, 255, 255, 0.06),
      border: const Color.fromRGBO(0, 0, 0, 0.75),
      subtleBorder: const Color.fromRGBO(255, 255, 255, 0.10),
      divider: const Color.fromRGBO(255, 255, 255, 0.10),
      cardShade: const Color.fromRGBO(0, 0, 0, 0.36),
      dialogOutline: const Color.fromRGBO(255, 255, 255, 0.07),
      floatingBorder: const Color.fromRGBO(0, 0, 0, 0.14),
      sidebarBorder: sidebarBorder,
      shade: const Color.fromRGBO(0, 0, 0, 0.25),
      muted: mutedForeground,
      admonitionNote: tintedSurface(BusyApiLinuxPalette.ubuntuBlueAccent),
      admonitionTip: tintedSurface(BusyApiLinuxPalette.ubuntuGreenAccent),
      admonitionWarning: tintedSurface(BusyApiLinuxPalette.ubuntuYellowAccent),
    ),
  };
}

@immutable
class BusyApiSurfaceColors extends ThemeExtension<BusyApiSurfaceColors> {
  const BusyApiSurfaceColors({
    required this.window,
    required this.view,
    required this.sidebar,
    required this.secondarySidebar,
    required this.headerbar,
    required this.headerbarFlat,
    required this.panel,
    required this.card,
    required this.groupedSurface,
    required this.dialog,
    required this.popover,
    required this.control,
    required this.controlHover,
    required this.controlActive,
    required this.foreground,
    required this.mutedForeground,
    required this.disabledForeground,
    required this.disabledControl,
    required this.border,
    required this.subtleBorder,
    required this.divider,
    required this.cardShade,
    required this.dialogOutline,
    required this.floatingBorder,
    required this.sidebarBorder,
    required this.shade,
    required this.muted,
    required this.admonitionNote,
    required this.admonitionTip,
    required this.admonitionWarning,
  });

  factory BusyApiSurfaceColors.fromTheme(ThemeData theme) {
    return _busyApiSemanticSurfaceColors(theme.brightness);
  }

  static BusyApiSurfaceColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<BusyApiSurfaceColors>() ??
        BusyApiSurfaceColors.fromTheme(theme);
  }

  final Color window;
  final Color view;
  final Color sidebar;
  final Color secondarySidebar;
  final Color headerbar;
  final Color headerbarFlat;
  final Color panel;
  final Color card;
  final Color groupedSurface;
  final Color dialog;
  final Color popover;
  final Color control;
  final Color controlHover;
  final Color controlActive;
  final Color foreground;
  final Color mutedForeground;
  final Color disabledForeground;
  final Color disabledControl;
  final Color border;
  final Color subtleBorder;
  final Color divider;
  final Color cardShade;
  final Color dialogOutline;
  final Color floatingBorder;
  final Color sidebarBorder;
  final Color shade;
  final Color muted;
  final Color admonitionNote;
  final Color admonitionTip;
  final Color admonitionWarning;

  @override
  BusyApiSurfaceColors copyWith({
    Color? window,
    Color? view,
    Color? sidebar,
    Color? secondarySidebar,
    Color? headerbar,
    Color? headerbarFlat,
    Color? panel,
    Color? card,
    Color? groupedSurface,
    Color? dialog,
    Color? popover,
    Color? control,
    Color? controlHover,
    Color? controlActive,
    Color? foreground,
    Color? mutedForeground,
    Color? disabledForeground,
    Color? disabledControl,
    Color? border,
    Color? subtleBorder,
    Color? divider,
    Color? cardShade,
    Color? dialogOutline,
    Color? floatingBorder,
    Color? sidebarBorder,
    Color? shade,
    Color? muted,
    Color? admonitionNote,
    Color? admonitionTip,
    Color? admonitionWarning,
  }) {
    return BusyApiSurfaceColors(
      window: window ?? this.window,
      view: view ?? this.view,
      sidebar: sidebar ?? this.sidebar,
      secondarySidebar: secondarySidebar ?? this.secondarySidebar,
      headerbar: headerbar ?? this.headerbar,
      headerbarFlat: headerbarFlat ?? this.headerbarFlat,
      panel: panel ?? this.panel,
      card: card ?? this.card,
      groupedSurface: groupedSurface ?? this.groupedSurface,
      dialog: dialog ?? this.dialog,
      popover: popover ?? this.popover,
      control: control ?? this.control,
      controlHover: controlHover ?? this.controlHover,
      controlActive: controlActive ?? this.controlActive,
      foreground: foreground ?? this.foreground,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      disabledForeground: disabledForeground ?? this.disabledForeground,
      disabledControl: disabledControl ?? this.disabledControl,
      border: border ?? this.border,
      subtleBorder: subtleBorder ?? this.subtleBorder,
      divider: divider ?? this.divider,
      cardShade: cardShade ?? this.cardShade,
      dialogOutline: dialogOutline ?? this.dialogOutline,
      floatingBorder: floatingBorder ?? this.floatingBorder,
      sidebarBorder: sidebarBorder ?? this.sidebarBorder,
      shade: shade ?? this.shade,
      muted: muted ?? this.muted,
      admonitionNote: admonitionNote ?? this.admonitionNote,
      admonitionTip: admonitionTip ?? this.admonitionTip,
      admonitionWarning: admonitionWarning ?? this.admonitionWarning,
    );
  }

  @override
  BusyApiSurfaceColors lerp(covariant BusyApiSurfaceColors? other, double t) {
    if (other == null) {
      return this;
    }
    return BusyApiSurfaceColors(
      window: Color.lerp(window, other.window, t)!,
      view: Color.lerp(view, other.view, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      secondarySidebar: Color.lerp(
        secondarySidebar,
        other.secondarySidebar,
        t,
      )!,
      headerbar: Color.lerp(headerbar, other.headerbar, t)!,
      headerbarFlat: Color.lerp(headerbarFlat, other.headerbarFlat, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      card: Color.lerp(card, other.card, t)!,
      groupedSurface: Color.lerp(groupedSurface, other.groupedSurface, t)!,
      dialog: Color.lerp(dialog, other.dialog, t)!,
      popover: Color.lerp(popover, other.popover, t)!,
      control: Color.lerp(control, other.control, t)!,
      controlHover: Color.lerp(controlHover, other.controlHover, t)!,
      controlActive: Color.lerp(controlActive, other.controlActive, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      disabledForeground: Color.lerp(
        disabledForeground,
        other.disabledForeground,
        t,
      )!,
      disabledControl: Color.lerp(disabledControl, other.disabledControl, t)!,
      border: Color.lerp(border, other.border, t)!,
      subtleBorder: Color.lerp(subtleBorder, other.subtleBorder, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      cardShade: Color.lerp(cardShade, other.cardShade, t)!,
      dialogOutline: Color.lerp(dialogOutline, other.dialogOutline, t)!,
      floatingBorder: Color.lerp(floatingBorder, other.floatingBorder, t)!,
      sidebarBorder: Color.lerp(sidebarBorder, other.sidebarBorder, t)!,
      shade: Color.lerp(shade, other.shade, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      admonitionNote: Color.lerp(admonitionNote, other.admonitionNote, t)!,
      admonitionTip: Color.lerp(admonitionTip, other.admonitionTip, t)!,
      admonitionWarning: Color.lerp(
        admonitionWarning,
        other.admonitionWarning,
        t,
      )!,
    );
  }
}

ButtonStyle busyApiHeaderIconButtonStyle({
  Color? foregroundColor,
  Color? disabledForegroundColor,
  WidgetStateProperty<Color?>? backgroundColor,
  WidgetStateProperty<Color?>? overlayColor,
  double borderRadius = BusyApiRadius.headerButton,
}) {
  return ButtonStyle(
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    foregroundColor: foregroundColor == null
        ? null
        : WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled) &&
                disabledForegroundColor != null) {
              return disabledForegroundColor;
            }
            return foregroundColor;
          }),
    backgroundColor: backgroundColor,
    overlayColor: overlayColor,
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(borderRadius)),
    ),
  );
}

WidgetStateProperty<Color?> busyApiHeaderButtonBackground(
  BuildContext context,
) {
  return Theme.of(context).filledButtonTheme.style?.backgroundColor ??
      WidgetStatePropertyAll(BusyApiSurfaceColors.of(context).control);
}

/// Resolves a contained control state against its semantic host surface.
///
/// Yaru control fills are translucent state layers, which is appropriate when
/// a parent control surface owns the background. Free-floating controls, such
/// as the editing toolbar over a document, have no such parent and must resolve
/// that layer once so document content cannot show through the button.
WidgetStateProperty<Color?> busyApiContainedControlBackground(
  BuildContext context, {
  required Color surface,
}) {
  final background = busyApiHeaderButtonBackground(context);
  return WidgetStateProperty.resolveWith((states) {
    final stateColor = background.resolve(states);
    return stateColor == null ? null : Color.alphaBlend(stateColor, surface);
  });
}

WidgetStateProperty<Color?> busyApiTransparentHeaderButtonBackground(
  BuildContext _,
) {
  return const WidgetStatePropertyAll(BusyApiLinuxPalette.transparent);
}

Color busyApiSelectedBackground(BuildContext context) {
  return BusyApiSurfaceColors.of(context).controlActive;
}

Color busyApiRowHoverColor(BuildContext context) {
  final theme = Theme.of(context);
  final hover = theme.hoverColor;
  if (theme.colorScheme.isHighContrast ||
      theme.colorScheme.brightness == Brightness.dark) {
    return hover;
  }
  return hover.withValues(
    alpha: hover.a * BusyApiAlpha.groupedRowLightHoverStrength,
  );
}

TextStyle? busyApiSectionHeaderStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodyMedium?.copyWith(
    color: BusyApiSurfaceColors.of(context).foreground,
    fontWeight: FontWeight.w700,
  );
}

Widget _busyApiGroupedRowSubtitle(
  BuildContext context,
  Widget child, {
  bool enabled = true,
}) {
  final colors = BusyApiSurfaceColors.of(context);
  return DefaultTextStyle.merge(
    style: TextStyle(
      color: enabled ? colors.mutedForeground : colors.disabledForeground,
    ),
    child: child,
  );
}

class BusyApiHeaderControlStyleScope extends InheritedWidget {
  const BusyApiHeaderControlStyleScope({
    super.key,
    required this.foregroundColor,
    required this.disabledForegroundColor,
    required this.backgroundColor,
    required this.overlayColor,
    required super.child,
  });

  final Color foregroundColor;
  final Color disabledForegroundColor;
  final WidgetStateProperty<Color?> backgroundColor;
  final WidgetStateProperty<Color?> overlayColor;

  static BusyApiHeaderControlStyleScope? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<BusyApiHeaderControlStyleScope>();

  @override
  bool updateShouldNotify(BusyApiHeaderControlStyleScope oldWidget) =>
      foregroundColor != oldWidget.foregroundColor ||
      disabledForegroundColor != oldWidget.disabledForegroundColor ||
      backgroundColor != oldWidget.backgroundColor ||
      overlayColor != oldWidget.overlayColor;
}

class BusyApiHeaderIconButton extends StatelessWidget {
  const BusyApiHeaderIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.nativeIcon,
    this.selected = false,
    this.accented = false,
    this.transparent = true,
    this.elevated = false,
    this.shortcut,
    this.foregroundColor,
    this.disabledForegroundColor,
    this.backgroundColor,
    this.overlayColor,
    this.borderRadius = BusyApiRadius.headerButton,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final BusyApiLinuxHeaderIcon? nativeIcon;
  final bool selected;
  final bool accented;
  final bool transparent;

  /// Uses the theme's physical button elevation without drawing a custom
  /// shadow surface around the control.
  final bool elevated;
  final String? shortcut;
  final Color? foregroundColor;
  final Color? disabledForegroundColor;
  final WidgetStateProperty<Color?>? backgroundColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final colors = BusyApiSurfaceColors.of(context);
    final inheritedStyle = accented
        ? null
        : BusyApiHeaderControlStyleScope.maybeOf(context);
    final semanticStyle = busyApiHeaderIconButtonStyle(
      foregroundColor:
          foregroundColor ??
          (accented ? colorScheme.onPrimary : inheritedStyle?.foregroundColor),
      disabledForegroundColor:
          disabledForegroundColor ??
          inheritedStyle?.disabledForegroundColor ??
          colors.disabledForeground,
      backgroundColor:
          backgroundColor ??
          (accented
              ? WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return colors.disabledControl;
                  }
                  return colorScheme.primary;
                })
              : inheritedStyle?.backgroundColor ??
                    (elevated || !transparent
                        ? busyApiHeaderButtonBackground(context)
                        : null)),
      overlayColor: overlayColor ?? inheritedStyle?.overlayColor,
      borderRadius: borderRadius,
    );
    final style = elevated
        ? semanticStyle.copyWith(
            elevation: WidgetStatePropertyAll(
              theme.cardTheme.elevation ?? BusyApiElevation.surface,
            ),
            shadowColor: WidgetStatePropertyAll(colorScheme.shadow),
            surfaceTintColor: const WidgetStatePropertyAll(
              BusyApiLinuxPalette.transparent,
            ),
          )
        : semanticStyle;
    // YaruIconButton merges its defaults as the receiver, so non-null default
    // colors win over caller-supplied semantic colors. Compose the styles in
    // the opposite direction and give the result directly to IconButton.
    final yaruDefaults = YaruIconButton(
      icon: const SizedBox.shrink(),
      iconSize: BusyApiSizes.iconButton,
    ).defaultStyleOf(context);
    final button = IconButton(
      isSelected: selected,
      tooltip: shortcut == null ? tooltip : '$tooltip ($shortcut)',
      icon: BusyApiGtkHeaderIcon(icon, nativeIcon: nativeIcon),
      padding: EdgeInsets.zero,
      style: style.merge(yaruDefaults),
      onPressed: onPressed,
    );
    return YaruTheme.maybeOf(context)?.focusBorders == true
        ? YaruFocusBorder.primary(
            borderRadius: BorderRadius.circular(BusyApiRadius.pill),
            child: button,
          )
        : button;
  }
}

/// A compact icon action that keeps Yaru's interaction and focus behavior.
///
/// Compact controls are appropriate inside dense editor affordances, where a
/// full title-bar item would consume too much document space.
class BusyApiCompactIconButton extends StatelessWidget {
  const BusyApiCompactIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = BusyApiSizes.compactIconButton,
    this.glyphSize = BusyApiSizes.compactIcon,
    this.foregroundColor,
    this.focusNode,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double glyphSize;
  final Color? foregroundColor;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final semanticStyle = ButtonStyle(
      foregroundColor: foregroundColor == null
          ? null
          : WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.disabledForeground;
              }
              return foregroundColor;
            }),
    );
    final yaruDefaults = YaruIconButton(
      icon: const SizedBox.shrink(),
      iconSize: size,
    ).defaultStyleOf(context);
    final button = IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: glyphSize),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: semanticStyle.merge(yaruDefaults),
      focusNode: focusNode,
      onPressed: onPressed,
    );
    return YaruTheme.maybeOf(context)?.focusBorders == true
        ? YaruFocusBorder.primary(
            borderRadius: BorderRadius.circular(BusyApiRadius.pill),
            child: button,
          )
        : button;
  }
}

class BusyApiHeaderPopupMenuButton<T> extends StatefulWidget {
  const BusyApiHeaderPopupMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.itemBuilder,
    required this.onSelected,
    this.onCanceled,
    this.transparent = true,
    this.elevated = false,
    this.shortcut,
    this.foregroundColor,
    this.backgroundColor,
    this.borderRadius = BusyApiRadius.headerButton,
    this.highlightWhenOpen = true,
    this.nativeMenuService = const NativeMenuService(),
  });

  final String tooltip;
  final IconData icon;
  final FutureOr<List<PopupMenuEntry<T>>> Function(BuildContext context)
  itemBuilder;
  final ValueChanged<T> onSelected;
  final VoidCallback? onCanceled;
  final bool transparent;

  /// Uses the theme's physical button elevation.
  final bool elevated;
  final String? shortcut;
  final Color? foregroundColor;
  final WidgetStateProperty<Color?>? backgroundColor;
  final double borderRadius;
  final bool highlightWhenOpen;
  final NativeMenuService nativeMenuService;

  @override
  State<BusyApiHeaderPopupMenuButton<T>> createState() =>
      _BusyApiHeaderPopupMenuButtonState<T>();
}

class _BusyApiHeaderPopupMenuButtonState<T>
    extends State<BusyApiHeaderPopupMenuButton<T>> {
  final _triggerKey = GlobalKey();
  BusyApiMenuSession? _activeMenuSession;
  var _loading = false;
  var _open = false;

  @override
  void dispose() {
    final session = _activeMenuSession;
    _activeMenuSession = null;
    if (session != null) {
      unawaited(session.dismiss());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _triggerKey,
      child: Semantics(
        expanded: _open,
        child: BusyApiHeaderIconButton(
          tooltip: widget.tooltip,
          icon: widget.icon,
          shortcut: widget.shortcut,
          selected: widget.highlightWhenOpen && (_loading || _open),
          transparent: widget.transparent,
          elevated: widget.elevated,
          foregroundColor: widget.foregroundColor,
          backgroundColor: widget.backgroundColor,
          borderRadius: widget.borderRadius,
          onPressed: _loadAndShowMenu,
        ),
      ),
    );
  }

  Future<void> _loadAndShowMenu() async {
    if (_loading || _open) {
      return;
    }
    setState(() => _loading = true);
    // A menu response belongs to the context in which it was opened. A
    // rebuilt caller may now represent another buffer or element.
    final onSelected = widget.onSelected;
    final onCanceled = widget.onCanceled;
    try {
      final items = await widget.itemBuilder(context);
      if (!mounted || items.isEmpty) {
        return;
      }
      final triggerContext = _triggerKey.currentContext;
      if (triggerContext == null || !triggerContext.mounted) {
        return;
      }
      final session = BusyApiMenuSession();
      _activeMenuSession = session;
      setState(() => _open = true);
      T? selection;
      try {
        selection = await showBusyApiMenu<T>(
          context: triggerContext,
          anchorContext: triggerContext,
          items: List.unmodifiable(items),
          nativeMenuService: widget.nativeMenuService,
          session: session,
        );
      } finally {
        if (mounted && identical(_activeMenuSession, session)) {
          setState(() {
            _activeMenuSession = null;
            _open = false;
          });
        }
      }
      if (mounted && !session.dismissed) {
        if (selection != null) {
          onSelected(selection);
        } else {
          onCanceled?.call();
        }
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }
}

/// Owns one native or Flutter fallback menu presentation.
final class BusyApiMenuSession {
  BusyApiMenuSession() : _nativeSession = NativeMenuSession();

  final NativeMenuSession _nativeSession;
  final GlobalKey _fallbackRouteKey = GlobalKey();
  NativeMenuService _nativeMenuService = const NativeMenuService();
  Route<dynamic>? _fallbackRoute;
  var _started = false;
  var _dismissed = false;

  bool get dismissed => _dismissed;

  Future<void> dismiss() async {
    if (_dismissed) {
      return;
    }
    _dismissed = true;
    _removeFallbackRoute();
    await _nativeMenuService.dismiss(_nativeSession);
  }

  void _beginPresentation(NativeMenuService nativeMenuService) {
    if (_started) {
      throw StateError('A BusyApiMenuSession can present only one menu.');
    }
    _started = true;
    _nativeMenuService = nativeMenuService;
  }

  void _captureFallbackRoute() {
    final routeContext = _fallbackRouteKey.currentContext;
    final route = routeContext == null ? null : ModalRoute.of(routeContext);
    if (route == null) {
      return;
    }
    _fallbackRoute = route;
    if (_dismissed) {
      _removeFallbackRoute();
    }
  }

  void _releaseFallbackRoute() {
    _fallbackRoute = null;
  }

  void _removeFallbackRoute() {
    final route = _fallbackRoute;
    final navigator = route?.navigator;
    if (route != null && navigator != null && route.isActive) {
      navigator.removeRoute(route);
    }
    _fallbackRoute = null;
  }
}

/// Presents menus, including nested submenus, through the desktop toolkit.
/// A themed fallback is only used when no native host is available.
Future<T?> showBusyApiMenu<T>({
  required BuildContext context,
  required List<PopupMenuEntry<T>> items,
  BuildContext? anchorContext,
  Offset? anchorPoint,
  Rect? anchorRect,
  NativeMenuService nativeMenuService = const NativeMenuService(),
  BusyApiMenuSession? session,
  bool focusFirst = false,
  bool preferAbove = false,
  double? width,
}) async {
  assert(
    anchorRect == null || (anchorContext == null && anchorPoint == null),
    'anchorRect cannot be combined with anchorContext or anchorPoint.',
  );
  if (items.isEmpty) {
    return null;
  }
  final itemSnapshot = List<PopupMenuEntry<T>>.unmodifiable(items);
  final presentation = session ?? BusyApiMenuSession();
  if (presentation.dismissed) {
    return null;
  }
  presentation._beginPresentation(nativeMenuService);
  final anchor =
      anchorRect ??
      _busyApiMenuAnchorRect(anchorContext ?? context, anchorPoint);
  final nativeEntries = _busyApiNativeMenuEntries(itemSnapshot);
  if (nativeEntries != null) {
    final nativeResult = await nativeMenuService.show(
      session: presentation._nativeSession,
      anchor: anchor,
      entries: nativeEntries,
      focusFirst: focusFirst,
      preferAbove: preferAbove,
      textDirection: Directionality.of(context),
    );
    if (presentation.dismissed) {
      return null;
    }
    if (nativeResult.available) {
      return _busyApiMenuValueAt(itemSnapshot, nativeResult.selectedIndex);
    }
  }
  if (!context.mounted) {
    return null;
  }
  if (itemSnapshot.any((item) => item is BusyApiSubmenuItem<T>)) {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!navigator.mounted || navigator.overlay?.mounted != true) return null;
    final previousFocus = FocusManager.instance.primaryFocus;
    final overlay = navigator.overlay?.context.findRenderObject();
    final localAnchor = overlay is RenderBox
        ? Rect.fromPoints(
            overlay.globalToLocal(anchor.topLeft),
            overlay.globalToLocal(anchor.bottomRight),
          )
        : anchor;
    final route = _BusyApiNestedMenuRoute<T>(
      anchor: localAnchor,
      items: itemSnapshot,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      direction: Directionality.of(context),
      focusFirst: focusFirst,
      routeKey: presentation._fallbackRouteKey,
      dismissLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    );
    final result = navigator.push<T>(route);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => presentation._captureFallbackRoute(),
    );
    try {
      final value = await result;
      return presentation.dismissed ? null : value;
    } finally {
      presentation._releaseFallbackRoute();
      if (previousFocus?.context?.mounted == true) {
        previousFocus!.requestFocus();
      }
    }
  }
  final selection = await _showBusyApiFallbackMenu<T>(
    context: context,
    anchor: anchor,
    items: itemSnapshot,
    session: presentation,
    width: width,
  );
  return presentation.dismissed ? null : selection;
}

Rect _busyApiMenuAnchorRect(BuildContext anchorContext, Offset? anchorPoint) {
  if (anchorPoint != null) {
    return Rect.fromLTWH(anchorPoint.dx, anchorPoint.dy, 0, 0);
  }
  final renderObject = anchorContext.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return Rect.zero;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

List<NativeMenuEntry>? _busyApiNativeMenuEntries<T>(
  List<PopupMenuEntry<T>> items,
) {
  final entries = <NativeMenuEntry>[];
  for (final item in items) {
    if (item is BusyApiPopupMenuItem<T>) {
      entries.add(
        NativeMenuEntry.command(
          label: item.label,
          iconName: BusyApiGlyphs.nativeMenuIconName(item.icon),
          iconColorArgb: item.iconColor?.toARGB32(),
          shortcut: item.shortcut,
          gtkAccelerator: item.gtkAccelerator,
          enabled: item.enabled,
          checkable: item.trailingCheck,
          selected: item.trailingCheck && item.checked,
          mutuallyExclusive: item.mutuallyExclusive,
        ),
      );
    } else if (item is BusyApiSubmenuItem<T>) {
      final children = _busyApiNativeMenuEntries(item.items);
      if (children == null) return null;
      entries.add(
        NativeMenuEntry.submenu(
          label: item.label,
          enabled: item.enabled,
          children: children,
        ),
      );
    } else if (item is PopupMenuDivider) {
      entries.add(const NativeMenuEntry.separator());
    } else {
      return null;
    }
  }
  return entries;
}

T? _busyApiMenuValueAt<T>(List<PopupMenuEntry<T>> items, int? index) {
  if (index == null || index < 0) return null;
  // GTK and Dart use the same preorder, including headings and separators.
  // Only enabled leaves (with enabled ancestors) can return an action.
  var position = 0;
  T? visit(List<PopupMenuEntry<T>> entries, bool ancestorsEnabled) {
    for (final item in entries) {
      final current = position++;
      if (item is BusyApiSubmenuItem<T>) {
        final value = visit(item.items, ancestorsEnabled && item.enabled);
        if (value != null) return value;
      } else if (current == index &&
          ancestorsEnabled &&
          item is BusyApiPopupMenuItem<T> &&
          item.enabled) {
        return item.menuValue;
      }
    }
    return null;
  }

  return visit(items, true);
}

Future<T?> _showBusyApiFallbackMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required List<PopupMenuEntry<T>> items,
  required BusyApiMenuSession session,
  required double? width,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay?.context.findRenderObject();
  if (overlay is! RenderBox || !overlay.hasSize) {
    return null;
  }
  final localAnchor = Rect.fromPoints(
    overlay.globalToLocal(anchor.topLeft),
    overlay.globalToLocal(anchor.bottomRight),
  );
  final menuAnchor = Rect.fromLTWH(
    localAnchor.left,
    localAnchor.bottom,
    localAnchor.width,
    0,
  );
  final fallbackItems = _busyApiFallbackItems(items, session._fallbackRouteKey);
  final selection = showMenu<T>(
    context: context,
    useRootNavigator: true,
    position: RelativeRect.fromRect(menuAnchor, Offset.zero & overlay.size),
    items: fallbackItems,
    constraints: width == null ? null : BoxConstraints.tightFor(width: width),
    requestFocus: true,
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    session._captureFallbackRoute();
  });
  try {
    return await selection;
  } finally {
    session._releaseFallbackRoute();
  }
}

List<PopupMenuEntry<T>> _busyApiFallbackItems<T>(
  List<PopupMenuEntry<T>> items,
  GlobalKey routeKey,
) {
  final fallbackItems = <PopupMenuEntry<T>>[];
  var routeKeyPending = true;
  for (final item in items) {
    if (item is BusyApiPopupMenuItem<T>) {
      fallbackItems.add(
        BusyApiPopupMenuItem<T>(
          value: item.menuValue,
          label: item.label,
          icon: item.icon,
          iconColor: item.iconColor,
          shortcut: item.shortcut,
          enabled: item.enabled,
          checked: item.checked,
          trailingCheck: item.trailingCheck,
          mutuallyExclusive: item.mutuallyExclusive,
          routeKey: routeKeyPending ? routeKey : null,
        ),
      );
      routeKeyPending = false;
    } else {
      fallbackItems.add(item);
    }
  }
  return fallbackItems;
}

/// Shows a BusyApi context menu at a global pointer position.
///
/// The menu opens away from the pointer's reading-direction edge and stays
/// inside the root overlay. Use [BusyApiPopupMenuItem] entries to keep menu
/// rows consistent with the rest of the application.
Future<T?> showBusyApiContextMenu<T>(
  BuildContext context,
  Offset globalPosition, {
  required List<PopupMenuEntry<T>> items,
  double width = BusyApiSizes.popupMenuMinWidth,
}) {
  if (items.isEmpty) {
    return Future<T?>.value();
  }
  return showBusyApiMenu<T>(
    context: context,
    anchorPoint: globalPosition,
    items: items,
    width: width,
  );
}

/// A real nested menu; its label is never a selectable command.
class BusyApiSubmenuItem<T> extends PopupMenuEntry<T> {
  const BusyApiSubmenuItem({
    super.key,
    required this.label,
    required this.items,
    this.enabled = true,
  });
  final String label;
  final List<PopupMenuEntry<T>> items;
  final bool enabled;
  @override
  double get height => kMinInteractiveDimension;
  @override
  bool represents(T? value) => false;
  @override
  State<BusyApiSubmenuItem<T>> createState() => _BusyApiSubmenuItemState<T>();
}

class _BusyApiSubmenuItemState<T> extends State<BusyApiSubmenuItem<T>> {
  @override
  Widget build(BuildContext context) => Text(widget.label);
}

class _BusyApiNestedMenuRoute<T> extends PopupRoute<T> {
  _BusyApiNestedMenuRoute({
    required this.anchor,
    required this.items,
    required this.themes,
    required this.direction,
    required this.routeKey,
    required this.dismissLabel,
    required this.focusFirst,
  });
  final bool focusFirst;
  final Rect anchor;
  final List<PopupMenuEntry<T>> items;
  final CapturedThemes themes;
  final TextDirection direction;
  final GlobalKey routeKey;
  final String dismissLabel;
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => dismissLabel;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    Directionality(
      textDirection: direction,
      child: _BusyApiNestedMenu<T>(route: this),
    ),
  );
}

class _BusyApiNestedMenu<T> extends StatefulWidget {
  const _BusyApiNestedMenu({required this.route});
  final _BusyApiNestedMenuRoute<T> route;
  @override
  State<_BusyApiNestedMenu<T>> createState() => _BusyApiNestedMenuState<T>();
}

class _BusyApiNestedMenuState<T> extends State<_BusyApiNestedMenu<T>> {
  final _controller = MenuController();
  final _firstFocus = FocusNode(debugLabel: 'First nested menu item');
  bool _selected = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.open();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.route.focusFirst) _firstFocus.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    super.dispose();
  }

  List<Widget> _children(
    List<PopupMenuEntry<T>> items, {
    bool root = false,
  }) => [
    for (final item in items)
      if (item is BusyApiSubmenuItem<T>)
        SubmenuButton(
          focusNode: root && identical(item, items.first) ? _firstFocus : null,
          menuChildren: item.enabled ? _children(item.items) : const [],
          child: Text(item.label),
        )
      else if (item is BusyApiPopupMenuItem<T>)
        Semantics(
          checked: item.trailingCheck ? item.checked : null,
          inMutuallyExclusiveGroup:
              item.trailingCheck && item.mutuallyExclusive,
          child: MenuItemButton(
            focusNode: root && identical(item, items.first)
                ? _firstFocus
                : null,
            closeOnActivate: false,
            onPressed: item.enabled
                ? () {
                    _selected = true;
                    Navigator.of(context).pop(item.menuValue);
                  }
                : null,
            leadingIcon: item.icon == null
                ? null
                : Icon(
                    item.icon,
                    size: BusyApiSizes.iconSm,
                    color: item.iconColor,
                  ),
            trailingIcon: item.trailingCheck
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.shortcut case final shortcut?) ...[
                        Text(shortcut),
                        const SizedBox(width: BusyApiSpacing.sm),
                      ],
                      Visibility.maintain(
                        visible: item.checked,
                        child: const Icon(
                          BusyApiGlyphs.check,
                          size: BusyApiSizes.iconSm,
                        ),
                      ),
                    ],
                  )
                : item.shortcut == null
                ? null
                : Text(item.shortcut!),
            child: Text(item.label),
          ),
        )
      else if (item is PopupMenuDivider)
        const Divider(height: BusyApiSpacing.sm),
  ];

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        left: widget.route.anchor.left,
        top: widget.route.anchor.bottom,
        child: MenuAnchor(
          key: widget.route.routeKey,
          controller: _controller,
          consumeOutsideTap: true,
          onClose: () {
            if (!_selected && mounted && widget.route.isCurrent) {
              Navigator.of(context).pop();
            }
          },
          menuChildren: _children(widget.route.items, root: true),
          child: const SizedBox.shrink(),
        ),
      ),
    ],
  );
}

class BusyApiPopupMenuItem<T> extends PopupMenuItem<T> {
  BusyApiPopupMenuItem({
    super.key,
    required T value,
    required String label,
    IconData? icon,
    Color? iconColor,
    String? shortcut,
    this.gtkAccelerator,
    super.enabled = true,
    bool checked = false,
    bool trailingCheck = false,
    bool mutuallyExclusive = true,
    Key? routeKey,
  }) : label = label,
       menuValue = value,
       icon = icon,
       iconColor = iconColor,
       shortcut = shortcut,
       checked = checked,
       trailingCheck = trailingCheck,
       mutuallyExclusive = mutuallyExclusive,
       super(
         value: value,
         child: KeyedSubtree(
           key: routeKey,
           child: _BusyApiPopupMenuItemContent(
             label: label,
             icon: icon,
             iconColor: iconColor,
             shortcut: shortcut,
             checked: checked,
             trailingCheck: trailingCheck,
             mutuallyExclusive: mutuallyExclusive,
           ),
         ),
       );

  final String label;
  final T menuValue;
  final IconData? icon;
  final Color? iconColor;
  final String? shortcut;
  final String? gtkAccelerator;
  final bool checked;
  final bool trailingCheck;
  final bool mutuallyExclusive;
}

class _BusyApiPopupMenuItemContent extends StatelessWidget {
  const _BusyApiPopupMenuItemContent({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.shortcut,
    required this.checked,
    required this.trailingCheck,
    required this.mutuallyExclusive,
  });

  final String label;
  final IconData? icon;
  final Color? iconColor;
  final String? shortcut;
  final bool checked;
  final bool trailingCheck;
  final bool mutuallyExclusive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelText = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final shortcutText = shortcut == null || shortcut!.isEmpty
        ? null
        : Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              shortcut!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          );
    return Semantics(
      checked: trailingCheck ? checked : null,
      inMutuallyExclusiveGroup: trailingCheck && mutuallyExclusive,
      child: IconTheme.merge(
        data: const IconThemeData(size: BusyApiSizes.iconSm),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: iconColor),
              const SizedBox(width: BusyApiSpacing.sm),
            ],
            Expanded(child: labelText),
            if (shortcutText != null) ...[
              const SizedBox(width: BusyApiSpacing.sm),
              shortcutText,
            ],
            if (trailingCheck) ...[
              const SizedBox(width: BusyApiSpacing.sm),
              Visibility.maintain(
                visible: checked,
                child: const Icon(BusyApiGlyphs.check),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

typedef BusyApiMenuTriggerBuilder = Widget Function(
  BuildContext context,
  BusyApiMenuTriggerDetails trigger,
);

@immutable
class BusyApiMenuTriggerDetails {
  // The measured anchor remains a private field with a public named parameter.
  const BusyApiMenuTriggerDetails._({
    required this.onPressed,
    required this.focusNode,
    required this.isOpen,
    required GlobalKey anchorKey,
    // ignore: prefer_initializing_formals
  }) : _anchorKey = anchorKey;

  final VoidCallback? onPressed;
  final FocusNode focusNode;
  final bool isOpen;
  final GlobalKey _anchorKey;

  Widget anchor({required Widget child}) {
    return KeyedSubtree(key: _anchorKey, child: child);
  }
}

/// A shared trigger that presents GTK menus with a Flutter fallback.
class BusyApiMenuButton<T> extends StatefulWidget {
  const BusyApiMenuButton({
    super.key,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    required this.triggerBuilder,
    this.enabled = true,
    this.nativeMenuService = const NativeMenuService(),
    this.fallbackMenuWidth,
  });

  final String tooltip;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final BusyApiMenuTriggerBuilder triggerBuilder;
  final bool enabled;
  final NativeMenuService nativeMenuService;
  final double? fallbackMenuWidth;

  @override
  State<BusyApiMenuButton<T>> createState() => _BusyApiMenuButtonState<T>();
}

class _BusyApiMenuButtonState<T> extends State<BusyApiMenuButton<T>> {
  final _triggerKey = GlobalKey();
  final _anchorKey = GlobalKey();
  late final FocusNode _focusNode;
  BusyApiMenuSession? _activeMenuSession;
  var _open = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: 'BusyApi menu trigger',
      onKeyEvent: _handleKeyEvent,
    );
  }

  @override
  void didUpdateWidget(covariant BusyApiMenuButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled && _open) {
      _closeMenu();
    }
  }

  @override
  void dispose() {
    final session = _activeMenuSession;
    _activeMenuSession = null;
    if (session != null) {
      unawaited(session.dismiss());
    }
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trigger = BusyApiMenuTriggerDetails._(
      onPressed: widget.enabled ? _toggleMenu : null,
      focusNode: _focusNode,
      isOpen: _open,
      anchorKey: _anchorKey,
    );
    return KeyedSubtree(
      key: _triggerKey,
      child: widget.triggerBuilder(context, trigger),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (isBusyApiContextMenuKeyEvent(event) ||
        event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      if (!_open) {
        unawaited(_openMenu(focusFirst: true));
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _open) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleMenu() {
    if (_open) {
      _closeMenu();
      return;
    }
    unawaited(_openMenu());
  }

  Future<void> _openMenu({bool focusFirst = false}) async {
    final triggerContext = _triggerKey.currentContext;
    if (!widget.enabled ||
        _open ||
        triggerContext == null ||
        widget.items.isEmpty) {
      return;
    }
    final items = List<PopupMenuEntry<T>>.unmodifiable(widget.items);
    final onSelected = widget.onSelected;
    final session = BusyApiMenuSession();
    _activeMenuSession = session;
    setState(() => _open = true);

    T? selection;
    try {
      final anchorContext = _anchorKey.currentContext ?? triggerContext;
      selection = await showBusyApiMenu<T>(
        context: triggerContext,
        anchorContext: anchorContext,
        items: items,
        nativeMenuService: widget.nativeMenuService,
        session: session,
        focusFirst: focusFirst,
        width: widget.fallbackMenuWidth,
      );
    } finally {
      if (mounted && identical(_activeMenuSession, session)) {
        setState(() {
          _activeMenuSession = null;
          _open = false;
        });
      }
    }
    if (mounted && !session.dismissed && selection != null) {
      onSelected(selection);
    }
  }

  void _closeMenu() {
    final session = _activeMenuSession;
    if (session == null) {
      return;
    }
    setState(() {
      _activeMenuSession = null;
      _open = false;
    });
    unawaited(session.dismiss());
  }
}

/// Whether [event] is the standard desktop request for an item context menu.
///
/// Linux applications conventionally support both the Menu key and Shift+F10.
bool isBusyApiContextMenuKeyEvent(KeyEvent event) {
  if (event is! KeyDownEvent) {
    return false;
  }
  return event.logicalKey == LogicalKeyboardKey.contextMenu ||
      (event.logicalKey == LogicalKeyboardKey.f10 &&
          HardwareKeyboard.instance.isShiftPressed);
}

class BusyApiPopupSelectorOption<T> {
  const BusyApiPopupSelectorOption({
    required this.value,
    required this.label,
    this.icon,
    this.iconColor,
    this.shortcut,
    this.gtkAccelerator,
  });

  final T value;
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final String? shortcut;
  final String? gtkAccelerator;
}

/// The shared desktop selector used by Settings-style control rows.
class BusyApiPopupSelector<T> extends StatelessWidget {
  const BusyApiPopupSelector({
    super.key,
    required this.value,
    required this.label,
    required this.tooltip,
    required this.options,
    required this.onSelected,
    this.enabled = true,
    this.popupMinWidth = BusyApiSizes.languagePopupMinWidth,
    this.popupMaxWidth = BusyApiSizes.languagePopupMaxWidth,
    this.buttonMaxWidth = BusyApiSizes.languageButtonMaxWidth,
    this.leading,
    this.fullWidth = false,
    this.maxLabelLines = 1,
  });

  final T? value;
  final String label;
  final String tooltip;
  final List<BusyApiPopupSelectorOption<T>> options;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final double popupMinWidth;
  final double popupMaxWidth;
  final double buttonMaxWidth;
  final Widget? leading;
  final bool fullWidth;
  final int maxLabelLines;
  @override
  Widget build(BuildContext context) {
    // Inherit borderless button geometry and interaction states while keeping
    // the neutral control foreground rather than an action-link accent.
    final neutralButtonStyle = Theme.of(context).outlinedButtonTheme.style;
    final selectorEnabled = enabled && options.isNotEmpty;
    final fallbackMenuWidth = (fullWidth ? popupMaxWidth : buttonMaxWidth)
        .clamp(popupMinWidth, popupMaxWidth);
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: fullWidth ? double.infinity : buttonMaxWidth,
        ),
        child: BusyApiMenuButton<T>(
          tooltip: tooltip,
          enabled: selectorEnabled,
          fallbackMenuWidth: fallbackMenuWidth,
          onSelected: onSelected,
          items: [
            for (final option in options)
              BusyApiPopupMenuItem<T>(
                value: option.value,
                label: option.label,
                icon: option.icon,
                iconColor: option.iconColor,
                shortcut: option.shortcut,
                gtkAccelerator: option.gtkAccelerator,
                checked: option.value == value,
                trailingCheck: true,
              ),
          ],
          triggerBuilder: (context, trigger) {
            return trigger.anchor(
              child: Tooltip(
                message: tooltip,
                child: Semantics(
                  expanded: trigger.isOpen,
                  child: TextButton(
                    style: ButtonStyle(
                      foregroundColor: neutralButtonStyle?.foregroundColor,
                      iconColor: neutralButtonStyle?.iconColor,
                    ),
                    onPressed: trigger.onPressed,
                    focusNode: trigger.focusNode,
                    child: Row(
                      mainAxisSize: fullWidth
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      children: [
                        if (leading != null) ...[
                          leading!,
                          const SizedBox(width: BusyApiSpacing.sm),
                        ],
                        if (fullWidth)
                          Expanded(
                            child: Text(
                              label,
                              maxLines: maxLabelLines,
                              overflow: TextOverflow.ellipsis,
                              softWrap: maxLabelLines > 1,
                            ),
                          )
                        else
                          Flexible(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math.max(
                                  0,
                                  buttonMaxWidth -
                                      BusyApiSizes.iconButton -
                                      BusyApiSpacing.smPlus,
                                ),
                              ),
                              child: Text(
                                label,
                                maxLines: maxLabelLines,
                                overflow: TextOverflow.ellipsis,
                                softWrap: maxLabelLines > 1,
                              ),
                            ),
                          ),
                        const SizedBox(width: BusyApiSpacing.sm),
                        const Icon(
                          BusyApiGlyphs.downArrow,
                          size: BusyApiSizes.iconSm,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Input decoration inherited by controls hosted in a grouped-list row.
///
/// The grouped list owns the surface, outline, padding, and separators. Yaru
/// and Flutter continue to own editing behavior without painting a second
/// Material input surface inside the native desktop row.
InputDecorationThemeData busyApiGroupedInputDecorationTheme(
  BuildContext context,
) {
  final theme = Theme.of(context);
  final labelColor = theme.colorScheme.onSurfaceVariant;
  final labelStyle = theme.textTheme.bodyMedium?.copyWith(color: labelColor);

  return theme.inputDecorationTheme.copyWith(
    filled: false,
    fillColor: Colors.transparent,
    hoverColor: Colors.transparent,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    contentPadding: EdgeInsets.zero,
    labelStyle: labelStyle,
    floatingLabelStyle: labelStyle,
    floatingLabelBehavior: FloatingLabelBehavior.auto,
  );
}

InputDecoration busyApiGroupedTextFieldDecoration(
  BuildContext context, {
  required String labelText,
  String? hintText,
  String? errorText,
  bool alignLabelWithHint = false,
}) {
  final decoration = InputDecoration(
    labelText: labelText,
    hintText: hintText,
    errorText: errorText,
    alignLabelWithHint: alignLabelWithHint,
  );
  final defaults = busyApiGroupedInputDecorationTheme(context);
  final resolved = decoration.applyDefaults(defaults);
  if (errorText == null) {
    return resolved;
  }
  final errorLabelStyle = Theme.of(context).textTheme.bodyMedium
      ?.copyWith(color: Theme.of(context).colorScheme.error);
  return resolved.copyWith(
    labelStyle: errorLabelStyle,
    floatingLabelStyle: errorLabelStyle,
  );
}

/// A text entry hosted by the native grouped-list form surface.
///
/// The row owns the background, outline, padding, and separators while
/// [TextFormField] continues to own editing, validation, and focus behavior.
class BusyApiGroupedTextEntry extends StatefulWidget {
  const BusyApiGroupedTextEntry({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.errorText,
    this.hintText,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.focusNode,
    this.keyboardType,
    this.inputFormatters,
    this.minLines = 1,
    this.maxLines = 1,
    this.textInputAction,
    this.textDirection,
    this.textStyle,
    this.alignLabelWithHint = false,
    this.obscureText = false,
    this.enableSuggestions = true,
    this.autocorrect = true,
    this.trailing,
    this.onChanged,
    this.onSubmitted,
  }) : assert(controller == null || initialValue == null),
       assert(minLines > 0),
       assert(maxLines >= minLines);

  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final String? errorText;
  final String? hintText;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int minLines;
  final int maxLines;
  final TextInputAction? textInputAction;
  final TextDirection? textDirection;
  final TextStyle? textStyle;
  final bool alignLabelWithHint;
  final bool obscureText;
  final bool enableSuggestions;
  final bool autocorrect;
  final Widget? trailing;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<BusyApiGroupedTextEntry> createState() =>
      _BusyApiGroupedTextEntryState();
}

class _BusyApiGroupedTextEntryState extends State<BusyApiGroupedTextEntry> {
  final _fieldKey = GlobalKey<FormFieldState<String>>();

  @override
  Widget build(BuildContext context) {
    final row = _buildRow(context);
    if (!widget.enabled || widget.onSubmitted == null) {
      return row;
    }
    // Linux physical key events are not always translated into the text-input
    // action that drives TextFormField.onFieldSubmitted. Keep that callback for
    // IME actions and bind the desktop Enter keys explicitly as well.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _submit,
      },
      child: row,
    );
  }

  Widget _buildRow(BuildContext context) {
    return YaruListTile.square(
      title: TextFormField(
        key: _fieldKey,
        controller: widget.controller,
        initialValue: widget.initialValue,
        enabled: widget.enabled,
        readOnly: widget.readOnly,
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        keyboardType: widget.keyboardType,
        inputFormatters: widget.inputFormatters,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        textInputAction: widget.textInputAction,
        textDirection: widget.textDirection,
        obscureText: widget.obscureText,
        enableSuggestions: widget.enableSuggestions,
        autocorrect: widget.autocorrect,
        style: widget.textStyle,
        onChanged: widget.enabled ? widget.onChanged : null,
        onFieldSubmitted: widget.enabled ? widget.onSubmitted : null,
        decoration: busyApiGroupedTextFieldDecoration(
          context,
          labelText: widget.label,
          hintText: widget.hintText,
          errorText: widget.errorText,
          alignLabelWithHint: widget.alignLabelWithHint,
        ),
      ),
      trailing: widget.trailing,
    );
  }

  void _submit() {
    final value =
        widget.controller?.text ??
        _fieldKey.currentState?.value ??
        widget.initialValue ??
        '';
    widget.onSubmitted?.call(value);
  }
}

class BusyApiClamp extends StatelessWidget {
  const BusyApiClamp({
    super.key,
    required this.child,
    this.maxWidth = 680,
    this.scrollable = true,
    this.center = true,
    this.padding = EdgeInsets.zero,
    this.margin = const EdgeInsets.all(BusyApiSpacing.lg),
    this.controller,
  });

  final Widget child;
  final double maxWidth;
  final bool scrollable;
  final bool center;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final clamped = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      margin: margin,
      padding: padding,
      child: child,
    );

    final body = center
        ? Align(alignment: Alignment.topCenter, child: clamped)
        : clamped;

    return scrollable
        ? SingleChildScrollView(controller: controller, child: body)
        : body;
  }
}

/// Semantic parent surfaces that can contain a grouped card.
enum BusyApiSurfaceRole { window, view, sidebar, dialog, popover }

class BusyApiSurfaceScope extends InheritedWidget {
  const BusyApiSurfaceScope({
    super.key,
    required this.role,
    required super.child,
  });

  final BusyApiSurfaceRole role;

  static BusyApiSurfaceRole roleOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<BusyApiSurfaceScope>()
            ?.role ??
        BusyApiSurfaceRole.window;
  }

  @override
  bool updateShouldNotify(BusyApiSurfaceScope oldWidget) {
    return role != oldWidget.role;
  }
}

Color busyApiGroupedSurfaceColor(
  BuildContext context, {
  BusyApiSurfaceRole? parentRole,
}) {
  final colors = BusyApiSurfaceColors.of(context);
  final role = parentRole ?? BusyApiSurfaceScope.roleOf(context);
  if (role == BusyApiSurfaceRole.window) {
    return colors.card;
  }
  final parent = switch (role) {
    BusyApiSurfaceRole.window => colors.window,
    BusyApiSurfaceRole.view => colors.view,
    BusyApiSurfaceRole.sidebar => colors.sidebar,
    BusyApiSurfaceRole.dialog => colors.dialog,
    BusyApiSurfaceRole.popover => colors.popover,
  };
  return Color.alphaBlend(colors.groupedSurface, parent);
}

class BusyApiSurface extends StatelessWidget {
  const BusyApiSurface({
    super.key,
    required this.child,
    this.filled = true,
    this.color,
    this.side,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final bool filled;
  final Color? color;
  final BorderSide? side;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final cardTheme = CardTheme.of(context);
    final surfaceColors = BusyApiSurfaceColors.of(context);
    final fallbackShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(BusyApiRadius.lg),
    );
    final themedShape = cardTheme.shape;
    final ShapeBorder shape;
    if (themedShape is OutlinedBorder) {
      shape = side == null ? themedShape : themedShape.copyWith(side: side);
    } else if (themedShape != null && side == null) {
      shape = themedShape;
    } else {
      shape = fallbackShape.copyWith(side: side ?? BorderSide.none);
    }
    final surfaceColor = filled
        ? color ?? cardTheme.color ?? surfaceColors.card
        : Colors.transparent;
    if (filled) {
      final shadowShape = shape is OutlinedBorder
          ? shape.copyWith(side: BorderSide.none)
          : shape;
      return DecoratedBox(
        decoration: ShapeDecoration(
          shape: shadowShape,
          shadows: BusyApiShadow.nativeCardShadowsFor(context),
        ),
        child: Card(
          margin: EdgeInsets.zero,
          semanticContainer: false,
          color: surfaceColor,
          shadowColor: Colors.transparent,
          shape: shape,
          clipBehavior: clipBehavior,
          child: child,
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      elevation: 0,
      surfaceTintColor: cardTheme.surfaceTintColor ?? Colors.transparent,
      shape: shape,
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}

/// The single semantic raised surface for grouped rows and cards.
class BusyApiGroupedSurface extends StatelessWidget {
  const BusyApiGroupedSurface({
    super.key,
    required this.child,
    this.clipBehavior = Clip.antiAlias,
    this.focused = false,
  });

  final Widget child;
  final Clip clipBehavior;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    return BusyApiSurface(
      color: busyApiGroupedSurfaceColor(context),
      side: focused
          ? BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: BusyApiStroke.focus,
            )
          : highContrast
          ? BorderSide(color: Theme.of(context).colorScheme.outline)
          : null,
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}

/// Shared split-view sidebar surface and reading-direction boundary.
class BusyApiSidebarSurface extends StatelessWidget {
  const BusyApiSidebarSurface({
    super.key,
    required this.child,
    this.showEndBorder = true,
  });

  final Widget child;
  final bool showEndBorder;

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    return Material(
      color: colors.sidebar,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: !showEndBorder
              ? null
              : BorderDirectional(
                  end: BorderSide(
                    color: colors.sidebarBorder,
                    width: BusyApiStroke.hairline,
                  ),
                ),
        ),
        child: child,
      ),
    );
  }
}

/// A GTK-style navigation list for a persistent desktop sidebar.
class BusyApiSidebarNavigation extends StatelessWidget {
  const BusyApiSidebarNavigation({
    super.key,
    required this.children,
    this.surfaceColor,
  });

  final List<Widget> children;
  final Color? surfaceColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BusyApiSurfaceColors.of(context);
    final masterDetailTheme = YaruMasterDetailTheme.of(context);

    return Theme(
      data: theme.copyWith(
        listTileTheme: theme.listTileTheme.copyWith(
          selectedColor: colors.foreground,
          selectedTileColor: Color.alphaBlend(
            colors.control,
            surfaceColor ?? colors.sidebar,
          ),
          tileColor: Colors.transparent,
          iconColor: colors.mutedForeground,
          textColor: colors.foreground,
          titleTextStyle: theme.textTheme.bodyMedium,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: BusyApiSpacing.sm,
          ),
          horizontalTitleGap: BusyApiSpacing.sm,
          minVerticalPadding: 0,
          minLeadingWidth: BusyApiSizes.iconSm,
          minTileHeight: BusyApiSizes.sidebarRowHeight,
          visualDensity: VisualDensity.standard,
          titleAlignment: ListTileTitleAlignment.center,
        ),
      ),
      child: ListView.separated(
        padding:
            masterDetailTheme.listPadding ??
            const EdgeInsets.symmetric(vertical: BusyApiSpacing.sm),
        itemCount: children.length,
        itemBuilder: (context, index) => children[index],
        separatorBuilder: (context, index) => SizedBox(
          height: masterDetailTheme.tileSpacing ?? BusyApiSpacing.xxs,
        ),
      ),
    );
  }
}

/// A selectable row for [BusyApiSidebarNavigation].
class BusyApiSidebarNavigationTile extends StatelessWidget {
  const BusyApiSidebarNavigationTile({
    super.key,
    required this.selected,
    required this.leading,
    required this.title,
    required this.onTap,
  });

  final bool selected;
  final Widget leading;
  final Widget title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return YaruMasterTile(
      selected: selected,
      leading: IconTheme.merge(
        data: const IconThemeData(size: BusyApiSizes.iconSm),
        child: leading,
      ),
      title: title,
      onTap: onTap,
    );
  }
}

typedef BusyApiSidebarRecordMenuBuilder<T> = List<PopupMenuEntry<T>> Function(
  BuildContext context,
);

/// The interactive record surface used by persistent sidebar lists.
///
/// This is the shared form of the Recent-workspace row: a transparent rounded
/// surface with native hover treatment and, when supplied, one overflow and
/// context-menu action model. Callers can use the standard title/subtitle
/// identity layout or provide domain-specific [content].
class BusyApiSidebarRecordRow<T> extends StatefulWidget {
  const BusyApiSidebarRecordRow({
    super.key,
    required this.icon,
    required this.onTap,
    this.title,
    this.subtitle,
    this.pathSubtitle = false,
    this.content,
    this.selected = false,
    this.compact = false,
    this.focusNode,
    this.geometryKey,
    this.onFocusChange,
    this.trailing,
    this.onDoubleTap,
    this.semanticsLabel,
    this.tooltip,
    this.menuTooltip,
    this.menuItemsBuilder,
    this.onMenuSelected,
    this.onMenuOpening,
  }) : assert(
         (title == null) != (content == null),
         'Supply either the standard title or custom content.',
       ),
       assert(
         (menuItemsBuilder == null) == (onMenuSelected == null),
         'Menu items and selection handling must be supplied together.',
       ),
       assert(
         menuItemsBuilder == null || menuTooltip != null,
         'Rows with a menu need a tooltip for its trigger.',
       );

  final IconData icon;
  final String? title;
  final String? subtitle;
  final bool pathSubtitle;
  final Widget? content;
  final bool selected, compact;
  final FocusNode? focusNode;

  /// Optional measured anchor; the public row key remains its resource identity.
  final GlobalKey? geometryKey;
  final ValueChanged<bool>? onFocusChange;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final String? semanticsLabel;
  final String? tooltip;
  final String? menuTooltip;
  final BusyApiSidebarRecordMenuBuilder<T>? menuItemsBuilder;
  final ValueChanged<T>? onMenuSelected;
  final VoidCallback? onMenuOpening;

  @override
  State<BusyApiSidebarRecordRow<T>> createState() =>
      _BusyApiSidebarRecordRowState<T>();
}

class _BusyApiSidebarRecordRowState<T>
    extends State<BusyApiSidebarRecordRow<T>> {
  final _rowKey = GlobalKey();
  late final FocusNode _rowFocusNode;
  var _contextMenuOpen = false;
  DateTime? _lastTapAt;

  bool get _hasMenu =>
      widget.menuItemsBuilder != null && widget.onMenuSelected != null;

  @override
  void initState() {
    super.initState();
    _rowFocusNode = FocusNode(debugLabel: 'BusyApi sidebar record row');
  }

  @override
  void dispose() {
    _rowFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_hasMenu || !isBusyApiContextMenuKeyEvent(event)) {
      return KeyEventResult.ignored;
    }
    unawaited(_showContextMenu());
    return KeyEventResult.handled;
  }

  void _handleTap() {
    final onDoubleTap = widget.onDoubleTap;
    if (onDoubleTap == null) {
      widget.onTap?.call();
      return;
    }
    final now = DateTime.now();
    final previous = _lastTapAt;
    final doubleTap =
        previous != null && now.difference(previous) <= kDoubleTapTimeout;
    _lastTapAt = doubleTap ? null : now;
    widget.onTap?.call();
    if (doubleTap) onDoubleTap();
  }

  Future<void> _showContextMenu([Offset? position]) async {
    if (!_hasMenu || _contextMenuOpen) return;
    final rowContext = _rowKey.currentContext;
    if (rowContext == null) return;

    widget.onMenuOpening?.call();
    setState(() => _contextMenuOpen = true);
    T? action;
    try {
      final items = widget.menuItemsBuilder!(rowContext);
      action = position == null
          ? await showBusyApiMenu<T>(
              context: rowContext,
              anchorContext: rowContext,
              items: items,
              focusFirst: true,
            )
          : await showBusyApiContextMenu<T>(rowContext, position, items: items);
    } finally {
      if (mounted) setState(() => _contextMenuOpen = false);
    }
    if (mounted && action != null) widget.onMenuSelected!(action);
  }

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final subtitle = widget.subtitle?.trim();
    final customContent = widget.content;
    final menuItems = widget.menuItemsBuilder?.call(context);
    final trailing = menuItems == null || menuItems.isEmpty
        ? widget.trailing
        : BusyApiMenuButton<T>(
            tooltip: widget.menuTooltip!,
            items: menuItems,
            onSelected: widget.onMenuSelected!,
            triggerBuilder: (context, trigger) => trigger.anchor(
              child: BusyApiCompactIconButton(
                tooltip: widget.menuTooltip!,
                icon: BusyApiGlyphs.menuVertical,
                focusNode: trigger.focusNode,
                onPressed: trigger.onPressed == null
                    ? null
                    : () {
                        widget.onMenuOpening?.call();
                        trigger.onPressed!();
                      },
              ),
            ),
          );
    final customRow = customContent == null
        ? null
        : ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.compact
                  ? BusyApiSizes.sidebarTreeRowHeight
                  : BusyApiSizes.sidebarTreeRowHeight * 2,
            ),
            child: Row(
              children: [
                const SizedBox(width: BusyApiSpacing.sm),
                Icon(
                  widget.icon,
                  size: BusyApiSizes.iconSm,
                  color: colors.mutedForeground,
                ),
                const SizedBox(width: BusyApiSpacing.sm),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: widget.compact
                          ? BusyApiSpacing.xs
                          : BusyApiSpacing.sm,
                    ),
                    child: customContent,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: BusyApiSpacing.xs),
                  trailing,
                ],
                const SizedBox(width: BusyApiSpacing.sm),
              ],
            ),
          );
    // Standard identities use the same native row layout as other BusyApi
    // lists. Yaru owns their typography, content spacing and minimum extent.
    final tile = customRow == null
        ? YaruListTile.square(
            leading: Icon(
              widget.icon,
              size: BusyApiSizes.iconSm,
              color: colors.mutedForeground,
            ),
            title: Text(
              widget.title!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: subtitle == null || subtitle.isEmpty
                ? null
                : _busyApiGroupedRowSubtitle(
                    context,
                    widget.pathSubtitle
                        ? BusyApiPathLabel(path: subtitle)
                        : Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
            trailing: trailing,
            focusNode: widget.focusNode ?? _rowFocusNode,
            onFocusChange: widget.onFocusChange,
            hoverColor: busyApiRowHoverColor(context),
            onTap: widget.onTap == null ? null : _handleTap,
          )
        : InkWell(
            hoverColor: busyApiRowHoverColor(context),
            focusNode: widget.focusNode ?? _rowFocusNode,
            onFocusChange: widget.onFocusChange,
            canRequestFocus: true,
            onTap: widget.onTap == null ? null : _handleTap,
            child: customRow,
          );
    final row = KeyedSubtree(
      key: _rowKey,
      child: Focus(
        onKeyEvent: _handleKeyEvent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: BusyApiStroke.hairline),
          child: Material(
            color: widget.selected || _contextMenuOpen
                ? busyApiRowHoverColor(context)
                : BusyApiLinuxPalette.transparent,
            borderRadius: BorderRadius.circular(BusyApiRadius.md),
            clipBehavior: Clip.antiAlias,
            child: GestureDetector(
              onSecondaryTapUp: !_hasMenu
                  ? null
                  : (details) {
                      (widget.focusNode ?? _rowFocusNode).requestFocus();
                      unawaited(_showContextMenu(details.globalPosition));
                    },
              child: tile,
            ),
          ),
        ),
      ),
    );
    final semanticRow = Semantics(
      container: true,
      selected: widget.selected,
      button: true,
      label: widget.semanticsLabel,
      enabled: widget.onTap != null,
      onTap: widget.onTap == null ? null : _handleTap,
      child: row,
    );
    final tooltip = widget.tooltip;
    final presented = tooltip == null || tooltip.isEmpty
        ? semanticRow
        : Tooltip(
            message: tooltip,
            excludeFromSemantics: true,
            child: semanticRow,
          );
    return widget.geometryKey == null
        ? presented
        : KeyedSubtree(key: widget.geometryKey, child: presented);
  }
}

/// A native contextual information bar embedded in the surrounding layout.
///
/// This mirrors Libadwaita's banner pattern: the host decides when the banner
/// is revealed, while the banner owns semantic surface, typography, and
/// native action-control presentation without floating over content.
class BusyApiBanner extends StatelessWidget {
  const BusyApiBanner({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.suggestedAction = false,
    this.revealed = true,
  }) : assert(actionLabel != null || onAction == null);

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool suggestedAction;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final actionLabel = this.actionLabel;
    final action = actionLabel == null
        ? null
        : suggestedAction
        ? BusyApiPushButton.suggested(
            onPressed: onAction,
            child: Text(actionLabel),
          )
        : BusyApiPushButton.standard(
            onPressed: onAction,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: BusyApiSpacing.sm,
              ),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(actionLabel),
          );
    final banner = Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.panel,
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BusyApiSpacing.md,
            vertical: BusyApiSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.foreground),
                  textAlign: TextAlign.start,
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: BusyApiSpacing.md),
                action,
              ],
            ],
          ),
        ),
      ),
    );
    final revealDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : BusyApiMotion.bannerReveal;
    if (revealDuration == Duration.zero) {
      return ClipRect(child: revealed ? banner : const SizedBox.shrink());
    }
    return ClipRect(
      child: AnimatedSize(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
        duration: revealDuration,
        reverseDuration: revealDuration,
        curve: BusyApiMotion.bannerRevealCurve,
        child: revealed ? banner : const SizedBox.shrink(),
      ),
    );
  }
}

class BusyApiGroupedList extends StatelessWidget {
  const BusyApiGroupedList({
    super.key,
    this.title,
    this.description,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: BusyApiSpacing.xs),
    this.filled = false,
  });

  final String? title;
  final String? description;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        top: title == null && (description == null || description!.isEmpty)
            ? BusyApiSpacing.md
            : BusyApiSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Padding(
              padding: padding,
              child: Semantics(
                header: true,
                child: Text(title!, style: busyApiSectionHeaderStyle(context)),
              ),
            ),
            if (description != null && description!.isNotEmpty) ...[
              const SizedBox(height: BusyApiSpacing.xs),
              Padding(
                padding: padding,
                child: Text(
                  description!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            const SizedBox(height: BusyApiSpacing.sm),
          ],
          _BusyApiGroupedListSurface(filled: filled, children: children),
        ],
      ),
    );
  }
}

class _BusyApiGroupedListSurface extends StatelessWidget {
  const _BusyApiGroupedListSurface({
    required this.filled,
    required this.children,
  });

  final bool filled;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final list = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < children.length; index++) ...[
          children[index],
          if (index < children.length - 1)
            Divider(height: 1, thickness: 1, color: colors.cardShade),
        ],
      ],
    );

    if (!filled) {
      return list;
    }

    return BusyApiGroupedSurface(child: list);
  }
}

/// A single-selection row following the native AdwComboRow interaction model.
///
/// The complete row owns hover, focus, and activation. Menu presentation is
/// delegated to BusyApi's GTK menu bridge on Linux.
class BusyApiComboRow<T> extends StatelessWidget {
  BusyApiComboRow({
    super.key,
    required this.title,
    required List<T> values,
    required this.selected,
    required this.labelFor,
    required this.onSelected,
    this.subtitle,
    this.errorText,
    this.leading,
    this.enabled = true,
    this.enabledFor,
    this.tooltip,
    this.width = BusyApiSizes.controlRowWidth,
  }) : values = List<T>.unmodifiable(values) {
    if (this.values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'A combo row requires at least one value.',
      );
    }
    if (this.values.toSet().length != this.values.length) {
      throw ArgumentError.value(
        values,
        'values',
        'A combo row requires unique values.',
      );
    }
    if (!this.values.contains(selected)) {
      throw ArgumentError.value(
        selected,
        'selected',
        'The selected value must be present in values.',
      );
    }
    if (!width.isFinite || width <= 0) {
      throw ArgumentError.value(
        width,
        'width',
        'The maximum value width must be finite and positive.',
      );
    }
  }

  final String title;
  final List<T> values;
  final T selected;
  final String Function(T value) labelFor;
  final ValueChanged<T> onSelected;
  final String? subtitle;
  final String? errorText;
  final Widget? leading;
  final bool enabled;
  // BusyAPI retains unavailable authored choices for explicit reconciliation.
  final bool Function(T)? enabledFor;
  final String? tooltip;
  final double width;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasError = errorText?.isNotEmpty ?? false;
        final subtitleWidget = hasError
            ? Text(
                errorText!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              )
            : subtitle == null
            ? null
            : Text(subtitle!);
        final styledSubtitle = subtitleWidget == null
            ? null
            : _busyApiGroupedRowSubtitle(
                context,
                subtitleWidget,
                enabled: enabled,
              );
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : width + BusyApiSpacing.md * 2;
        final maximumValueWidth =
            (availableWidth * BusyApiFormLayout.comboInlineMaxFraction)
                .clamp(0.0, width)
                .toDouble();

        return BusyApiMenuButton<int>(
          tooltip: tooltip ?? title,
          enabled: enabled,
          onSelected: (index) {
            final value = values[index];
            if (value != selected && (enabledFor?.call(value) ?? true)) {
              onSelected(value);
            }
          },
          items: [
            for (var index = 0; index < values.length; index++)
              BusyApiPopupMenuItem<int>(
                value: index,
                label: labelFor(values[index]),
                enabled: enabledFor?.call(values[index]) ?? true,
                checked:
                    values[index] == selected &&
                    (enabledFor?.call(values[index]) ?? true),
                // An unavailable retained value is an explanatory disabled
                // command, not a disabled member of GTK's live radio group.
                trailingCheck: enabledFor?.call(values[index]) ?? true,
                mutuallyExclusive: enabledFor?.call(values[index]) ?? true,
              ),
          ],
          triggerBuilder: (context, trigger) {
            final colors = BusyApiSurfaceColors.of(context);
            final valueForeground = enabled
                ? colors.foreground
                : colors.disabledForeground;
            final value = ExcludeSemantics(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maximumValueWidth),
                child: DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: valueForeground),
                  child: IconTheme.merge(
                    data: IconThemeData(
                      color: valueForeground,
                      size: BusyApiSizes.iconSm,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            labelFor(selected),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: BusyApiSpacing.sm),
                        trigger.anchor(
                          child: const Icon(BusyApiGlyphs.downArrow),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            final row = YaruListTile.square(
              leading: leading == null
                  ? null
                  : ExcludeSemantics(child: leading!),
              title: ExcludeSemantics(child: Text(title)),
              subtitle: styledSubtitle == null
                  ? null
                  : ExcludeSemantics(child: styledSubtitle),
              trailing: value,
              onTap: trigger.onPressed,
              focusNode: trigger.focusNode,
              hoverColor: busyApiRowHoverColor(context),
              enabled: enabled,
            );
            final semanticRow = Semantics(
              container: true,
              button: true,
              enabled: enabled,
              expanded: trigger.isOpen,
              onTap: enabled ? trigger.onPressed : null,
              label: subtitle == null || subtitle!.isEmpty
                  ? title
                  : '$title, $subtitle',
              value: labelFor(selected),
              hint: hasError ? errorText : null,
              liveRegion: hasError,
              validationResult: hasError
                  ? ui.SemanticsValidationResult.invalid
                  : ui.SemanticsValidationResult.valid,
              child: ExcludeSemantics(child: row),
            );
            final statefulRow = ColoredBox(
              color: trigger.isOpen
                  ? busyApiRowHoverColor(context)
                  : Colors.transparent,
              child: semanticRow,
            );
            final boundedRow = constraints.hasBoundedWidth
                ? statefulRow
                : SizedBox(width: availableWidth, child: statefulRow);
            return tooltip == null
                ? boundedRow
                : Tooltip(
                    message: tooltip!,
                    excludeFromSemantics: true,
                    child: boundedRow,
                  );
          },
        );
      },
    );
  }
}

typedef BusyApiRowActivationCallback = void Function(
  BuildContext context,
  Offset? globalPosition,
);

class BusyApiActionRow extends StatefulWidget {
  const BusyApiActionRow({
    super.key,
    required this.title,
    this.subtitle,
    this.titleWidget,
    this.subtitleWidget,
    this.leading,
    this.trailing,
    this.onTap,
    this.onActivated,
    this.enabled = true,
    this.tooltip,
    this.destructive = false,
    this.autofocus = false,
    this.hoverColor,
  }) : assert(onTap == null || onActivated == null);

  final String title;
  final String? subtitle;
  final Widget? titleWidget;
  final Widget? subtitleWidget;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final BusyApiRowActivationCallback? onActivated;
  final bool enabled;
  final String? tooltip;
  final bool destructive;
  final bool autofocus;
  final Color? hoverColor;

  @override
  State<BusyApiActionRow> createState() => _BusyApiActionRowState();
}

class _BusyApiActionRowState extends State<BusyApiActionRow> {
  int? _primaryPointer;
  Offset? _pointerDownPosition;

  @override
  void didUpdateWidget(covariant BusyApiActionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.onActivated == null) {
      _clearPointer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = BusyApiSurfaceColors.of(context);
    final titleStyle = widget.destructive
        ? TextStyle(
            color: widget.enabled
                ? busyApiDestructiveForeground(context)
                : colors.disabledForeground,
          )
        : null;
    final subtitle =
        widget.subtitleWidget ??
        (widget.subtitle == null || widget.subtitle!.isEmpty
            ? null
            : Text(
                widget.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ));
    final interactive =
        widget.enabled && (widget.onTap != null || widget.onActivated != null);
    final row = YaruListTile.square(
      leading: widget.leading,
      title:
          widget.titleWidget ??
          Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
      subtitle: subtitle == null
          ? null
          : _busyApiGroupedRowSubtitle(
              context,
              subtitle,
              enabled: widget.enabled,
            ),
      trailing: widget.trailing,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      hoverColor: widget.hoverColor ?? busyApiRowHoverColor(context),
      onTap: interactive ? _activate : null,
    );

    final trackedRow = widget.onActivated == null
        ? row
        : Listener(
            onPointerDown: widget.enabled ? _handlePointerDown : null,
            onPointerUp: widget.enabled ? _handlePointerUp : null,
            onPointerCancel: widget.enabled ? _handlePointerCancel : null,
            child: row,
          );

    if (widget.enabled || widget.tooltip == null) {
      return trackedRow;
    }

    return Tooltip(
      message: widget.tooltip!,
      child: Opacity(opacity: 0.6, child: IgnorePointer(child: trackedRow)),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) {
      return;
    }
    _primaryPointer = event.pointer;
    _pointerDownPosition = event.position;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_primaryPointer != event.pointer) {
      return;
    }
    final pointer = event.pointer;
    scheduleMicrotask(() {
      if (mounted && _primaryPointer == pointer) {
        _clearPointer();
      }
    });
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_primaryPointer == event.pointer) {
      _clearPointer();
    }
  }

  void _activate() {
    final onActivated = widget.onActivated;
    if (onActivated == null) {
      widget.onTap?.call();
      return;
    }
    final globalPosition = _pointerDownPosition;
    _clearPointer();
    onActivated(context, globalPosition);
  }

  void _clearPointer() {
    _primaryPointer = null;
    _pointerDownPosition = null;
  }
}

/// A Yaru switch with Libadwaita-style state colors and no external halo.
class BusyApiSwitch extends StatefulWidget {
  const BusyApiSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.mouseCursor,
    this.onOffShapes,
    this.hasFocusBorder,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;
  final MouseCursor? mouseCursor;
  final bool? onOffShapes;
  final bool? hasFocusBorder;

  @override
  State<BusyApiSwitch> createState() => _BusyApiSwitchState();
}

class _BusyApiSwitchState extends State<BusyApiSwitch> {
  bool _hovered = false;
  int? _pressedPointer;

  bool get _pressed => _pressedPointer != null;

  @override
  void didUpdateWidget(BusyApiSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null) {
      _pressedPointer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inheritedSwitchTheme = YaruSwitchTheme.of(context);
    final checkedTrackColor = _busyApiCheckedSwitchColor(
      theme.colorScheme.primary,
      brightness: theme.brightness,
      hovered: _hovered,
      pressed: _pressed,
    );

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Listener(
        onPointerDown: widget.onChanged == null ? null : _handlePointerDown,
        onPointerUp: widget.onChanged == null ? null : _handlePointerUp,
        onPointerCancel: widget.onChanged == null ? null : _handlePointerCancel,
        child: YaruSwitchTheme(
          data: inheritedSwitchTheme.copyWith(
            indicatorColor: const WidgetStatePropertyAll<Color?>(
              Colors.transparent,
            ),
          ),
          child: YaruSwitch(
            value: widget.value,
            onChanged: widget.onChanged,
            selectedColor: checkedTrackColor,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            mouseCursor: widget.mouseCursor,
            onOffShapes: widget.onOffShapes,
            hasFocusBorder: widget.hasFocusBorder,
          ),
        ),
      ),
    );
  }

  void _setHovered(bool hovered) {
    if (_hovered != hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pressedPointer != null || event.buttons != kPrimaryButton) {
      return;
    }
    setState(() => _pressedPointer = event.pointer);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_pressedPointer == event.pointer) {
      setState(() => _pressedPointer = null);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pressedPointer == event.pointer) {
      setState(() => _pressedPointer = null);
    }
  }
}

Color _busyApiCheckedSwitchColor(
  Color accent, {
  required Brightness brightness,
  required bool hovered,
  required bool pressed,
}) {
  final normalLightnessDelta = brightness == Brightness.light ? 0.05 : 0.0;
  final stateLightnessDelta = pressed ? -0.07 : (hovered ? 0.07 : 0.0);
  final hsl = HSLColor.fromColor(accent);
  return hsl
      .withLightness(
        (hsl.lightness + normalLightnessDelta + stateLightnessDelta).clamp(
          0.0,
          1.0,
        ),
      )
      .toColor();
}

class BusyApiSwitchRow extends StatelessWidget {
  const BusyApiSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? leading;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final switchControl = BusyApiSwitch(
      value: value,
      onChanged: enabled ? onChanged : null,
    );
    return YaruSwitchListTile(
      value: value,
      onChanged: enabled ? onChanged : null,
      control: switchControl,
      secondary: leading,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : _busyApiGroupedRowSubtitle(
              context,
              Text(subtitle!),
              enabled: enabled,
            ),
      shape: const RoundedRectangleBorder(),
      hoverColor: busyApiRowHoverColor(context),
    );
  }
}

/// A Yaru radio button with GTK-style state colors and no external halo.
class BusyApiRadioButton<T> extends StatefulWidget {
  const BusyApiRadioButton({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    this.autofocus = false,
    this.focusNode,
    this.mouseCursor,
    this.hasFocusBorder,
  });

  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool autofocus;
  final FocusNode? focusNode;
  final MouseCursor? mouseCursor;
  final bool? hasFocusBorder;

  @override
  State<BusyApiRadioButton<T>> createState() => _BusyApiRadioButtonState<T>();
}

class _BusyApiRadioButtonState<T> extends State<BusyApiRadioButton<T>> {
  bool _hovered = false;
  int? _pressedPointer;

  bool get _pressed => _pressedPointer != null;

  @override
  void didUpdateWidget(BusyApiRadioButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null) {
      _pressedPointer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inheritedRadioTheme = YaruRadioTheme.of(context);
    final checkedColor = _busyApiCheckedRadioColor(
      theme.colorScheme.primary,
      brightness: theme.brightness,
      hovered: _hovered,
      pressed: _pressed,
    );

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Listener(
        onPointerDown: widget.onChanged == null ? null : _handlePointerDown,
        onPointerUp: widget.onChanged == null ? null : _handlePointerUp,
        onPointerCancel: widget.onChanged == null ? null : _handlePointerCancel,
        child: YaruRadioTheme(
          data: inheritedRadioTheme.copyWith(
            color: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return inheritedRadioTheme.color?.resolve(states);
              }
              if (states.contains(WidgetState.selected)) {
                return checkedColor;
              }
              return inheritedRadioTheme.color?.resolve(states);
            }),
            indicatorColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
          child: YaruRadioButton<T>(
            value: widget.value,
            groupValue: widget.groupValue,
            onChanged: widget.onChanged,
            title: widget.title,
            subtitle: widget.subtitle,
            contentPadding: widget.contentPadding,
            autofocus: widget.autofocus,
            focusNode: widget.focusNode,
            mouseCursor: widget.mouseCursor,
            hasFocusBorder: widget.hasFocusBorder,
          ),
        ),
      ),
    );
  }

  void _setHovered(bool hovered) {
    if (_hovered != hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pressedPointer != null || event.buttons != kPrimaryButton) {
      return;
    }
    setState(() => _pressedPointer = event.pointer);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_pressedPointer == event.pointer) {
      setState(() => _pressedPointer = null);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_pressedPointer == event.pointer) {
      setState(() => _pressedPointer = null);
    }
  }
}

Color _busyApiCheckedRadioColor(
  Color accent, {
  required Brightness brightness,
  required bool hovered,
  required bool pressed,
}) {
  final normalLightnessDelta = brightness == Brightness.light ? 0.05 : 0.0;
  final stateLightnessDelta = pressed ? -0.07 : (hovered ? 0.07 : 0.0);
  final hsl = HSLColor.fromColor(accent);
  return hsl
      .withLightness(
        (hsl.lightness + normalLightnessDelta + stateLightnessDelta).clamp(
          0.0,
          1.0,
        ),
      )
      .toColor();
}

class BusyApiCheckbox extends StatelessWidget {
  const BusyApiCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.tooltip,
    this.tristate = false,
  });

  final bool? value;
  final bool tristate;
  final String? tooltip;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final checkbox = YaruCheckbox(
      value: value,
      tristate: tristate,
      onChanged: onChanged,
    );
    final message = tooltip;
    if (message == null || message.isEmpty) {
      return checkbox;
    }
    return Tooltip(message: message, child: checkbox);
  }
}

enum BusyApiStatusKind { information, success, warning, error }

Color busyApiStatusColor(BuildContext context, BusyApiStatusKind kind) {
  final colors = YaruColors.of(context);
  return switch (kind) {
    BusyApiStatusKind.information => colors.link,
    BusyApiStatusKind.success => colors.success,
    BusyApiStatusKind.warning => colors.warning,
    BusyApiStatusKind.error => colors.error,
  };
}

class BusyApiStatusBox extends StatelessWidget {
  const BusyApiStatusBox({
    super.key,
    required this.message,
    this.kind = BusyApiStatusKind.information,
  });

  final String message;
  final BusyApiStatusKind kind;

  @override
  Widget build(BuildContext context) {
    return YaruInfoBox(
      yaruInfoType: switch (kind) {
        BusyApiStatusKind.information => YaruInfoType.information,
        BusyApiStatusKind.success => YaruInfoType.success,
        BusyApiStatusKind.warning => YaruInfoType.warning,
        BusyApiStatusKind.error => YaruInfoType.danger,
      },
      subtitle: Text(message),
    );
  }
}

Color busyApiDialogSurfaceColor(BuildContext context) {
  return DialogTheme.of(context).backgroundColor ??
      BusyApiSurfaceColors.of(context).dialog;
}

class BusyApiEditorHeader extends StatelessWidget {
  const BusyApiEditorHeader({
    super.key,
    required this.title,
    required this.cancelLabel,
    required this.saveLabel,
    required this.onCancel,
    required this.onSave,
    this.saving = false,
    this.cancelEnabled = true,
    this.cancelKey,
    this.saveKey,
  });

  final String title;
  final String cancelLabel;
  final String saveLabel;
  final VoidCallback onCancel;
  final VoidCallback? onSave;
  final bool saving;
  final bool cancelEnabled;
  final Key? cancelKey;
  final Key? saveKey;

  @override
  Widget build(BuildContext context) {
    final actionStyle = ButtonStyle(
      textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.titleSmall),
    );
    return Padding(
      padding: const EdgeInsets.all(BusyApiSpacing.headerInset),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              heightFactor: 1,
              child: BusyApiPushButton.standard(
                key: cancelKey,
                onPressed: cancelEnabled ? onCancel : null,
                style: actionStyle,
                child: Text(cancelLabel, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              heightFactor: 1,
              child: BusyApiPushButton.suggested(
                key: saveKey,
                onPressed: onSave,
                style: actionStyle,
                child: saving
                    ? const ExcludeSemantics(
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Text(saveLabel, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BusyApiEditorScrollBody extends StatelessWidget {
  const BusyApiEditorScrollBody({
    super.key,
    required this.child,
    this.maxWidth = 640,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return YaruScrollViewUndershoot.builder(
      endUndershoot: false,
      builder: (context, controller) => BusyApiClamp(
        maxWidth: maxWidth,
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.fromLTRB(
          BusyApiSpacing.lg,
          BusyApiSpacing.headerInset,
          BusyApiSpacing.lg,
          0,
        ),
        controller: controller,
        child: child,
      ),
    );
  }
}

class BusyApiModalEditorScaffold extends StatelessWidget {
  const BusyApiModalEditorScaffold({
    super.key,
    required this.title,
    required this.cancelLabel,
    required this.saveLabel,
    required this.onCancel,
    required this.onSave,
    required this.children,
    this.saving = false,
    this.cancelEnabled = true,
    this.contentMaxWidth = 640,
    this.cancelKey,
    this.saveKey,
  });

  final String title;
  final String cancelLabel;
  final String saveLabel;
  final VoidCallback onCancel;
  final VoidCallback? onSave;
  final bool saving;
  final bool cancelEnabled;
  final double contentMaxWidth;
  final List<Widget> children;
  final Key? cancelKey;
  final Key? saveKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BusyApiEditorHeader(
            title: title,
            cancelLabel: cancelLabel,
            saveLabel: saveLabel,
            onCancel: onCancel,
            onSave: onSave,
            saving: saving,
            cancelEnabled: cancelEnabled,
            cancelKey: cancelKey,
            saveKey: saveKey,
          ),
          Flexible(
            child: BusyApiEditorScrollBody(
              maxWidth: contentMaxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BusyApiDialogTitleBar extends StatelessWidget {
  const BusyApiDialogTitleBar({
    super.key,
    this.title,
    this.centerTitle = true,
    this.closeSemanticLabel,
    this.closable = true,
    this.showDividerInHighContrast = true,
  });

  final Widget? title;
  final bool centerTitle;
  final String? closeSemanticLabel;
  final bool closable;
  final bool showDividerInHighContrast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BusyApiSurfaceColors.of(context);
    final dialogSurface = busyApiDialogSurfaceColor(context);
    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(
          backgroundColor: dialogSurface,
          surfaceTintColor: dialogSurface,
          shadowColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      child: YaruDialogTitleBar(
        title: title,
        centerTitle: centerTitle,
        isClosable: closable,
        isActive: true,
        backgroundColor: dialogSurface,
        border: showDividerInHighContrast && theme.colorScheme.isHighContrast
            ? BorderSide(color: colors.divider)
            : BorderSide.none,
        closeSemanticLabel: closeSemanticLabel,
        heroTag: null,
      ),
    );
  }
}

class BusyApiDialogShell extends StatelessWidget {
  const BusyApiDialogShell({
    super.key,
    required this.title,
    required this.children,
    this.maxWidth = BusyApiSizes.dialog,
    this.header,
    this.actions = const [],
    this.closable = true,
  });

  final String title;
  final List<Widget> children;
  final double maxWidth;
  final Widget? header;
  final List<Widget> actions;
  final bool closable;

  @override
  Widget build(BuildContext context) {
    final dialogSurface = busyApiDialogSurfaceColor(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: BusyApiSurfaceScope(
        role: BusyApiSurfaceRole.dialog,
        child: Dialog(
          backgroundColor: dialogSurface,
          surfaceTintColor: dialogSurface,
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header ??
                    BusyApiDialogTitleBar(
                      title: Text(title),
                      closable: closable,
                    ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(BusyApiSpacing.lg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(BusyApiSpacing.lg),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: BusyApiSpacing.sm,
                      overflowSpacing: BusyApiSpacing.sm,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Semantic desktop push-button roles backed by real Yaru-themed controls.
abstract final class BusyApiPushButton {
  static FilledButton standard({
    required Widget child,
    required VoidCallback? onPressed,
    ButtonStyle? style,
    FocusNode? focusNode,
    bool autofocus = false,
    WidgetStatesController? statesController,
    Key? key,
  }) {
    return FilledButton(
      key: key,
      onPressed: onPressed,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      statesController: statesController,
      child: child,
    );
  }

  static FilledButton standardIcon({
    required Widget icon,
    required Widget label,
    required VoidCallback? onPressed,
    ButtonStyle? style,
    FocusNode? focusNode,
    bool autofocus = false,
    WidgetStatesController? statesController,
    Key? key,
  }) {
    return FilledButton.icon(
      key: key,
      onPressed: onPressed,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      statesController: statesController,
      icon: icon,
      label: label,
    );
  }

  static ElevatedButton suggested({
    required Widget child,
    required VoidCallback? onPressed,
    ButtonStyle? style,
    FocusNode? focusNode,
    bool autofocus = false,
    WidgetStatesController? statesController,
    Key? key,
  }) {
    return ElevatedButton(
      key: key,
      onPressed: onPressed,
      style: style,
      focusNode: focusNode,
      autofocus: autofocus,
      statesController: statesController,
      child: child,
    );
  }

  static ElevatedButton destructive({
    required BuildContext context,
    required Widget child,
    required VoidCallback? onPressed,
    ButtonStyle? style,
    FocusNode? focusNode,
    bool autofocus = false,
    WidgetStatesController? statesController,
    Key? key,
  }) {
    return ElevatedButton(
      key: key,
      onPressed: onPressed,
      style: _destructiveButtonStyle(context).merge(style),
      focusNode: focusNode,
      autofocus: autofocus,
      statesController: statesController,
      child: child,
    );
  }
}

class BusyApiDialogButton extends StatelessWidget {
  const BusyApiDialogButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.suggested = false,
    this.destructive = false,
  }) : assert(!suggested || !destructive);

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool suggested;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final child = _BusyApiDialogButtonContent(label: label, icon: icon);
    if (destructive) {
      return BusyApiPushButton.destructive(
        context: context,
        onPressed: onPressed,
        child: child,
      );
    }
    if (suggested) {
      return BusyApiPushButton.suggested(onPressed: onPressed, child: child);
    }
    return BusyApiPushButton.standard(onPressed: onPressed, child: child);
  }
}

ButtonStyle _destructiveButtonStyle(BuildContext context) {
  final theme = Theme.of(context);
  final colors = BusyApiSurfaceColors.of(context);
  Color? background(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled)
      ? colors.disabledControl
      : BusyApiDestructiveButtonStyle.background(theme);
  Color? foreground(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled)
      ? colors.disabledForeground
      : BusyApiDestructiveButtonStyle.foreground(theme);
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith(background),
    foregroundColor: WidgetStateProperty.resolveWith(foreground),
    iconColor: WidgetStateProperty.resolveWith(foreground),
  );
}

class _BusyApiDialogButtonContent extends StatelessWidget {
  const _BusyApiDialogButtonContent({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final icon = this.icon;
    if (icon == null) {
      return Center(widthFactor: 1, child: text);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: BusyApiSizes.iconSm),
        const SizedBox(width: BusyApiSpacing.sm),
        Flexible(child: text),
      ],
    );
  }
}

class BusyApiFloatingTextEntryGroup extends StatelessWidget {
  const BusyApiFloatingTextEntryGroup({super.key, required this.children})
    : assert(children.length > 1);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) const SizedBox(height: BusyApiSpacing.sm),
            children[index],
          ],
        ],
      ),
    );
  }
}

class BusyApiFloatingTextEntry extends StatelessWidget {
  const BusyApiFloatingTextEntry({
    super.key,
    required this.label,
    required this.controller,
    this.errorText,
    this.hintText,
    this.enabled = true,
    this.autofocus = false,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.textInputAction,
    this.textDirection,
    this.textStyle,
    this.onSubmitted,
  }) : assert(minLines > 0),
       assert(maxLines >= minLines);

  final String label;
  final TextEditingController controller;
  final String? errorText;
  final String? hintText;
  final bool enabled;
  final bool autofocus;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final TextInputAction? textInputAction;
  final TextDirection? textDirection;
  final TextStyle? textStyle;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: keyboardType,
      minLines: minLines,
      maxLines: maxLines,
      textInputAction: textInputAction,
      textDirection: textDirection,
      style: textStyle,
      onFieldSubmitted: enabled ? onSubmitted : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        errorText: errorText,
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: BusyApiInsets.sectionLabel,
      child: Semantics(
        header: true,
        child: Text(text, style: busyApiSectionHeaderStyle(context)),
      ),
    );
  }
}
