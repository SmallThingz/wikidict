#pragma once

#include "CompiledContent.hpp"
#include "SemanticHtml.hpp"
#include <QPointer>
#include <QColor>
#include <QMargins>
#include <QTextCursor>
#include <QTextDocumentFragment>
#include <QTextFrame>
#include <QTextTable>
#include <QScopeGuard>
#include <limits>
#include <algorithm>

namespace FlowConstruction {
inline const QString scheme = QStringLiteral("wikidict-flow");
inline constexpr int sourceRunProperty = SemanticHtml::sourceRunProperty;

// The HTML is imported as one fragment. Source-run metadata records its actual
// imported ranges; it never replaces source characters with projected offsets.
struct Rendered { QString html; QJsonArray parts; };
struct ContainerLineInput {
    enum class Mode { Inherit, Normal, Multiplier, Length };
    Mode mode = Mode::Inherit;
    qreal value = 0; // Multiplier remains unitless; Length is normal-body CSS px.
};
struct RenderContext {
    QString language;
    QString alignment;
    qreal pointSize = 0;
    qreal normalBodyEm = 0;
    qreal legacyVerticalScale = 1;
    bool containerTypography = false;
    ContainerLineInput containerLineHeight;
    QColor inheritedInk;
    QJsonObject captionLinkPaint;
    bool computedCellTraits = false;
    bool cellLineInheritance = false;
    int contentDepth = 0;
    bool inReference = false;
    QHash<QString, bool> inlineTableAudioOwners;
    QHash<QString, bool> inlineTableImageOwners;
    bool languageKnown = false;
    bool zeroFontContext = false;
    // True only while rendering children of a real compiled Scope owner.
    bool typedScopeOwnsIsolation = false;
};

// Typed inputs for the existing native layout owner. These are authored size
// requests in CSS pixels, not used rectangles or glyph ink. In particular,
// zero width and an empty child array cannot be replaced with intrinsic text.
struct ContainerWidthInput {
    enum class Mode { Auto, Length, FitContent, None };
    Mode mode = Mode::Auto;
    bool authored = false;
    qreal requested = 0; // Meaningful only for Length, before box-sizing.
};
struct ContainerInputs {
    QJsonObject source;
    QJsonObject effectiveStyle;
    qreal rootViewportCssPixels = 0;
    qreal containingContentCssPixels = 0;
    qreal normalBodyCssPixels = 0;
    bool screenActive = false;
    ContainerWidthInput width;
    ContainerWidthInput maximumWidth;
    ContainerLineInput lineHeight;
    bool relativeAuto = false;
    bool localScrollport = false;
    int columnCount = 0;
    qreal columnGap = 0;
    bool heightAuthored = false;
    qreal height = 0;
    bool minimumHeightAuthored = false;
    qreal minimumHeight = 0;
    struct BorderEdge { int style = 0; qreal width = 0; QColor color; };
    BorderEdge borderEdges[4]; // top, right, bottom, left
    bool physicalEdges = false;
    QMarginsF margins;
    bool marginValuesAuthored = false;
    bool autoMargins[4] = {}; // top, right, bottom, left; resolved only by the native owner
    QMarginsF padding;
    qreal borderWidth = 0;
    QColor borderColor;
    QColor background; // Invalid is inherited/unset; transparent is a real color.
    QString layout = QStringLiteral("flow");
    QString alignItems = QStringLiteral("stretch");
    QString floatSide;
    QString clear = QStringLiteral("none");
    QString boxSizing = QStringLiteral("content_box");
    QString textAlignment;
    bool flexNone = false;
    bool separateFormattingContext = false;
};
inline ContainerInputs containerInputs(const QJsonObject &containerBlock, qreal rootViewportCssPixels,
                                       qreal containingContentCssPixels, qreal normalBodyCssPixels,
                                       bool effectiveDark) {
    const auto owned = CompiledContent::containerBlock(containerBlock);
    CompiledContent::require(std::isfinite(rootViewportCssPixels) && rootViewportCssPixels >= 0
        && std::isfinite(containingContentCssPixels) && containingContentCssPixels >= 0
        && std::isfinite(normalBodyCssPixels) && normalBodyCssPixels > 0);
    ContainerInputs result;
    result.source = containerBlock;
    result.rootViewportCssPixels = rootViewportCssPixels;
    result.containingContentCssPixels = containingContentCssPixels;
    result.normalBodyCssPixels = normalBodyCssPixels;
    auto style = CompiledContent::containerStyle(owned.value(QStringLiteral("style")));
    const auto screen = style.value(QStringLiteral("screen_max_width"));
    if (CompiledContent::present(screen) && rootViewportCssPixels <= screen.toObject().value(QStringLiteral("max_width_px")).toDouble()) {
        result.screenActive = true;
        for (const auto &key : {QStringLiteral("width"), QStringLiteral("max_width"), QStringLiteral("box_sizing"), QStringLiteral("line_height")})
            if (CompiledContent::present(screen.toObject().value(key))) style.insert(key, screen.toObject().value(key));
    }
    result.effectiveStyle = style;
    const auto length = [&](const QJsonValue &value) {
        const auto spec = value.toObject();
        const auto unit = spec.value(QStringLiteral("unit")).toString();
        const qreal authored = spec.value(QStringLiteral("value")).toDouble();
        const qreal resolved = unit == QStringLiteral("em") ? authored * normalBodyCssPixels
            : unit == QStringLiteral("percent") ? (authored / 100) * containingContentCssPixels : authored;
        CompiledContent::require(std::isfinite(resolved) && resolved >= 0);
        return resolved;
    };
    const auto edges = [&](const QJsonValue &value) {
        if (!CompiledContent::present(value)) return QMarginsF();
        const auto spec = value.toObject();
        return QMarginsF(length(spec.value(QStringLiteral("left"))), length(spec.value(QStringLiteral("top"))),
                         length(spec.value(QStringLiteral("right"))), length(spec.value(QStringLiteral("bottom"))));
    };
    const auto width = [&](const QJsonValue &value, bool maximum) {
        ContainerWidthInput input;
        input.mode = maximum ? ContainerWidthInput::Mode::None : ContainerWidthInput::Mode::Auto;
        if (!CompiledContent::present(value)) return input;
        input.authored = true;
        const auto spec = value.toObject();
        if (spec.contains(QStringLiteral("length"))) { input.mode = ContainerWidthInput::Mode::Length; input.requested = length(spec.value(QStringLiteral("length"))); }
        else if (spec.contains(QStringLiteral("fit_content"))) input.mode = ContainerWidthInput::Mode::FitContent;
        return input;
    };
    const auto color = [&](const QJsonValue &value) {
        if (!CompiledContent::present(value)) return QColor();
        const auto spec = value.toObject();
        if (spec.contains(QStringLiteral("transparent"))) return QColor(Qt::transparent);
        if (spec.contains(QStringLiteral("rgb"))) return QColor(spec.value(QStringLiteral("rgb")).toString());
        return QColor(spec.value(QStringLiteral("light_dark")).toObject()
            .value(effectiveDark ? QStringLiteral("dark") : QStringLiteral("light")).toString());
    };
    result.width = width(style.value(QStringLiteral("width")), false);
    result.maximumWidth = width(style.value(QStringLiteral("max_width")), true);
    result.relativeAuto = CompiledContent::present(style.value(QStringLiteral("positioning")));
    result.localScrollport = style.value(QStringLiteral("overflow")) == QStringLiteral("auto");
    const auto columns = style.value(QStringLiteral("columns"));
    if (CompiledContent::present(columns)) {
        result.columnCount = columns.toObject().value(QStringLiteral("count")).toInt();
        result.columnGap = length(columns.toObject().value(QStringLiteral("gap")));
    }
    result.heightAuthored = CompiledContent::present(style.value(QStringLiteral("height")));
    if (result.heightAuthored) result.height = length(style.value(QStringLiteral("height")));
    result.minimumHeightAuthored = CompiledContent::present(style.value(QStringLiteral("min_height")));
    if (result.minimumHeightAuthored) result.minimumHeight = length(style.value(QStringLiteral("min_height")));
    if (CompiledContent::present(style.value(QStringLiteral("margins")))) {
        const auto spec = style.value(QStringLiteral("margins")).toObject();
        const auto signedLength = [&](const QString &side) {
            const auto value = spec.value(side).toObject();
            const qreal result = value.value(QStringLiteral("value")).toDouble()
                * (value.value(QStringLiteral("unit")) == QStringLiteral("em") ? normalBodyCssPixels : 1);
            CompiledContent::require(std::isfinite(result)); return result;
        };
        result.margins = QMarginsF(signedLength(QStringLiteral("left")), signedLength(QStringLiteral("top")),
            signedLength(QStringLiteral("right")), signedLength(QStringLiteral("bottom")));
    }
    result.marginValuesAuthored = CompiledContent::present(style.value(QStringLiteral("margin_values")));
    if (result.marginValuesAuthored) {
        const auto spec = style.value(QStringLiteral("margin_values")).toObject();
        const QString names[] = {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
        qreal resolved[4] = {};
        for (int i = 0; i < 4; ++i) {
            const auto tagged = spec.value(names[i]).toObject();
            result.autoMargins[i] = tagged.contains(QStringLiteral("auto"));
            if (!result.autoMargins[i]) {
                const auto value = tagged.value(QStringLiteral("length")).toObject();
                resolved[i] = value.value(QStringLiteral("value")).toDouble()
                    * (value.value(QStringLiteral("unit")) == QStringLiteral("em") ? normalBodyCssPixels : 1);
                CompiledContent::require(std::isfinite(resolved[i]));
            }
        }
        result.margins = QMarginsF(resolved[3], resolved[0], resolved[1], resolved[2]);
    }
    result.padding = edges(style.value(QStringLiteral("padding")));
    result.background = color(style.value(QStringLiteral("background")));
    const auto border = style.value(QStringLiteral("border")).toObject();
    if (border.contains(QStringLiteral("solid"))) {
        const auto solid = border.value(QStringLiteral("solid")).toObject();
        result.borderWidth = length(solid.value(QStringLiteral("width")));
        result.borderColor = color(solid.value(QStringLiteral("color")));
        for (auto &edge : result.borderEdges) edge = {2, result.borderWidth, result.borderColor};
    } else if (border.contains(QStringLiteral("edges"))) {
        result.physicalEdges = true;
        const auto spec = border.value(QStringLiteral("edges")).toObject();
        const QString names[] = {QStringLiteral("top"), QStringLiteral("right"), QStringLiteral("bottom"), QStringLiteral("left")};
        for (int i = 0; i < 4; ++i) {
            const auto edge = spec.value(names[i]).toObject();
            auto &out = result.borderEdges[i];
            out.style = edge.contains(QStringLiteral("hidden")) ? 1 : edge.contains(QStringLiteral("solid")) ? 2
                : edge.contains(QStringLiteral("dotted")) ? 3 : 0;
            if (out.style >= 2) {
                const auto line = edge.value(out.style == 2 ? QStringLiteral("solid") : QStringLiteral("dotted")).toObject();
                out.width = length(line.value(QStringLiteral("width")));
                out.color = color(line.value(QStringLiteral("color")));
            }
        }
    }
    result.physicalEdges = result.physicalEdges || result.padding.top() != result.padding.right()
        || result.padding.top() != result.padding.bottom() || result.padding.top() != result.padding.left();
    const auto line = style.value(QStringLiteral("line_height"));
    if (CompiledContent::present(line)) {
        const auto spec = line.toObject();
        if (spec.contains(QStringLiteral("normal"))) result.lineHeight.mode = ContainerLineInput::Mode::Normal;
        else if (spec.contains(QStringLiteral("multiplier"))) {
            result.lineHeight.mode = ContainerLineInput::Mode::Multiplier;
            result.lineHeight.value = spec.value(QStringLiteral("multiplier")).toDouble();
        } else {
            result.lineHeight.mode = ContainerLineInput::Mode::Length;
            result.lineHeight.value = length(spec.value(QStringLiteral("length")));
        }
    }
    const auto stringOr = [&](const QString &key, const QString &fallback) {
        return CompiledContent::present(style.value(key)) ? style.value(key).toString() : fallback;
    };
    result.layout = stringOr(QStringLiteral("layout"), result.layout);
    result.alignItems = stringOr(QStringLiteral("align_items"), result.alignItems);
    result.floatSide = stringOr(QStringLiteral("float_side"), {});
    result.clear = stringOr(QStringLiteral("clear"), result.clear);
    result.boxSizing = stringOr(QStringLiteral("box_sizing"), result.boxSizing);
    result.textAlignment = stringOr(QStringLiteral("text_align"), {});
    result.flexNone = CompiledContent::present(style.value(QStringLiteral("flex_item")));
    result.separateFormattingContext = result.localScrollport || !result.floatSide.isEmpty() || result.layout == QStringLiteral("flex_row");
    return result;
}

// This is the native policy's deliberately bounded first materialization.
// Preserve unsupported authored fields as an error instead of approximating them.
inline constexpr int containerPolicyProperty = QTextFormat::UserProperty + 0x57e0;
inline constexpr int containerClearProperty = QTextFormat::UserProperty + 0x57e1;
inline constexpr int containerSourceProperty = QTextFormat::UserProperty + 0x57e2;
inline constexpr int containerStorageProperty = QTextFormat::UserProperty + 0x57e3;
inline constexpr int containerTypographyProperty = QTextFormat::UserProperty + 0x57e4;
inline constexpr int containerColumnsProperty = QTextFormat::UserProperty + 0x57e5;
inline constexpr int containerPositioningProperty = QTextFormat::UserProperty + 0x57e6;
inline constexpr int containerMinimumHeightProperty = QTextFormat::UserProperty + 0x57e7;
inline constexpr int containerPhysicalEdgesProperty = QTextFormat::UserProperty + 0x57e8;
inline constexpr int containerMarginsProperty = QTextFormat::UserProperty + 0x57e9;
inline constexpr int containerAutoMarginsProperty = QTextFormat::UserProperty + 0x57ea;
inline constexpr int containerScrollportProperty = QTextFormat::UserProperty + 0x57eb;
inline void columnsContent(const QJsonObject &owned, bool allowTableCaptionMedia = false) {
    const auto children = owned.value(QStringLiteral("blocks")).toArray();
    for (const auto &childValue : children) {
        const auto child = CompiledContent::object(childValue);
        const auto kind = child.value(QStringLiteral("kind")).toString();
        CompiledContent::require(kind == QStringLiteral("paragraph") || kind == QStringLiteral("list_item")
            || kind == QStringLiteral("list_detail") || kind == QStringLiteral("definition"));
        for (const auto &key : {QStringLiteral("container"), QStringLiteral("table"), QStringLiteral("figure"), QStringLiteral("feature")})
            CompiledContent::require(!CompiledContent::present(child.value(key)));
        CompiledContent::require(!CompiledContent::present(child.value(QStringLiteral("style")))
            || (child.value(QStringLiteral("style")).isObject() && child.value(QStringLiteral("style")).toObject().isEmpty()));
    }
    auto spans = [allowTableCaptionMedia](const QJsonArray &values, const CompiledContent::Context &context) {
        for (const auto &value : values) {
            const auto span = CompiledContent::object(value);
            const auto kind = span.value(QStringLiteral("kind")).toString();
            CompiledContent::require(kind == QStringLiteral("text") || kind == QStringLiteral("link")
                || kind == QStringLiteral("external_link") || kind == QStringLiteral("line_break"));
            if (CompiledContent::present(span.value(QStringLiteral("image")))) {
                // Only a direct media visit of the typed Figure enters the
                // relative group. Its complete semantic/native validation still
                // precedes commit; equal ordinary/caption images remain refused.
                const auto &figure = context.figureMediaOwner;
                CompiledContent::require(allowTableCaptionMedia && !figure.isEmpty()
                    && figure.value(QStringLiteral("table_caption_layout")).isObject()
                    && figure.value(QStringLiteral("table_caption_layout")).toObject().value(QStringLiteral("collapse")) == QStringLiteral("collapse")
                    && !CompiledContent::present(figure.value(QStringLiteral("missing_content")))
                    && figure.value(QStringLiteral("image_span")).isObject()
                    && figure.value(QStringLiteral("image_span")).toObject() == span);
            }
        }
    };
    CompiledContent::Walker<decltype(spans)> walker(spans, CompiledContent::TableSpans::VisibleBody);
    walker.blocks(children);
}

inline QTextFrameFormat plainContainerFormat(const QJsonObject &block, qreal normalBodyCssPixels, bool effectiveDark) {
    const auto owned = CompiledContent::containerBlock(block);
    const auto input = containerInputs(block, 0, 1, normalBodyCssPixels, effectiveDark);
    const auto &style = input.effectiveStyle;
    CompiledContent::require(!CompiledContent::present(style.value(QStringLiteral("screen_max_width")))
        && input.layout == QStringLiteral("flow") && input.floatSide.isEmpty() && !input.flexNone
        && (input.maximumWidth.mode == ContainerWidthInput::Mode::None || input.marginValuesAuthored || input.localScrollport)
        && input.width.mode != ContainerWidthInput::Mode::FitContent);
    const bool adjoining = input.margins.top() != 0 || input.margins.bottom() != 0
        || input.margins.left() < 0 || input.margins.right() < 0 || input.marginValuesAuthored || input.localScrollport;
    CompiledContent::require(!adjoining || !input.columnCount);
    QTextFrameFormat format;
    format.setProperty(containerPolicyProperty, QStringLiteral("wikidict.plain-container/1"));
    format.setProperty(containerSourceProperty, QJsonDocument(block).toJson(QJsonDocument::Compact));
    if (input.localScrollport) {
        CompiledContent::require(!input.heightAuthored && !input.minimumHeightAuthored && !input.columnCount
            && !input.relativeAuto && !input.marginValuesAuthored && input.width.mode == ContainerWidthInput::Mode::Auto
            && input.margins.top() >= 0 && input.margins.right() >= 0 && input.margins.bottom() >= 0 && input.margins.left() >= 0
            && style.value(QStringLiteral("max_width")).toObject().value(QStringLiteral("length")).toObject()
                .value(QStringLiteral("unit")) != QStringLiteral("percent"));
        format.setProperty(containerScrollportProperty, QStringLiteral("wikidict.container-scrollport/1"));
    }
    if (input.relativeAuto) {
        CompiledContent::require(!input.columnCount);
        columnsContent(owned, true);
        for (const auto &child : owned.value(QStringLiteral("blocks")).toArray())
            CompiledContent::require(child.toObject().value(QStringLiteral("kind")) == QStringLiteral("paragraph"));
        format.setProperty(containerPositioningProperty, QStringLiteral("wikidict.relative-auto/1"));
    }
    if (input.columnCount) {
        CompiledContent::require(!input.heightAuthored && !input.minimumHeightAuthored && input.width.mode == ContainerWidthInput::Mode::Auto);
        columnsContent(owned);
        format.setProperty(containerColumnsProperty, QVariantMap{{QStringLiteral("count"), input.columnCount},
            {QStringLiteral("gap"), input.columnGap}});
    }
    const int clear = input.clear == QStringLiteral("left") ? 1 : input.clear == QStringLiteral("right") ? 2
        : input.clear == QStringLiteral("both") ? 3 : 0;
    format.setProperty(containerClearProperty, clear);
    format.setPosition(QTextFrameFormat::InFlow);
    format.setMargin(0);
    if (adjoining) {
        format.setProperty(containerMarginsProperty, QVariantMap{
            {QStringLiteral("edges"), QVariantList{input.margins.top(), input.margins.right(), input.margins.bottom(), input.margins.left()}},
            {QStringLiteral("auto_width"), input.marginValuesAuthored || input.width.mode == ContainerWidthInput::Mode::Auto}});
    } else { format.setLeftMargin(input.margins.left()); format.setRightMargin(input.margins.right()); }
    format.setPadding(input.padding.top());
    format.setBorder(input.borderWidth);
    format.setBorderStyle(input.borderWidth > 0 ? QTextFrameFormat::BorderStyle_Solid : QTextFrameFormat::BorderStyle_None);
    if (input.borderColor.isValid()) format.setBorderBrush(input.borderColor);
    if (input.background.isValid()) format.setBackground(input.background);
    if (input.physicalEdges) {
        QVariantList borders;
        for (const auto &edge : input.borderEdges)
            borders.append(QVariantMap{{QStringLiteral("style"), edge.style}, {QStringLiteral("width"), edge.width},
                {QStringLiteral("color"), edge.color.isValid() ? edge.color : QColor(Qt::transparent)}});
        format.setProperty(containerPhysicalEdgesProperty, QVariantMap{
            {QStringLiteral("padding"), QVariantList{input.padding.top(), input.padding.right(), input.padding.bottom(), input.padding.left()}},
            {QStringLiteral("borders"), borders}});
        format.setPadding(0); format.setBorder(0); format.setBorderStyle(QTextFrameFormat::BorderStyle_None);
    }
    const qreal insets = input.padding.left() + input.padding.right() + input.borderEdges[1].width + input.borderEdges[3].width;
    const qreal verticalInsets = input.padding.top() + input.padding.bottom() + input.borderEdges[0].width + input.borderEdges[2].width;
    if (input.minimumHeightAuthored) {
        const qreal floor = input.boxSizing == QStringLiteral("content_box") ? input.minimumHeight
            : qMax(qreal(0), input.minimumHeight - verticalInsets);
        format.setProperty(containerMinimumHeightProperty, QVariantMap{{QStringLiteral("content"), floor},
            {QStringLiteral("computed"), input.minimumHeight}});
    }
    if (input.heightAuthored) {
        const qreal content = input.boxSizing == QStringLiteral("content_box") ? input.height
            : qMax(qreal(0), input.height - verticalInsets);
        const qreal outer = content + verticalInsets;
        CompiledContent::require(std::isfinite(outer) && outer >= 0);
        format.setHeight(QTextLength(QTextLength::FixedLength, outer));
    }
    const qreal margins = input.margins.left() + input.margins.right();
    if (input.marginValuesAuthored || input.localScrollport) {
        const auto nativeWidth = [&](const QString &key, const QString &absent) {
            const auto width = style.value(key).toObject();
            const auto length = width.value(QStringLiteral("length")).toObject();
            if (length.isEmpty()) return QVariantMap{{QStringLiteral("unit"), absent}, {QStringLiteral("value"), qreal(0)}};
            const auto unit = length.value(QStringLiteral("unit"));
            const qreal value = length.value(QStringLiteral("value")).toDouble()
                * (unit == QStringLiteral("em") ? normalBodyCssPixels : 1);
            CompiledContent::require(std::isfinite(value) && value >= 0);
            return QVariantMap{{QStringLiteral("unit"), unit == QStringLiteral("percent") ? QStringLiteral("percent") : QStringLiteral("fixed")},
                {QStringLiteral("value"), value}};
        };
        format.setProperty(containerAutoMarginsProperty, QVariantMap{
            {QStringLiteral("autos"), QVariantList{input.autoMargins[0], input.autoMargins[1], input.autoMargins[2], input.autoMargins[3]}},
            {QStringLiteral("width"), nativeWidth(QStringLiteral("width"), QStringLiteral("auto"))},
            {QStringLiteral("max_width"), nativeWidth(QStringLiteral("max_width"), QStringLiteral("none"))},
            {QStringLiteral("border_box"), input.boxSizing == QStringLiteral("border_box")}});
        format.setWidth(QTextLength(QTextLength::PercentageLength, 100));
        return format;
    }
    const auto authored = style.value(QStringLiteral("width")).toObject().value(QStringLiteral("length")).toObject();
    if (input.width.mode == ContainerWidthInput::Mode::Auto) {
        format.setWidth(QTextLength(QTextLength::PercentageLength, 100));
    } else if (authored.value(QStringLiteral("unit")) == QStringLiteral("percent")) {
        // The native percentage is the outer frame width. Nonzero insets need
        // a separate typed content-box percentage hook; never resolve at import.
        CompiledContent::require(insets == 0 && margins == 0);
        const qreal percentage = authored.value(QStringLiteral("value")).toDouble();
        CompiledContent::require(percentage > 0 || owned.value(QStringLiteral("blocks")).toArray().isEmpty());
        format.setWidth(QTextLength(QTextLength::PercentageLength, percentage));
    } else {
        const qreal content = input.boxSizing == QStringLiteral("content_box") ? input.width.requested
            : qMax(qreal(0), input.width.requested - insets);
        CompiledContent::require(content > 0 || owned.value(QStringLiteral("blocks")).toArray().isEmpty());
        const qreal outer = content + insets + (adjoining ? 0 : margins);
        CompiledContent::require(std::isfinite(outer) && outer >= 0);
        format.setWidth(QTextLength(QTextLength::FixedLength, outer));
    }
    return format;
}

template <typename InlineRenderer, typename FigureRenderer>
Rendered render(const QJsonArray &parts, CompiledContent::Depth depth, RenderContext context,
                InlineRenderer &inlineRenderer, FigureRenderer &figureRenderer, int &nextRun) {
    Rendered result;
    const auto allocateRun = [&] {
        CompiledContent::require(nextRun >= 0 && nextRun < std::numeric_limits<int>::max());
        return nextRun++;
    };
    for (const QJsonValue &value : parts) {
        const auto part = CompiledContent::object(value);
        const QString kind = part.value(QStringLiteral("kind")).toString();
        const auto spans = CompiledContent::array(part.value(QStringLiteral("spans")));
        if (kind == QStringLiteral("inline")) {
            CompiledContent::require(!CompiledContent::present(part.value(QStringLiteral("figure")))
                && !CompiledContent::present(part.value(QStringLiteral("scope"))));
            const int run = allocateRun();
            result.html += inlineRenderer(spans, run, context);
            result.parts.append(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("run"), run}});
        } else if (kind == QStringLiteral("figure")) {
            CompiledContent::require(spans.isEmpty() && !CompiledContent::present(part.value(QStringLiteral("scope"))));
            const int run = allocateRun();
            result.html += figureRenderer(CompiledContent::object(part.value(QStringLiteral("figure"))), run, context, depth);
            result.parts.append(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("run"), run}});
        } else {
            CompiledContent::require(kind == QStringLiteral("scope") && spans.isEmpty()
                && !CompiledContent::present(part.value(QStringLiteral("figure"))));
            const auto scope = CompiledContent::scope(part.value(QStringLiteral("scope")));
            auto nestedContext = context;
            nestedContext.typedScopeOwnsIsolation = true;
            if (!scope.value(QStringLiteral("language")).isNull()) {
                nestedContext.language = scope.value(QStringLiteral("language")).toString();
                nestedContext.languageKnown = true;
            }
            nestedContext.contentDepth = depth.nestedContent().content;
            const auto nested = render(scope.value(QStringLiteral("parts")).toArray(), depth.nestedContent(),
                nestedContext, inlineRenderer, figureRenderer, nextRun);
            result.html += nested.html;
            result.parts.append(QJsonObject{{QStringLiteral("kind"), kind},
                {QStringLiteral("mode"), scope.value(QStringLiteral("mode"))},
                {QStringLiteral("direction"), scope.value(QStringLiteral("resolved_direction"))},
                {QStringLiteral("language"), scope.value(QStringLiteral("language"))},
                {QStringLiteral("parts"), nested.parts}});
        }
    }
    return result;
}

