#pragma once
// Private candidate: decoded Ruby data only; no source markup or font probe text.
#include "SemanticHtml.hpp"
#include <QtGui/private/qtextformat_p.h>
#include <QtGui/private/qtextinlinestyle_p.h>
#include <QFontDatabase>
#include <optional>

namespace CompiledRuby {
struct Context {
    QFont originalFont;
    qreal bodyPoints = 0;
    QPaintDevice *device = nullptr;
    QTextOption option;
    QBrush foreground;
    qint64 *actionOwnerCounter = nullptr;
    QString egyptianFamily;
};
struct ResolvedOwner {
    QTextCharFormat format;
    QFont font;
    qreal script = 0;
    int scriptMode = 0;
    std::optional<qreal> numeric;
    qreal above = 0, below = 0;
};
inline qreal checked(qreal value, bool nonnegative = false) {
    if (!std::isfinite(value) || std::abs(value) >= qreal(QFIXED_MAX)
        || (nonnegative && value < 0)) throw std::runtime_error("unrepresentable Ruby metric");
    return value;
}
inline QJsonObject spanFont(const QJsonObject &span) {
    QJsonObject value;
    for (const auto &key : {"font_scale", "font_scale_basis", "small", "superscript", "subscript",
            "bold", "italic", "code", "language", "classes", "role", "font_features", "font_family"})
        if (span.contains(key)) value.insert(key, span.value(key));
    value.insert("font_normalized", span.value("inline_style").toObject().value("font_normalized").toBool());
    return SemanticHtml::inlineFontSnapshot(value);
}
inline QTextCharFormat fontFormat(const QJsonObject &raw, const Context &context) {
    const auto snapshot = SemanticHtml::inlineFontSnapshot(raw);
    if (!(context.bodyPoints > 0) || context.originalFont.pointSizeF() <= 0)
        throw std::runtime_error("Ruby lost its original inline font basis");
    QFont basis = context.originalFont;
    const QString origin = snapshot.value("font_scale_basis").toString();
    const auto scale = snapshot.value("font_scale");
    const qreal base = origin == "normal_body" ? context.bodyPoints
        : origin == "css_px" ? SemanticHtml::cssPixelFontBase(context.bodyPoints) : basis.pointSizeF();
    if (SemanticHtml::present(scale)) {
        // Zero-size glyph/strut support is not emulated with a minimum-size font.
        if (scale.toDouble() == 0) throw std::runtime_error("Ruby zero-size font not yet installed");
        basis.setPointSizeF(SemanticHtml::boundedFontPoints(base, scale.toDouble(), SemanticHtml::maximumFontPoints()));
    }
    basis.setBold(snapshot.value("bold").toBool());
    basis.setItalic(snapshot.value("italic").toBool());
    basis.setUnderline(false); basis.setStrikeOut(false);
    if (snapshot.value("code").toBool()) {
        const QFont fixed = QFontDatabase::systemFont(QFontDatabase::FixedFont);
        basis.setFamilies(fixed.families()); basis.setStyleHint(QFont::Monospace);
    }
    if (!snapshot.value("code").toBool() && !SemanticHtml::present(snapshot.value("font_family"))
        && snapshot.value("classes").toString().simplified().split(QChar(' '), Qt::SkipEmptyParts).contains(QStringLiteral("Egyp"))) {
        if (context.egyptianFamily.isEmpty()) throw std::runtime_error("Ruby Egyptian family context is missing");
        basis.setFamilies({context.egyptianFamily});
    }
    if (SemanticHtml::present(snapshot.value("font_family")))
        SemanticHtml::applyFontFamily(basis, snapshot.value("font_family"));
    QTextCharFormat format;
    format.setFont(basis);
    const bool normalized = snapshot.value("font_normalized").toBool();
    if (!normalized && snapshot.value("small").toBool())
        format.setProperty(QTextFormat::FontSizeAdjustment, -1);
    // Use Qt's own HTML-size resolver without inserting a synthetic text child.
    QTextFormatCollection collection;
    collection.setDefaultFont(basis);
    format = collection.charFormat(collection.indexForFormat(format));
    const QFont resolved = format.font();
    format.clearProperty(QTextFormat::FontSizeAdjustment);
    format.setFont(resolved);
    if (snapshot.value("superscript").toBool() && snapshot.value("subscript").toBool())
        throw std::runtime_error("ambiguous Ruby script origin");
    format.setVerticalAlignment(snapshot.value("superscript").toBool() ? QTextCharFormat::AlignSuperScript
        : snapshot.value("subscript").toBool() ? QTextCharFormat::AlignSubScript : QTextCharFormat::AlignNormal);
    if (normalized) format.setProperty(QCompiledInline::Property,
        QVariantMap{{"policy", QCompiledInline::Capability}, {"normalized", true}});
    SemanticHtml::applyFontFeatures(format, SemanticHtml::fontFeaturePolicy(snapshot.value("font_features")), context.originalFont);
    return format;
}
inline qreal computedMetric(const QJsonValue &value, const Context &context) {
    SemanticHtml::inlineComputed(value, true);
    const auto object = value.toObject();
    const qreal base = object.value("font_scale_basis") == "css_px"
        ? SemanticHtml::cssPixelFontBase(context.bodyPoints) : context.bodyPoints;
    return checked(object.value("value").toDouble() * base * QFontMetricsF(QFont()).fontDpi() / 72);
}
inline QVariantMap inlinePolicy(const QJsonObject &style, const QJsonObject &snapshot,
        const Context &context, const QTextCharFormat &font) {
    if (style.isEmpty()) return QCompiledInline::policy(font);
    SemanticHtml::inlineObject(style, {"font_normalized", "wrap", "cursor", "decoration", "line_height", "baseline_shift"});
    QVariantMap result{{"policy", QCompiledInline::Capability},
        {"normalized", snapshot.value("font_normalized").toBool()}};
    if (SemanticHtml::present(style.value("wrap"))) {
        if (style.value("wrap") != "normal" && style.value("wrap") != "break_word")
            throw std::runtime_error("invalid Ruby wrap policy");
        result.insert("wrap", style.value("wrap").toString());
    }
    if (SemanticHtml::present(style.value("cursor"))) result.insert("cursor", style.value("cursor").toString());
    if (SemanticHtml::present(style.value("baseline_shift")))
        result.insert("shift", computedMetric(style.value("baseline_shift"), context));
    if (SemanticHtml::present(style.value("line_height"))) {
        const auto line = SemanticHtml::inlineObject(style.value("line_height"), {"computed", "font_relative"});
        if (line.size() != 1) throw std::runtime_error("invalid Ruby line-height union");
        if (line.contains("computed")) result.insert("height", computedMetric(line.value("computed"), context));
        else {
            const auto relative = SemanticHtml::inlineObject(line.value("font_relative"), {"font", "factor"}, {"font", "factor"});
            const auto reference = SemanticHtml::inlineFontSnapshot(relative.value("font"));
            if (reference != SemanticHtml::inlineFontSnapshot(snapshot))
                throw std::runtime_error("Ruby line-height crosses its declaring font");
            result.insert("height_factor", SemanticHtml::inlineNumber(relative.value("factor")));
            result.insert("height_font", QVariant::fromValue(QTextFormat(font)));
        }
    }
    if (SemanticHtml::present(style.value("decoration"))) {
        const auto decoration = SemanticHtml::inlineObject(style.value("decoration"), {"style", "color", "thickness"}, {"style"});
        QVariantMap paint{{"style", decoration.value("style").toString()}};
        if (SemanticHtml::present(decoration.value("color"))) {
            SemanticHtml::styleColor(decoration.value("color"));
            paint.insert("color", decoration.value("color").toString());
        }
        if (SemanticHtml::present(decoration.value("thickness"))) {
            const auto width = SemanticHtml::inlineObject(decoration.value("thickness"), {"unit", "value"}, {"unit", "value"});
            if (width.value("unit") != "px" && width.value("unit") != "em") throw std::runtime_error("invalid Ruby decoration unit");
            const qreal scale = width.value("unit") == "em" ? context.bodyPoints * QFontMetricsF(QFont()).fontDpi() / 72 : 1;
            paint.insert("thickness", checked(SemanticHtml::inlineNumber(width.value("value")) * scale, true));
        }
        result.insert("decoration", paint);
    }
    if (!QCompiledInline::valid(result)) throw std::runtime_error("invalid resolved Ruby inline policy");
    return result;
}
inline ResolvedOwner resolveOwner(const QJsonObject &owner, const Context &context) {
    SemanticHtml::inlineObject(owner, {"font", "direction", "inline_style", "foreground", "background"}, {"font", "direction"});
    if (!owner.value("direction").isString()
        || (SemanticHtml::present(owner.value("inline_style")) && !owner.value("inline_style").isObject()))
        throw std::runtime_error("invalid Ruby declaring context");
    const auto snapshot = SemanticHtml::inlineFontSnapshot(owner.value("font"));
    ResolvedOwner result;
    result.scriptMode = snapshot.value("superscript").toBool() ? -1 : snapshot.value("subscript").toBool() ? 1 : 0;
    result.format = fontFormat(snapshot, context);
    const auto style = owner.value("inline_style").toObject();
    auto policy = inlinePolicy(style, snapshot, context, result.format);
    if (!policy.isEmpty()) result.format.setProperty(QCompiledInline::Property, policy);
    result.font = context.device ? QFont(result.format.font(), context.device) : result.format.font();
    QCompiledInline::applyScriptSize(result.font, result.format);
    const QFontMetricsF metrics(result.font, context.device);
    const qreal scale = QCompiledInline::deviceScale(result.font);
    auto scriptFormat = result.format;
    auto scriptPolicy = QCompiledInline::policy(scriptFormat); scriptPolicy.remove("shift");
    if (scriptPolicy.size() == 2 && !scriptPolicy.value("normalized").toBool()) scriptFormat.clearProperty(QCompiledInline::Property);
    else if (!scriptPolicy.isEmpty()) scriptFormat.setProperty(QCompiledInline::Property, scriptPolicy);
    result.script = checked(QCompiledInline::baseline(scriptFormat,
        QFixed::fromReal(checked(metrics.ascent() + metrics.descent(), true)), scale).toReal());
    if (policy.contains("shift")) result.numeric = checked(-policy.value("shift").toDouble() * scale);
    const qreal leading = qMax(qreal(0), metrics.leading());
    result.above = checked(metrics.ascent() + leading / 2);
    result.below = checked(metrics.descent() + leading / 2);
    qreal height = 0;
    if (QCompiledInline::height(result.format, context.device, scale, &height)) {
        const qreal extra = (height - metrics.ascent() - metrics.descent()) / 2;
        result.above = checked(metrics.ascent() + extra);
        result.below = checked(metrics.descent() + extra);
    }
    for (const auto &key : {"foreground", "background"}) if (SemanticHtml::present(owner.value(key))) {
        const QColor color(SemanticHtml::styleColor(owner.value(key)));
        if (QString(key) == "foreground") result.format.setForeground(color); else result.format.setBackground(color);
    }
    return result;
}
struct Placement { qreal shift = 0, appliedScript = 0; int scriptMode = 0; };
// A numeric override leaves its script snapshot visible to descendants but
// does not apply that default script. A later reset removes only applied script.
inline Placement place(const ResolvedOwner &node, const Placement *parent = nullptr) {
    Placement result{parent ? parent->shift : 0, parent ? parent->appliedScript : 0, node.scriptMode};
    if (node.numeric) result.shift = checked(result.shift + *node.numeric);
    else if (!parent || node.scriptMode != parent->scriptMode) {
        result.shift = checked(result.shift + node.script - result.appliedScript);
        result.appliedScript = node.script;
    }
    return result;
}
inline QTextCharFormat childFormat(const ResolvedOwner &node, qreal localDisplacement) {
    auto format = node.format;
    format.setFont(node.font);
    format.setVerticalAlignment(QTextCharFormat::AlignNormal);
    format.setBaselineOffset(0);
    auto policy = QCompiledInline::policy(format);
    policy.insert("policy", QCompiledInline::Capability); policy.insert("normalized", true);
    policy.insert("shift", checked(-localDisplacement / QCompiledInline::deviceScale(node.font)));
    format.setProperty(QCompiledInline::Property, policy);
    return format;
}
} // namespace CompiledRuby