inline QString placeholder(const QJsonObject &block, const Rendered &rendered, const RenderContext &context) {
    if (block.value(QStringLiteral("kind")) == QStringLiteral("container")) CompiledContent::containerBlock(block);
    else CompiledContent::require(CompiledContent::contentRole(block));
    QJsonObject metadata{{QStringLiteral("block"), block}, {QStringLiteral("html"), rendered.html},
        {QStringLiteral("parts"), rendered.parts}, {QStringLiteral("language"), context.language},
        {QStringLiteral("alignment"), context.alignment},
        {QStringLiteral("normal_body_em"), context.normalBodyEm},
        {QStringLiteral("legacy_vertical_scale"), context.legacyVerticalScale},
        {QStringLiteral("context_points"), context.pointSize}};
    if (context.containerTypography) {
        const auto mode = context.containerLineHeight.mode;
        const QString kind = mode == ContainerLineInput::Mode::Multiplier ? QStringLiteral("multiplier")
            : mode == ContainerLineInput::Mode::Length ? QStringLiteral("length") : QStringLiteral("normal");
        const qreal cssPixels = context.zeroFontContext ? 0 : context.pointSize * QFontMetricsF(QFont()).fontDpi() / 72;
        metadata.insert(QStringLiteral("container_typography"), QJsonObject{{"kind", kind},
            {"value", context.containerLineHeight.value}, {"owner_px", cssPixels}});
        metadata.insert(QStringLiteral("owner_zero"), context.zeroFontContext);
        if (context.cellLineInheritance) metadata.insert(QStringLiteral("cell_line_inherited"), true);
    }
    const auto payload = QJsonDocument(metadata).toJson(QJsonDocument::Compact)
        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    // The caller supplies the existing block's role/prefix/indent exactly once.
    return QStringLiteral("<img src='%1:%2'>").arg(scheme, QString::fromLatin1(payload));
}

struct AuthoredBoundary {
    QTextCursor character;
    int sourceRun = -1;
    QTextBlockFormat precedingFormat;
    QTextBlockFormat followingFormat;
};
struct Paragraph {
    QTextCursor first;
    QTextBlockFormat intrinsicFormat;
    QTextCharFormat intrinsicCharacter;
};
struct Owner {
    QTextCursor first;
    QTextCursor prefixEnd;
    QTextCursor last;
    QJsonObject metadata;
    QTextBlockFormat roleFormat;
    QTextCharFormat roleCharacter;
    QVector<AuthoredBoundary> authoredBoundaries;
    QVector<QTextCursor> figureJoins;
    QVector<Paragraph> paragraphs;
};

inline QJsonObject decode(const QString &name) {
    const QUrl url(name);
    CompiledContent::require(url.scheme() == scheme);
    const auto encoded = url.path().toLatin1();
    const auto bytes = QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding | QByteArray::AbortOnBase64DecodingErrors);
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(bytes, &error);
    CompiledContent::require(error.error == QJsonParseError::NoError && document.isObject()
        && bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals) == encoded);
    const auto metadata = document.object();
    CompiledContent::require(metadata.value(QStringLiteral("block")).isObject()
        && metadata.value(QStringLiteral("html")).isString() && metadata.value(QStringLiteral("parts")).isArray()
        && metadata.value(QStringLiteral("language")).isString() && metadata.value(QStringLiteral("alignment")).isString());
    return metadata;
}

inline QVector<Owner> expand(QTextDocument *document, QVector<QPointer<QTextFrame>> *containers = nullptr, bool effectiveDark = false) {
    const QPointer<QTextDocument> guard(document);
    CompiledContent::require(guard);
    struct Pending { QTextCursor character; QJsonObject metadata; };
    QVector<Pending> pending;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
            const QString name = fragment.charFormat().toImageFormat().name();
            if (QUrl(name).scheme() != scheme) continue;
            CompiledContent::require(fragment.length() == 1);
            QTextCursor character(document); character.setPosition(fragment.position());
            character.setPosition(fragment.position() + 1, QTextCursor::KeepAnchor);
            pending.append({character, decode(name)});
        }
    }
    if (pending.isEmpty()) return {};
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    CompiledContent::require(guard && layout && document->documentLayout() == layout);
    CompiledContent::require(layout->property("_wikidictSourceProvenanceCapability").toString()
        == QStringLiteral("wikidict.source-provenance/1"));
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    CompiledContent::require(guard && layout && document->documentLayout() == layout);
    bool restored = false, finished = false;
    const auto restore = qScopeGuard([&] { if (!restored && guard) guard->setLayoutEnabled(enabled); });
    QTextCursor transaction(document); transaction.beginEditBlock();
    const auto finish = qScopeGuard([&] { if (!finished && guard) transaction.endEditBlock(); });
    QVector<Owner> owners;
    for (const auto &item : pending) {
        CompiledContent::require(guard);
        QTextCursor insertion = item.character;
        Owner owner;
        owner.metadata = item.metadata;
        owner.roleFormat = insertion.blockFormat();
        owner.roleCharacter = insertion.block().charFormat();
        owner.first = insertion;
        owner.first.clearSelection(); owner.first.setPosition(insertion.block().position());
        owner.first.setKeepPositionOnInsert(true);
        owner.prefixEnd = insertion;
        owner.prefixEnd.clearSelection(); owner.prefixEnd.setPosition(insertion.selectionStart());
        owner.prefixEnd.setKeepPositionOnInsert(true);
        QTextDocument temporary;
        QFont contextFont = insertion.charFormat().font().resolve(document->defaultFont());
        const auto typography = item.metadata.value(QStringLiteral("container_typography"));
        const bool typedFont = CompiledContent::present(typography);
        const auto cellHeightValue = item.metadata.value(QStringLiteral("cell_line_inherited"));
        CompiledContent::require(!CompiledContent::present(cellHeightValue) || (cellHeightValue.isBool() && cellHeightValue.toBool() && typedFont));
        const bool cellHeight = cellHeightValue.toBool();
        const bool zeroOwner = item.metadata.value(QStringLiteral("owner_zero")).toBool();
        if (typedFont) {
            const auto capability = layout->property("_wikidictContainerTypographyCapability");
            CompiledContent::require(capability.metaType().id() == QMetaType::QString
                && capability.toString() == QStringLiteral("wikidict.container-typography/1"));
            const qreal points = item.metadata.value(QStringLiteral("context_points")).toDouble(-1);
            CompiledContent::require(std::isfinite(points) && (zeroOwner ? points == 0 : points > 0));
            // Import positive child overrides in the ordinary family even when
            // the owner's own strut is zero. Zero spans have explicit metadata.
            if (!zeroOwner) contextFont.setPointSizeF(points);
        }
        temporary.setDefaultFont(contextFont);
        temporary.setDefaultTextOption(document->defaultTextOption());
        temporary.setDocumentMargin(0);
        SemanticHtml::setHtml(&temporary, item.metadata.value(QStringLiteral("html")).toString());
        CompiledContent::require(guard);
        if (typedFont) {
            const auto object = typography.toObject();
            CompiledContent::require(typography.isObject() && object.size() == 3
                && object.value(QStringLiteral("kind")).isString()
                && object.value(QStringLiteral("value")).isDouble()
                && object.value(QStringLiteral("owner_px")).isDouble());
            // JSON stores integral numbers as integers internally. The native
            // typography protocol requires explicit Double metrics, including 0.
            const QVariantMap policy{{QStringLiteral("kind"), object.value(QStringLiteral("kind")).toString()},
                {QStringLiteral("value"), object.value(QStringLiteral("value")).toDouble()},
                {QStringLiteral("owner_px"), object.value(QStringLiteral("owner_px")).toDouble()}};
            for (auto block = temporary.begin(); block.isValid(); block = block.next()) {
                QVector<QPair<QTextCursor, QTextCharFormat>> runs;
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto text = it.fragment(); if (!text.isValid()) continue;
                    auto format = text.charFormat(); format.setFont(format.font().resolve(contextFont));
                    QTextCursor run(&temporary); run.setPosition(text.position()); run.setPosition(text.position()+text.length(), QTextCursor::KeepAnchor);
                    runs.append(qMakePair(run, format));
                }
                for (auto &run : runs) run.first.setCharFormat(run.second);
                QTextCursor paragraph(block); auto strut = paragraph.blockCharFormat();
                QFont font = contextFont;
                if (zeroOwner) { font.setFamilies(QStringList{SemanticHtml::zeroFontFamilyName}); font.setStyleStrategy(QFont::NoFontMerging); }
                strut.setFont(font); paragraph.setBlockCharFormat(strut);
                auto format = paragraph.blockFormat();
                // These blocks belong to the fresh temporary document, not the
                // enclosing destination Cell. Keep a nearer Cell imported inside
                // this content; direct Container blocks receive their own height.
                if (!cellHeight && !SemanticHtml::cellLineHeightOwner(block) && !format.hasProperty(SemanticHtml::tableLineHeightProperty) && !format.hasProperty(QTextFormat::LineHeight))
                    format.setProperty(containerTypographyProperty, policy);
                paragraph.setBlockFormat(format);
            }
        }
        // Fragment copying retains explicit formats, not the temporary
        // document's default font. Keep inherited weight and tracking concrete
        // across this boundary, including markers expanded in a later pass.
        const QTextCharFormat inheritedCharacter = insertion.charFormat();
        if (inheritedCharacter.hasProperty(QTextFormat::FontLetterSpacing)
            || inheritedCharacter.hasProperty(QTextFormat::FontWeight)) {
            QVector<QPair<QTextCursor, QTextCharFormat>> inheritedRuns;
            for (auto block = temporary.begin(); block.isValid(); block = block.next()) {
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto text = it.fragment();
                    if (!text.isValid()) continue;
                    QTextCharFormat inherited;
                    if (inheritedCharacter.hasProperty(QTextFormat::FontLetterSpacing)
                        && !text.charFormat().hasProperty(QTextFormat::FontLetterSpacing)) {
                        inherited.setProperty(QTextFormat::FontLetterSpacing,
                            inheritedCharacter.property(QTextFormat::FontLetterSpacing));
                        inherited.setProperty(QTextFormat::FontLetterSpacingType,
                            inheritedCharacter.fontLetterSpacingType());
                    }
                    if (inheritedCharacter.hasProperty(QTextFormat::FontWeight)
                        && !text.charFormat().hasProperty(QTextFormat::FontWeight))
                        inherited.setProperty(QTextFormat::FontWeight,
                            inheritedCharacter.property(QTextFormat::FontWeight));
                    if (inherited.properties().isEmpty()) continue;
                    QTextCursor run(&temporary); run.setPosition(text.position());
                    run.setPosition(text.position() + text.length(), QTextCursor::KeepAnchor);
                    inheritedRuns.append(qMakePair(run, inherited));
                }
            }
            for (auto &run : inheritedRuns) run.first.mergeCharFormat(run.second);
        }
        const auto sourceFirst = temporary.begin();
        const QTextBlockFormat firstFormat = sourceFirst.blockFormat();
        const QTextCharFormat firstCharacter = sourceFirst.charFormat();
        const auto sourceBlock = item.metadata.value(QStringLiteral("block")).toObject();
        if (sourceBlock.value(QStringLiteral("kind")) == QStringLiteral("container")) {
            CompiledContent::require(containers && layout && document->documentLayout() == layout
                && layout->property("_wikidictPlainContainerCapability").toString() == QStringLiteral("wikidict.plain-container/1"));
            const auto owned = CompiledContent::containerBlock(sourceBlock);
            const qreal scale = item.metadata.value(QStringLiteral("legacy_vertical_scale")).toDouble();
            const qreal em = item.metadata.value(QStringLiteral("normal_body_em")).toDouble();
            CompiledContent::require(std::isfinite(scale) && scale > 0 && std::isfinite(em) && em > 0
                && item.metadata.value(QStringLiteral("parts")).toArray().isEmpty()
                && insertion.selectionEnd() - insertion.selectionStart() == 1
                && insertion.selectedText() == QString(QChar::ObjectReplacementCharacter)
                && insertion.block().position() == insertion.selectionStart() && insertion.block().length() == 2);
            const QPointer<QTextFrame> parent(insertion.currentFrame());
            auto format = plainContainerFormat(sourceBlock, em / scale, effectiveDark);
            const bool columns = format.hasProperty(containerColumnsProperty);
            const bool positioned = format.hasProperty(containerPositioningProperty);
            QPointer<QTextTable> containingTable(insertion.currentTable());
            int sourceRow = -1, sourceColumn = -1;
            if (containingTable) {
                const auto cell = containingTable->cellAt(insertion.position());
                const auto captionContent = [&] {
                    // currentTable() also reports an ancestor table through a
                    // Figure's real caption-content owner. Registration follows
                    // construction; native layout validates that current owner.
                    constexpr int figureOwner = QTextFormat::UserProperty + 0x57a0;
                    auto *content = parent.data();
                    while (content && content->frameFormat().stringProperty(containerPolicyProperty)
                            == QStringLiteral("wikidict.plain-container/1")
                            && content->frameFormat().position() == QTextFrameFormat::InFlow)
                        content = content->parentFrame();
                    auto *caption = content ? qobject_cast<QTextTable *>(content->parentFrame()) : nullptr;
                    auto *figure = caption ? caption->parentFrame() : nullptr;
                    const auto owned = [&](QTextFrame *candidate, const QString &role, bool helper) {
                        if (!candidate || candidate->document() != document
                            || document->object(candidate->objectIndex()) != candidate) return false;
                        const auto format = candidate->frameFormat();
                        const auto policy = format.property(figureOwner + 14);
                        return format.stringProperty(figureOwner) == QStringLiteral("wikidict.figure-layout/1")
                            && format.stringProperty(figureOwner + 4) == role
                            && policy.metaType().id() == QMetaType::QVariantMap
                            && policy.toMap().value(QStringLiteral("capability")).metaType().id() == QMetaType::QString
                            && policy.toMap().value(QStringLiteral("capability")).toString() == QStringLiteral("wikidict.figure-table-caption/4")
                            && (!helper || (figure && format.property(figureOwner + 8).metaType().id() == QMetaType::Int
                                && format.intProperty(figureOwner + 8) == figure->objectIndex()
                                && format.position() == QTextFrameFormat::InFlow));
                    };
                    if (caption != containingTable || !owned(content, QStringLiteral("caption-content"), true)
                        || !owned(caption, QStringLiteral("caption"), true) || !owned(figure, QStringLiteral("figure"), false)
                        || caption->rows() != 1 || caption->columns() != 1
                        || caption->childFrames().size() != 1 || caption->childFrames().first() != content
                        || figure->childFrames().size() != 2 || figure->childFrames().at(1) != caption) return false;
                    const auto metadata = figure->frameFormat().property(figureOwner + 3);
                    if (metadata.metaType().id() != QMetaType::QByteArray) return false;
                    QJsonParseError error;
                    const auto decoded = QJsonDocument::fromJson(metadata.toByteArray(), &error);
                    const auto source = decoded.object().value(QStringLiteral("figure")).toObject();
                    return error.error == QJsonParseError::NoError && decoded.isObject()
                        && source.value(QStringLiteral("caption_blocks")).isArray()
                        && source.value(QStringLiteral("table_caption_layout")).toObject()
                            .value(QStringLiteral("collapse")) == QStringLiteral("collapse");
                };
                const auto typedCell = [&] {
                    if (!cell.isValid() || !typedFont || !parent
                        || layout->property("_wikidictCellLineHeightCapability").toString()
                            != QStringLiteral("wikidict.cell-line-height/1")) return false;
                    // Keep the real nearest table and its cell coordinates. A
                    // nested undeclared cell may inherit a typed outer owner.
                    for (auto *frame = parent.data(); frame; frame = frame->parentFrame()) {
                        if (frame->document() != document || document->object(frame->objectIndex()) != frame)
                            return false;
                        if (auto *table = qobject_cast<QTextTable *>(frame)) {
                            if (table->format().stringProperty(SemanticHtml::tableBoxOwnerProperty)
                                    != QStringLiteral("wikidict.table-box/1")) return false;
                            const auto ownerCell = table->cellAt(insertion.position());
                            if (!ownerCell.isValid()) return false;
                            const auto value = ownerCell.format().property(SemanticHtml::cellLineHeightProperty);
                            if (value.isValid()) {
                                const auto policy = value.toMap();
                                return value.metaType().id() == QMetaType::QVariantMap && policy.size() == 6
                                    && policy.value(QStringLiteral("capability")).metaType().id() == QMetaType::QString
                                    && policy.value(QStringLiteral("capability")).toString() == QStringLiteral("wikidict.cell-line-height/1")
                                    && policy.value(QStringLiteral("font")).metaType().id() == QMetaType::QFont
                                    && policy.value(QStringLiteral("empty")).metaType().id() == QMetaType::Bool
                                    && !policy.value(QStringLiteral("empty")).toBool();
                            }
                            if (table->format().hasProperty(SemanticHtml::tableLineHeightProperty)) return false;
                        } else if (frame->frameFormat().stringProperty(containerPolicyProperty)
                                != QStringLiteral("wikidict.plain-container/1")
                            || frame->frameFormat().position() != QTextFrameFormat::InFlow) return false;
                    }
                    return false;
                };
                CompiledContent::require((columns || positioned || captionContent() || typedCell()) && cell.isValid());
                sourceRow = cell.row(); sourceColumn = cell.column();
            }
            if (!columns && !positioned) for (auto *ancestor = parent.data(); ancestor; ancestor = ancestor->parentFrame())
                if (qobject_cast<QTextTable *>(ancestor))
                    CompiledContent::require(layout->property("_wikidictContainerAdjoiningCapability").toString()
                        == QStringLiteral("wikidict.container-adjoining/1"));
            if (positioned) CompiledContent::require(layout->property("_wikidictContainerPositioningCapability").toString()
                == QStringLiteral("wikidict.relative-auto/1"));
            if (columns) {
                CompiledContent::require(layout->property("_wikidictContainerColumnsCapability").toString()
                    == QStringLiteral("wikidict.container-columns/1"));
                format.setLayoutDirection(insertion.blockFormat().layoutDirection());
            }
            if (format.height().type() == QTextLength::FixedLength)
                CompiledContent::require(layout->property("_wikidictContainerHeightCapability").toString()
                    == QStringLiteral("wikidict.container-height/1"));
            if (format.hasProperty(containerMinimumHeightProperty))
                CompiledContent::require(layout->property("_wikidictContainerMinimumHeightCapability").toString()
                    == QStringLiteral("wikidict.container-minimum-height/1"));
            if (format.hasProperty(containerPhysicalEdgesProperty))
                CompiledContent::require(layout->property("_wikidictPhysicalBorderCapability").toString()
                    == QStringLiteral("wikidict.physical-border/1"));
            if (format.hasProperty(containerMarginsProperty))
                CompiledContent::require(layout->property("_wikidictContainerAdjoiningCapability").toString()
                    == QStringLiteral("wikidict.container-adjoining/1"));
            if (format.hasProperty(containerScrollportProperty))
                CompiledContent::require(layout->property("_wikidictContainerScrollportCapability").toString()
                    == QStringLiteral("wikidict.container-scrollport/1")
                    && layout->property("_wikidictScrollportWidgetOwner").toBool());
            if (format.hasProperty(containerAutoMarginsProperty)) {
                CompiledContent::require(layout->property("_wikidictContainerAutoMarginsCapability").toString()
                    == QStringLiteral("wikidict.container-auto-margins/1"));
                const auto direction = insertion.blockFormat().layoutDirection();
                format.setLayoutDirection(direction == Qt::LayoutDirectionAuto
                    ? document->defaultTextOption().textDirection() : direction);
            }
            const QPointer<QTextFrame> frame(insertion.insertFrame(format));
            CompiledContent::require(guard && layout && document->documentLayout() == layout && parent && frame
                && frame->parentFrame() == parent);
            // Recover the exact authenticated ORC by fragment identity, without
            // grapheme navigation or cursor-adjacent character-format guesses.
            QTextCursor marker(document); int matches = 0;
            for (auto block = frame->firstCursorPosition().block(); block.isValid()
                 && block.position() <= frame->lastPosition(); block = block.next()) {
                for (auto it = block.begin(); !it.atEnd(); ++it) {
                    const auto text = it.fragment();
                    if (!text.isValid() || !text.charFormat().isImageFormat()) continue;
                    const auto name = text.charFormat().toImageFormat().name();
                    if (QUrl(name).scheme() != scheme || decode(name) != item.metadata) continue;
                    CompiledContent::require(text.length() == 1 && block.length() == 2
                        && text.position() == block.position());
                    marker.setPosition(text.position()); marker.setPosition(text.position() + 1, QTextCursor::KeepAnchor);
                    ++matches;
                }
            }
            CompiledContent::require(matches == 1 && marker.currentFrame() == frame
                && marker.selectionStart() >= frame->firstPosition() && marker.selectionEnd() <= frame->lastPosition()
                && marker.selectedText() == QString(QChar::ObjectReplacementCharacter));
            // Journal only source-authenticated table storage in the temporary
            // import. Authored paragraph children, including empty ones, still
            // contain their Flow ORCs here and cannot be length-one storage.
            const auto children = owned.value(QStringLiteral("blocks")).toArray();
            qsizetype sourceTables = 0, nonemptyTables = 0;
            for (const auto &child : children) {
                const auto table = child.toObject().value(QStringLiteral("table"));
                if (!table.isObject()) continue;
                ++sourceTables;
                bool hasCell = false;
                for (const auto &row : table.toObject().value(QStringLiteral("rows")).toArray())
                    hasCell |= !row.toObject().value(QStringLiteral("cells")).toArray().isEmpty();
                nonemptyTables += hasCell;
            }
            // An unstyled, captionless no-cell table still emits <table> HTML.
            // Qt may elide its frame but retain a root boundary separator. Only
            // the corresponding source edge can authorize that boundary; this
            // does not classify unrelated empty definition/list blocks.
            const auto elidedEdgeTable = [](const QJsonValue &value) {
                const auto child = value.toObject();
                const auto tableValue = child.value(QStringLiteral("table"));
                if (child.value(QStringLiteral("kind")).toString() != QStringLiteral("table")
                    || !tableValue.isObject()
                    || !child.value(QStringLiteral("list_path")).toString().isEmpty()
                    || !child.value(QStringLiteral("path")).toString().isEmpty()) return false;
                const auto table = tableValue.toObject();
                if (SemanticHtml::present(table.value(QStringLiteral("style")))
                    || SemanticHtml::present(table.value(QStringLiteral("geometry")))
                    || SemanticHtml::present(table.value(QStringLiteral("caption_blocks")))
                    || !table.value(QStringLiteral("caption")).toArray().isEmpty()) return false;
                for (const auto &row : table.value(QStringLiteral("rows")).toArray())
                    if (!row.toObject().value(QStringLiteral("cells")).toArray().isEmpty()) return false;
                return true;
            };
            const bool leadingElidedTable = !children.isEmpty() && elidedEdgeTable(children.first());
            const bool trailingElidedTable = !children.isEmpty() && elidedEdgeTable(children.last());
            auto *temporaryRoot = temporary.rootFrame();
            QList<QTextFrame *> directTables;
            for (auto *candidate : temporaryRoot->childFrames()) {
                // Only table owners authorize this storage journal. Qt also
                // creates child frames for inline images (including Flow ORCs);
                // their existing image/Flow validators retain that ownership.
                if (!qobject_cast<QTextTable *>(candidate)
                    && !candidate->frameFormat().hasProperty(SemanticHtml::tableBoxOwnerProperty)) continue;
                CompiledContent::require(candidate->parentFrame() == temporaryRoot);
                directTables.append(candidate);
            }
            // Existing SemanticHtml marker validation owns styled empty tables;
            // an unstyled no-cell table may correctly produce no Qt frame.
            CompiledContent::require(directTables.size() >= nonemptyTables && directTables.size() <= sourceTables);
            for (auto it = temporaryRoot->begin(); !it.atEnd(); ++it) {
                if (it.currentFrame()) continue;
                const auto block = it.currentBlock();
                if (!block.isValid() || block.length() != 1) continue;
                CompiledContent::require(QTextCursor(block).currentFrame() == temporaryRoot);
                bool tableAdjacent = false;
                for (auto *tableOwner : directTables)
                    tableAdjacent |= tableOwner->firstPosition() == block.position() + 1
                        || tableOwner->lastPosition() + 1 == block.position();
                const bool elidedTableBoundary = (leadingElidedTable && block == temporary.begin())
                    || (trailingElidedTable && block == temporary.lastBlock());
                if (!tableAdjacent && !elidedTableBoundary) continue;
                QTextCursor storage(block); auto storageFormat = storage.blockFormat();
                storageFormat.setProperty(containerStorageProperty, true);
                storageFormat.setLineHeight(0, QTextBlockFormat::FixedHeight);
                storage.setBlockFormat(storageFormat);
            }
            const QTextDocumentFragment fragment(&temporary);
            if (fragment.isEmpty()) marker.removeSelectedText(); else marker.insertFragment(fragment);
            CompiledContent::require(guard && layout && document->documentLayout() == layout && parent && frame
                && frame->parentFrame() == parent);
            QTextCursor first = frame->firstCursorPosition();
            first.setBlockFormat(temporary.begin().blockFormat()); first.setBlockCharFormat(firstCharacter);
            CompiledContent::require(guard && frame && parent && frame->parentFrame() == parent);
            // Direct flow/group paragraphs have no reader-invented outer margin.
            // Frames, table cells and Figure captions retain their own formats.
            for (auto it = frame->begin(); !it.atEnd(); ++it) {
                if (it.currentFrame()) continue;
                const auto block = it.currentBlock();
                if (!block.isValid()) continue;
                QTextCursor direct(block); auto format = direct.blockFormat();
                format.setTopMargin(0); format.setBottomMargin(0); direct.setBlockFormat(format);
                const auto alignment = item.metadata.value(QStringLiteral("alignment")).toString();
                if (!alignment.isEmpty() && !format.hasProperty(QTextFormat::BlockAlignment)) {
                    format.setAlignment(alignment == QStringLiteral("center") ? Qt::AlignHCenter
                        : alignment == QStringLiteral("right") ? Qt::AlignRight : Qt::AlignLeft);
                    direct.setBlockFormat(format);
                }
            }
            const auto hideStorage = [&](QTextBlock block, QTextFrame *owner) {
                CompiledContent::require(guard && layout && document->documentLayout() == layout && block.isValid()
                    && block.length() == 1 && QTextCursor(block).currentFrame() == owner);
                QTextCursor storage(block); auto format = storage.blockFormat();
                format.setTopMargin(0); format.setBottomMargin(0);
                format.setLineHeight(0, QTextBlockFormat::FixedHeight);
                format.setProperty(containerStorageProperty, true);
                storage.setBlockFormat(format); block.setVisible(false); block.setLineCount(0);
            };
            const auto before = frame->firstCursorPosition().block().previous();
            const auto after = frame->lastCursorPosition().block().next();
            CompiledContent::require(before.isValid() && after.isValid()
                && before.position() + before.length() == frame->firstPosition()
                && after.position() == frame->lastPosition() + 1);
            if (containingTable) {
                const auto beforeCell = containingTable->cellAt(before.position());
                const auto afterCell = containingTable->cellAt(after.position());
                CompiledContent::require(beforeCell.isValid() && afterCell.isValid()
                    && beforeCell.row() == sourceRow && afterCell.row() == sourceRow
                    && beforeCell.column() == sourceColumn && afterCell.column() == sourceColumn);
            }
            hideStorage(before, parent); hideStorage(after, parent);
            for (auto it = frame->begin(); !it.atEnd(); ++it) {
                if (it.currentFrame()) continue;
                const auto block = it.currentBlock();
                if (block.isValid() && block.blockFormat().boolProperty(containerStorageProperty))
                    hideStorage(block, frame);
            }
            if (item.metadata.value(QStringLiteral("html")).toString().isEmpty()) {
                CompiledContent::require(frame->childFrames().isEmpty()
                    && frame->firstCursorPosition().block() == frame->lastCursorPosition().block());
                hideStorage(frame->firstCursorPosition().block(), frame);
            }
            containers->append(frame);
            continue;
        }
        const QTextDocumentFragment fragment(&temporary);
        // Qt skips empty fragments before replacing the selected placeholder.
        if (fragment.isEmpty()) insertion.removeSelectedText();
        else insertion.insertFragment(fragment);
        CompiledContent::require(guard);
        owner.last = insertion;
        owner.last.clearSelection(); owner.last.movePosition(QTextCursor::EndOfBlock);
        // Restore the outer role at position zero as well as nonzero insertions.
        // Keep the imported paragraph's own metrics separately for the native
        // whole-owner projection; prefix character formats are never rewritten.
        auto merged = owner.roleFormat;
        const auto firstProperties = firstFormat.properties();
        for (auto it = firstProperties.cbegin(); it != firstProperties.cend(); ++it) {
            if (it.key() != QTextFormat::ObjectIndex && it.key() != QTextFormat::BlockTopMargin
                && it.key() != QTextFormat::BlockBottomMargin && it.key() != QTextFormat::BlockLeftMargin
                && it.key() != QTextFormat::BlockRightMargin && it.key() != QTextFormat::LayoutDirection)
                merged.setProperty(it.key(), it.value());
        }
        if (firstFormat.hasProperty(QTextFormat::LayoutDirection))
            merged.setLayoutDirection(firstFormat.layoutDirection());
        merged.setTopMargin(owner.roleFormat.topMargin() + firstFormat.topMargin());
        merged.setBottomMargin(owner.roleFormat.bottomMargin() + firstFormat.bottomMargin());
        merged.setLeftMargin(owner.roleFormat.leftMargin() + firstFormat.leftMargin());
        merged.setRightMargin(owner.roleFormat.rightMargin() + firstFormat.rightMargin());
        QTextCursor first(owner.first.block());
        first.setBlockFormat(merged);
        auto character = owner.roleCharacter;
        character.merge(firstCharacter);
        first.setBlockCharFormat(character);
        first.setKeepPositionOnInsert(true);
        owner.paragraphs.append({first, firstFormat, firstCharacter});
        // Fragment insertion also omits the first separator association at a
        // nonzero destination, even when that paragraph is not a poem line.
        if (firstFormat.hasProperty(SemanticHtml::sourceBoundaryProperty)) {
            QTextCursor first(owner.first.block());
            auto format = first.blockFormat();
            format.setProperty(SemanticHtml::sourceBoundaryProperty,
                firstFormat.property(SemanticHtml::sourceBoundaryProperty));
            first.setBlockFormat(format);
        }
        // This is the pre-figure authored paragraph inventory. Raw U+2029
        // paragraphs need the role inset too, even without a poem block marker.
        for (auto block = owner.first.block().next(); block.isValid()
             && block.position() <= owner.last.position(); block = block.next()) {
            auto format = block.blockFormat();
            QTextCursor paragraph(block); paragraph.setKeepPositionOnInsert(true);
            owner.paragraphs.append({paragraph, format, block.charFormat()});
            format.setLeftMargin(owner.roleFormat.leftMargin() + format.leftMargin());
            format.setRightMargin(owner.roleFormat.rightMargin() + format.rightMargin());
            paragraph.setBlockFormat(format);
        }
        // These boundaries predate figure insertion. They are authored storage
        // paragraphs, including poem/empty lines, and may never become joins.
        for (auto block = owner.first.block(); block.isValid() && block.position() < owner.last.position(); block = block.next()) {
            const int position = block.position() + block.length() - 1;
            if (position >= owner.last.position()) break;
            QTextCursor boundary(document); boundary.setPosition(position);
            CompiledContent::require(document->characterAt(position) == QChar::ParagraphSeparator);
            const auto format = block.blockFormat();
            const int separatorRun = format.hasProperty(SemanticHtml::sourceBoundaryProperty)
                ? format.intProperty(SemanticHtml::sourceBoundaryProperty)
                : format.hasProperty(sourceRunProperty) ? format.intProperty(sourceRunProperty) : -1;
            owner.authoredBoundaries.append({boundary, separatorRun, format, block.next().blockFormat()});
        }
        owners.append(owner);
    }
    const int revision = document->revision(), count = document->characterCount();
    finished = true;
    transaction.endEditBlock();
    CompiledContent::require(guard && layout && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    restored = true;
    document->setLayoutEnabled(enabled);
    CompiledContent::require(guard && layout && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    return owners;
}

// Only this operation may journal a renderer-created parent separator. Caption
// construction runs afterwards; unrelated paragraphs introduced there cannot be
// relabelled as removable joins.
template <typename Populate>
QPointer<QTextFrame> insertFigure(Owner &owner, QTextCursor placeholder, int run,
                                 QTextFrameFormat format, Populate &&populate) {
    const QPointer<QTextDocument> document(owner.first.document());
    CompiledContent::require(document && owner.last.document() == document && placeholder.document() == document
        && placeholder.hasSelection() && placeholder.selectionEnd() == placeholder.selectionStart() + 1 && run >= 0);
    const QPointer<QAbstractTextDocumentLayout> layout(document->documentLayout());
    CompiledContent::require(document && layout && document->documentLayout() == layout);
    const int revisionBefore = document->revision(), countBefore = document->characterCount();
    const int position = placeholder.selectionStart();
    const bool replacesOwnerTail = placeholder.selectionEnd() == owner.last.position();
    const QPointer<QTextFrame> parent(placeholder.currentFrame());
    CompiledContent::require(parent && parent == owner.first.currentFrame()
        && position >= owner.prefixEnd.position() && position < owner.last.position()
        && document->characterAt(position) == QChar::ObjectReplacementCharacter);
    const auto character = placeholder.charFormat();
    CompiledContent::require(character.isImageFormat()
        && character.property(sourceRunProperty).metaType().id() == QMetaType::Int
        && character.intProperty(sourceRunProperty) == run);
    const int selectedEnd = placeholder.selectionEnd();
    QVector<int> boundaryEnds, joinEnds;
    for (int i = 0; i < owner.authoredBoundaries.size(); ++i)
        if (owner.authoredBoundaries[i].character.position() == selectedEnd) boundaryEnds.append(i);
    for (int i = 0; i < owner.figureJoins.size(); ++i)
        if (owner.figureJoins[i].position() == selectedEnd) joinEnds.append(i);
    QVector<QPair<QTextCursor, bool>> before;
    for (auto it = parent->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock();
        if (!block.isValid()) continue;
        const int separator = block.position() + block.length() - 1;
        if (separator < owner.first.position() || separator >= owner.last.position()
            || document->characterAt(separator) != QChar::ParagraphSeparator) continue;
        QTextCursor cursor(document); cursor.setPosition(separator); before.append({cursor, separator == selectedEnd});
    }
    const bool enabled = document->isLayoutEnabled();
    document->setLayoutEnabled(false);
    CompiledContent::require(document && layout && parent && document->documentLayout() == layout
        && document->revision() == revisionBefore && document->characterCount() == countBefore);
    bool restored = false, finished = false;
    const auto restore = qScopeGuard([&] { if (!restored && document) document->setLayoutEnabled(enabled); });
    QTextCursor transaction(document); transaction.beginEditBlock();
    const auto finish = qScopeGuard([&] { if (!finished && document) transaction.endEditBlock(); });
    format.setProperty(sourceRunProperty, run);
    const QPointer<QTextFrame> frame(placeholder.insertFrame(format));
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && frame->document() == document && frame->parentFrame() == parent);
    QTextCursor inside = frame->firstCursorPosition();
    CompiledContent::require(document->characterAt(inside.position()) == QChar::ObjectReplacementCharacter);
    inside.deleteChar();
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout);
    if (replacesOwnerTail) {
        owner.last.setPosition(frame->lastPosition() + 1);
        owner.last.movePosition(QTextCursor::EndOfBlock);
    }
    // insertFrame uses KeepCursor for its closing marker. A cursor on the
    // original separator at the selection end stays on that new FDD1; restore
    // only identities recorded at that exact boundary before this operation.
    const auto restoreSeparator = [&](QTextCursor &cursor) {
        CompiledContent::require(cursor.document() == document
            && cursor.position() == frame->lastPosition()
            && document->characterAt(cursor.position()) == QChar(0xfdd1)
            && document->characterAt(frame->lastPosition() + 1) == QChar::ParagraphSeparator);
        cursor.setPosition(frame->lastPosition() + 1);
        CompiledContent::require(cursor.currentFrame() == parent);
    };
    for (int index : boundaryEnds) restoreSeparator(owner.authoredBoundaries[index].character);
    for (int index : joinEnds) restoreSeparator(owner.figureJoins[index]);
    QSet<int> retained;
    for (auto &saved : before) {
        auto &cursor = saved.first;
        if (saved.second) restoreSeparator(cursor);
        CompiledContent::require(cursor.document() == document && cursor.currentFrame() == parent
            && document->characterAt(cursor.position()) == QChar::ParagraphSeparator);
        retained.insert(cursor.position());
    }
    QVector<QTextCursor> joins;
    for (auto it = parent->begin(); !it.atEnd(); ++it) {
        const auto block = it.currentBlock();
        if (!block.isValid()) continue;
        const int separator = block.position() + block.length() - 1;
        if (separator < owner.first.position() || separator >= owner.last.position()
            || document->characterAt(separator) != QChar::ParagraphSeparator || retained.contains(separator)) continue;
        QTextCursor cursor(document); cursor.setPosition(separator);
        auto blockFormat = cursor.blockFormat();
        blockFormat.clearProperty(SemanticHtml::sourceBoundaryProperty);
        cursor.setBlockFormat(blockFormat);
        joins.append(cursor);
    }
    populate(frame.data());
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && frame->parentFrame() == parent && frame->frameFormat().intProperty(sourceRunProperty) == run);
    for (const auto &cursor : joins)
        CompiledContent::require(cursor.document() == document && cursor.currentFrame() == parent
            && document->characterAt(cursor.position()) == QChar::ParagraphSeparator);
    const int revision = document->revision(), count = document->characterCount();
    finished = true; transaction.endEditBlock();
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    restored = true; document->setLayoutEnabled(enabled);
    CompiledContent::require(document && layout && parent && frame && document->documentLayout() == layout
        && document->revision() == revision && document->characterCount() == count);
    owner.figureJoins += joins;
    return frame;
}

// Called after actual figure-frame insertion. The intervals are discovered from
// the renderer's run metadata and frame objects, never by matching visible text.
struct SourceRanges {
    QHash<int, QVector<QPair<int, int>>> text;
    QHash<int, int> frames;
    QHash<int, int> frameStarts;
    QVector<int> structuralJoins;
    QVector<AuthoredBoundary> authoredBoundaries;
    int first = -1;
    int last = -1;
};
inline SourceRanges ranges(const Owner &owner) {
    auto *document = owner.first.document();
    CompiledContent::require(document && owner.last.document() == document);
    SourceRanges result;
    result.first = owner.first.block().position();
    result.last = owner.last.block().position() + owner.last.block().length() - 1;
    result.authoredBoundaries = owner.authoredBoundaries;
    const auto parent = owner.first.currentFrame();
    QSet<int> authored;
    for (const auto &boundary : owner.authoredBoundaries) {
        CompiledContent::require(boundary.character.document() == document
            && document->characterAt(boundary.character.position()) == QChar::ParagraphSeparator);
        authored.insert(boundary.character.position());
    }
    QSet<int> joins;
    for (const auto &cursor : owner.figureJoins) {
        const int position = cursor.position();
        CompiledContent::require(cursor.document() == document && position >= result.first && position < result.last
            && cursor.currentFrame() == parent && document->characterAt(position) == QChar::ParagraphSeparator
            && !authored.contains(position) && !joins.contains(position));
        joins.insert(position);
        result.structuralJoins.append(position);
    }
    for (auto block = document->findBlock(result.first); block.isValid() && block.position() <= result.last; block = block.next()) {
        if (QTextCursor(block).currentFrame() != parent) continue;
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().hasProperty(sourceRunProperty)) continue;
            const QVariant run = fragment.charFormat().property(sourceRunProperty);
            CompiledContent::require(run.metaType().id() == QMetaType::Int && run.toInt() >= 0);
            result.text[run.toInt()].append({fragment.position(), fragment.position() + fragment.length()});
        }
        const int separator = block.position() + block.length() - 1;
        if (separator < result.last && !authored.contains(separator)
            && document->characterAt(separator) == QChar::ParagraphSeparator)
            CompiledContent::require(joins.contains(separator));
    }
    for (auto *frame : parent->childFrames()) {
        if (frame->firstPosition() - 1 < result.first || frame->lastPosition() + 1 > result.last) continue;
        const QVariant run = frame->frameFormat().property(sourceRunProperty);
        if (!run.isValid()) continue;
        CompiledContent::require(run.metaType().id() == QMetaType::Int && run.toInt() >= 0
            && !result.frames.contains(run.toInt()));
        result.frames.insert(run.toInt(), frame->objectIndex());
        result.frameStarts.insert(frame->objectIndex(), frame->firstPosition() - 1);
    }
    return result;
}

// Produce the private native descriptor from actual imported ranges. The native
// registration independently checks complete, ordered, once-only source coverage.
inline QVariantList nativeParts(const QJsonArray &outline, const SourceRanges &source,
                                QSet<int> &consumedRuns) {
    QVariantList result;
    for (const QJsonValue &value : outline) {
        const QJsonObject part = CompiledContent::object(value);
        const QString kind = part.value(QStringLiteral("kind")).toString();
        if (kind == QStringLiteral("scope")) {
            const QString direction = part.value(QStringLiteral("direction")).toString();
            CompiledContent::require(direction == QStringLiteral("ltr") || direction == QStringLiteral("rtl"));
            const auto nested = nativeParts(CompiledContent::array(part.value(QStringLiteral("parts"))), source, consumedRuns);
            result.append(QVariantMap{{QStringLiteral("kind"), kind},
                {QStringLiteral("mode"), part.value(QStringLiteral("mode")).toString()},
                {QStringLiteral("direction"), int(direction == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight)},
                {QStringLiteral("language"), part.value(QStringLiteral("language")).toVariant()},
                {QStringLiteral("parts"), nested}});
            continue;
        }
        const QJsonValue runValue = part.value(QStringLiteral("run"));
        const int run = runValue.toInt(-1);
        CompiledContent::require(runValue.isDouble() && run >= 0 && runValue.toDouble() == run
            && !consumedRuns.contains(run));
        consumedRuns.insert(run);
        if (kind == QStringLiteral("figure")) {
            CompiledContent::require(source.frames.contains(run) && !source.text.contains(run));
            result.append(QVariantMap{{QStringLiteral("kind"), QStringLiteral("frame")},
                {QStringLiteral("object"), source.frames.value(run)}});
            continue;
        }
        CompiledContent::require(kind == QStringLiteral("inline") && !source.frames.contains(run));
        QVector<QPair<int, QVariantMap>> events;
        for (const auto &range : source.text.value(run)) {
            CompiledContent::require(range.first < range.second);
            events.append({range.first, {{QStringLiteral("kind"), QStringLiteral("text")},
                {QStringLiteral("first"), range.first}, {QStringLiteral("last"), range.second}}});
        }
        for (const auto &boundary : source.authoredBoundaries) {
            if (boundary.sourceRun != run) continue;
            const int position = boundary.character.position();
            events.append({position, {{QStringLiteral("kind"), QStringLiteral("paragraph_break")},
                {QStringLiteral("position"), position}}});
        }
        std::sort(events.begin(), events.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
        for (const auto &event : events) result.append(event.second);
    }
    // Qt can keep an authored paragraph separator after a following figure's
    // storage frame. Its run association remains original, but native coverage
    // must follow the actual source positions. Reorder only separator events
    // among siblings of this exact scope; never split or move a scope node.
    const auto kindOf = [](const QVariant &part) {
        return part.toMap().value(QStringLiteral("kind")).toString();
    };
    const auto positionOf = [&](const QVariant &value) {
        const auto part = value.toMap();
        const auto kind = part.value(QStringLiteral("kind")).toString();
        if (kind == QStringLiteral("text")) return part.value(QStringLiteral("first")).toInt();
        if (kind == QStringLiteral("paragraph_break")) return part.value(QStringLiteral("position")).toInt();
        const int object = part.value(QStringLiteral("object")).toInt();
        CompiledContent::require(kind == QStringLiteral("frame") && source.frameStarts.contains(object));
        return source.frameStarts.value(object);
    };
    for (qsizetype begin = 0; begin < result.size();) {
        if (kindOf(result[begin]) == QStringLiteral("scope")) { ++begin; continue; }
        qsizetype end = begin;
        QVariantList contentBefore;
        while (end < result.size() && kindOf(result[end]) != QStringLiteral("scope")) {
            if (kindOf(result[end]) != QStringLiteral("paragraph_break")) contentBefore.append(result[end]);
            ++end;
        }
        std::stable_sort(result.begin() + begin, result.begin() + end,
            [&](const QVariant &left, const QVariant &right) { return positionOf(left) < positionOf(right); });
        QVariantList contentAfter;
        for (qsizetype index = begin; index < end; ++index)
            if (kindOf(result[index]) != QStringLiteral("paragraph_break")) contentAfter.append(result[index]);
        CompiledContent::require(contentBefore == contentAfter);
        begin = end;
    }
    return result;
}

inline QVariantMap descriptor(const Owner &owner, Qt::LayoutDirection direction = Qt::LayoutDirectionAuto) {
    const SourceRanges source = ranges(owner);
    QSet<int> consumed;
    QVariantList parts = nativeParts(owner.metadata.value(QStringLiteral("parts")).toArray(), source, consumed);
    for (auto it = source.text.cbegin(); it != source.text.cend(); ++it) CompiledContent::require(consumed.contains(it.key()));
    for (auto it = source.frames.cbegin(); it != source.frames.cend(); ++it) CompiledContent::require(consumed.contains(it.key()));
    // Unassociated raw source separators remain an explicit construction error;
    // they must not be guessed into a scope or erased as frame-generated joins.
    for (const auto &boundary : source.authoredBoundaries)
        CompiledContent::require(boundary.sourceRun >= 0 && consumed.contains(boundary.sourceRun));
    CompiledContent::require(owner.prefixEnd.document() == owner.first.document()
        && owner.prefixEnd.position() >= source.first && owner.prefixEnd.position() <= source.last);
    if (owner.prefixEnd.position() > source.first)
        parts.prepend(QVariantMap{{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("first"), source.first}, {QStringLiteral("last"), owner.prefixEnd.position()}});
    QVariantList joins;
    for (const int position : source.structuralJoins) joins.append(position);
    return {{QStringLiteral("first"), source.first}, {QStringLiteral("last"), source.last},
        {QStringLiteral("direction"), int(direction)},
        {QStringLiteral("language"), owner.metadata.value(QStringLiteral("language")).toString()},
        {QStringLiteral("joins"), joins}, {QStringLiteral("parts"), parts}};
}
}
