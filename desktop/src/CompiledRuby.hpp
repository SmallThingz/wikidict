#pragma once
#include "CompiledRubyFont.hpp"
#include "CompiledContent.hpp"
#include <QtGui/private/qtextrubylayout_p.h>
#include <QtGui/private/qtextrubyrangemap_p.h>
#include <QTextBlock>
#include <QTextCursor>
#include <QUrl>
#include <functional>

namespace CompiledRuby {
inline QString marker(const QJsonObject &span, qreal bodyPoints, qreal contextPoints,
        int sourceRun, const QJsonValue &contextFamily, const QString &egyptianFamily) {
    if (!span.value("ruby").isObject() || span.value("kind") != "text"
        || !span.value("text").toString().isEmpty() || !span.value("trail").toString().isEmpty()
        || !span.value("target").toString().isEmpty()) throw std::runtime_error("invalid compiled Ruby span owner");
    const QJsonObject data{{"span", span}, {"body_points", bodyPoints}, {"context_points", contextPoints}, {"egyptian_family", egyptianFamily}};
    // A transient import anchor, removed while document layout is disabled.
    // Declaring fonts come from RubyOwner, never this character's glyph metrics.
    return SemanticHtml::scaledText(QStringLiteral("&#xe000;"), 1, {}, SemanticHtml::Basis::Context,
        0, false, false, false, 0, {}, true, sourceRun, {}, -1, 0, false, {}, false, {}, 0, 0, {}, contextFamily, data);
}
struct TrackedRange {
    QTextCursor first, last;
    TrackedRange() = default;
    TrackedRange(QTextDocument *document, int begin, int end) : first(document), last(document) {
        first.setPosition(begin); last.setPosition(end);
        first.setKeepPositionOnInsert(begin == end); last.setKeepPositionOnInsert(true);
    }
    QTextRubyLayout::Range native() const { return {first.position(), last.position()}; }
    QTextRubyRangeMap::Range logical() const { return {first.position(), last.position()}; }
};
struct ImportedChild {
    TrackedRange range;
    QTextRubyLayout::Child native;
};
struct ImportedGap { ImportedChild child; QString logicalText; };
struct ImportedReading { ImportedChild child; int start = 0, count = 0, level = 0; bool hidden = false; ImportedGap gap; };
struct ImportedSegment {
    TrackedRange range;
    ImportedGap gap;
    QList<ImportedChild> bases;
    QList<ImportedGap> baseGaps;
    QList<ImportedReading> readings;
    Qt::LayoutDirection direction = Qt::LeftToRight;
    qreal baselineOrigin = 0;
    QTextCharFormat actionFormat;
};
struct ImportedOwner { TrackedRange range; QList<ImportedSegment> segments; };
struct Expansion {
    QPointer<QTextDocument> document;
    QList<ImportedOwner> owners;
    bool empty() const { return owners.isEmpty(); }
};
inline QJsonArray array(const QJsonValue &value) {
    if (!value.isArray()) throw std::runtime_error("invalid compiled Ruby array");
    return value.toArray();
}
inline int integer(const QJsonValue &value) {
    const double number = value.toDouble(-1);
    if (!value.isDouble() || !std::isfinite(number) || number < 0 || number > 65536 || number != std::floor(number))
        throw std::runtime_error("invalid compiled Ruby index");
    return int(number);
}
inline bool hasPadding(const QJsonObject &span) {
    return SemanticHtml::present(span.value("inline_padding_group"));
}
inline QJsonObject paddingGroup(const QJsonObject &span) {
    SemanticHtml::inlineObject(span, {"kind", "role", "text", "target", "trail", "language", "classes",
        "direction", "explanation", "font_scale", "font_scale_basis", "font_features", "link_paint",
        "inline_style", "font_family", "image", "target_fragment", "tooltip", "ruby", "inline_padding_group",
        "foreground", "background", "bold", "italic", "small", "subscript", "superscript", "code", "underline", "strike"});
    const auto group = SemanticHtml::inlineObject(span.value("inline_padding_group"),
        {"left", "right", "spans"}, {"left", "right", "spans"});
    bool nonzero = false;
    for (const auto &key : {"left", "right"}) {
        const auto edge = SemanticHtml::inlineObject(group.value(key), {"unit", "value"}, {"unit", "value"});
        if (edge.value("unit") != "px" && edge.value("unit") != "em")
            throw std::runtime_error("invalid inline padding unit");
        nonzero |= SemanticHtml::inlineNumber(edge.value("value")) != 0;
    }
    const auto children = array(group.value("spans"));
    if (!nonzero || children.isEmpty() || children.size() > 65536
        || !span.value("text").isString() || !span.value("text").toString().isEmpty()
        || !span.value("trail").isString() || !span.value("trail").toString().isEmpty()
        || SemanticHtml::present(span.value("ruby")) || SemanticHtml::present(span.value("image"))
        || SemanticHtml::present(span.value("link_paint")))
        throw std::runtime_error("invalid inline padding owner");
    const auto kind = span.value("kind");
    if ((kind != "text" && kind != "link" && kind != "external_link") || !span.value("target").isString()
        || (kind == "text" ? !span.value("target").toString().isEmpty() : span.value("target").toString().isEmpty()))
        throw std::runtime_error("invalid inline padding action");
    if (!span.value("direction").isString() || !span.value("direction").toString().isEmpty())
        throw std::runtime_error("inline padding bidi scope not yet supported");
    for (const auto &key : {"underline", "strike"})
        if (span.contains(key) && !span.value(key).isBool()) throw std::runtime_error("invalid inline padding paint");
    if (SemanticHtml::present(span.value("target_fragment"))
        && (kind != "link" || !span.value("target_fragment").isString()))
        throw std::runtime_error("invalid inline padding fragment");
    if (span.contains("explanation") && !span.value("explanation").isString())
        throw std::runtime_error("invalid inline padding explanation");
    return group;
}
// Check the whole compiled entry before rendering any carrier. Table depth is
// independent; each Ruby/group increments the existing content-depth budget.
inline void validatePaddingEntry(const QJsonObject &entry,
        const std::function<bool(const QJsonObject &, int, int, qsizetype &)> &extra = {}) {
    qsizetype remaining = 1 << 20;
    const auto scan = [&](auto &&self, const QJsonArray &spans, int depth, int rubyDepth) -> void {
        if (depth > 16 || rubyDepth > 16 || spans.size() > remaining)
            throw std::runtime_error("inline group presentation budget exceeded");
        remaining -= spans.size();
        for (const auto &raw : spans) {
            if (!raw.isObject()) throw std::runtime_error("invalid compiled inline child");
            const auto span = raw.toObject();
            if (extra && extra(span, depth, rubyDepth, remaining)) continue;
            if (hasPadding(span)) self(self, array(paddingGroup(span).value("spans")), depth + 1, rubyDepth);
            if (!SemanticHtml::present(span.value("ruby"))) continue;
            if (hasPadding(span)) throw std::runtime_error("competing inline group payloads");
            const auto ruby = SemanticHtml::inlineObject(span.value("ruby"), {"segments"}, {"segments"});
            const auto segments = array(ruby.value("segments"));
            if (depth >= 16 || rubyDepth >= 16 || segments.size() > remaining)
                throw std::runtime_error("Ruby presentation budget exceeded");
            remaining -= segments.size();
            for (const auto &value : segments) {
                const auto segment = value.toObject();
                self(self, array(segment.value("gap_before")), depth + 1, rubyDepth + 1);
                for (const auto &key : {"bases", "annotations"}) {
                    const auto children = array(segment.value(key));
                    if (children.size() > remaining) throw std::runtime_error("Ruby presentation budget exceeded");
                    remaining -= children.size();
                    for (const auto &item : children) {
                        const auto child = item.toObject();
                        self(self, array(child.value("spans")), depth + 1, rubyDepth + 1);
                        self(self, array(child.value("gap_before")), depth + 1, rubyDepth + 1);
                        if (QLatin1StringView(key) == QLatin1StringView("annotations"))
                            for (const auto &fallback : {"fallback_before", "fallback_after"})
                                self(self, array(child.value(fallback)), depth + 1, rubyDepth + 1);
                    }
                }
            }
        }
    };
    const auto visit = [&](const QJsonArray &spans, const CompiledContent::Context &context) {
        scan(scan, spans, context.contentDepth, 0);
    };
    CompiledContent::Walker walker(visit, CompiledContent::TableSpans::Stored);
    walker.entry(entry);
}
inline QString gapText(const QJsonValue &value) {
    QString result;
    for (const auto &raw : array(value)) {
        if (!raw.isObject()) throw std::runtime_error("invalid Ruby gap span");
        const auto span = raw.toObject();
        if (span.value("kind") != "text" || !span.value("text").isString()
            || !span.value("trail").toString().isEmpty() || !span.value("target").toString().isEmpty()
            || hasPadding(span) || SemanticHtml::present(span.value("ruby")) || SemanticHtml::present(span.value("image"))
            || SemanticHtml::present(span.value("link_paint")) || !span.value("direction").toString().isEmpty())
            throw std::runtime_error("unsupported Ruby gap content");
        const auto text = span.value("text").toString();
        for (auto c : text) if (c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != '\f')
            throw std::runtime_error("non-CSS whitespace in Ruby gap");
        result += text;
    }
    return result;
}
inline QString plain(const QJsonArray &spans, int depth = 0) {
    if (depth > 16) throw std::runtime_error("inline group content depth exceeded");
    QString result;
    for (const auto &value : spans) {
        if (!value.isObject()) throw std::runtime_error("invalid Ruby child");
        const auto span = value.toObject();
        if (SemanticHtml::present(span.value("ruby"))) throw std::runtime_error("nested Ruby importer not yet installed");
        if (hasPadding(span)) {
            result += plain(array(paddingGroup(span).value("spans")), depth + 1);
            continue;
        }
        if (!span.value("text").isString() || !span.value("trail").isString()) throw std::runtime_error("invalid Ruby text");
        result += span.value("text").toString() + span.value("trail").toString();
    }
    return result;
}
inline Qt::LayoutDirection direction(const QString &value, const QString &text, Qt::LayoutDirection inherited) {
    if (value == "ltr") return Qt::LeftToRight;
    if (value == "rtl") return Qt::RightToLeft;
    if (value == "auto") return text.isRightToLeft() ? Qt::RightToLeft : Qt::LeftToRight;
    if (value.isEmpty()) return inherited == Qt::RightToLeft ? Qt::RightToLeft : Qt::LeftToRight;
    throw std::runtime_error("invalid Ruby direction");
}
inline void validateLeaf(const QJsonObject &span) {
    if (hasPadding(span) || SemanticHtml::present(span.value("ruby")) || SemanticHtml::present(span.value("image"))
        || SemanticHtml::present(span.value("link_paint"))) throw std::runtime_error("Ruby child capability not yet installed");
    const QString kind = span.value("kind").toString();
    if (kind != "text" && kind != "link" && kind != "external_link") throw std::runtime_error("invalid Ruby child kind");
    const QString text = plain(QJsonArray{span});
    for (const QChar c : text) if (c == QChar(0) || c == '\t' || c == '\n' || c == '\r' || c == '\f'
        || c == QChar::ParagraphSeparator || c == QChar::LineSeparator || c == QChar::ObjectReplacementCharacter)
        throw std::runtime_error("Ruby body requires an ordinary single-line text child");
    if (kind == "text" ? !span.value("target").toString().isEmpty()
        : span.value("target").toString().isEmpty() || span.value("text").toString().isEmpty())
        throw std::runtime_error("invalid Ruby child action");
    if (!span.value("direction").toString().isEmpty())
        throw std::runtime_error("Ruby leaf bidi isolation not yet installed");
}
inline QString href(const QJsonObject &span) {
    const auto target = span.value("target").toString();
    if (span.value("kind") == "link") {
        QString result = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target));
        if (SemanticHtml::present(span.value("target_fragment")))
            result += QChar('#') + QString::fromLatin1(QUrl::toPercentEncoding(span.value("target_fragment").toString()));
        return result;
    }
    if (span.value("kind") != "external_link") return {};
    QUrl url(target);
    if (target.startsWith("//") && url.scheme().isEmpty()) url.setScheme("https");
    if (!url.isValid() || url.host().isEmpty() || (url.scheme() != "http" && url.scheme() != "https"))
        throw std::runtime_error("unsupported Ruby external action");
    return url.toString(QUrl::FullyEncoded);
}
inline void requireOwnerPolicy(const QJsonObject &owner, bool outer = false) {
    const auto style = owner.value("inline_style").toObject();
    for (const auto &key : {"wrap", "cursor", "decoration"})
        if (SemanticHtml::present(style.value(key)))
            throw std::runtime_error("Ruby declaring-owner interaction/decoration policy not yet installed");
    if (outer && SemanticHtml::present(style.value("line_height")))
        throw std::runtime_error("outer Ruby used line-height owner not yet installed");
}
inline ImportedChild insertChild(QTextCursor &cursor, const QJsonObject &owner,
        const QJsonArray &spans, const Context &context, const ResolvedOwner &outer,
        const Placement &outerPlacement, bool underline, bool strike, const QTextCharFormat &provenance,
        bool reading = false) {
    requireOwnerPolicy(owner);
    const ResolvedOwner resolved = resolveOwner(owner, context);
    const auto placement = place(resolved, &outerPlacement);
    const qreal groupShift = placement.shift;
    if (!context.actionOwnerCounter || *context.actionOwnerCounter >= (1 << 20))
        throw std::runtime_error("Ruby action-owner budget exceeded");
    const qint64 actionOwner = ++*context.actionOwnerCounter;
    const QBrush inheritedInk = resolved.format.foreground().style() != Qt::NoBrush ? resolved.format.foreground()
        : outer.format.foreground().style() != Qt::NoBrush ? outer.format.foreground() : context.foreground;
    QJsonArray children = spans;
    std::optional<QTextRubyLayout::InlinePadding> padding;
    QString inheritedAction;
    if (spans.size() == 1 && hasPadding(spans.first().toObject())) {
        if (!reading) throw std::runtime_error("inline padding is only supported in a complete Ruby reading");
        const auto groupSpan = spans.first().toObject();
        const auto group = paddingGroup(groupSpan);
        children = array(group.value("spans"));
        QJsonObject groupOwner{{"font", spanFont(groupSpan)}, {"direction", ""},
            {"inline_style", groupSpan.value("inline_style")}, {"foreground", groupSpan.value("foreground")},
            {"background", groupSpan.value("background")}};
        requireOwnerPolicy(groupOwner);
        if (SemanticHtml::present(groupSpan.value("inline_style").toObject().value("line_height")))
            throw std::runtime_error("inline padding group line-height not yet supported");
        const auto declaring = resolveOwner(groupOwner, context);
        if (place(declaring, &placement).shift != groupShift)
            throw std::runtime_error("shifted inline padding group not yet supported");
        padding.emplace(); padding->ownerFont = declaring.font;
        padding->ownerFormat = childFormat(declaring, 0);
        if (padding->ownerFormat.foreground().style() == Qt::NoBrush) padding->ownerFormat.setForeground(inheritedInk);
        padding->ownerFormat.setFontUnderline(groupSpan.value("underline").toBool());
        padding->ownerFormat.setFontStrikeOut(groupSpan.value("strike").toBool());
        for (const auto &key : {"left", "right"}) {
            const auto spec = group.value(key).toObject();
            auto &edge = QLatin1StringView(key) == QLatin1StringView("left") ? padding->left : padding->right;
            edge.value = spec.value("value").toDouble(); edge.em = spec.value("unit") == "em";
        }
        inheritedAction = href(groupSpan);
        if (!inheritedAction.isEmpty()) {
            padding->ownerFormat.setAnchor(true); padding->ownerFormat.setAnchorHref(inheritedAction);
            padding->ownerFormat.setProperty(QCompiledInline::RubyAnchorProperty, actionOwner);
        }
        if (SemanticHtml::present(groupSpan.value("tooltip"))) {
            if (!groupSpan.value("tooltip").isString()) throw std::runtime_error("invalid inline padding tooltip");
            padding->ownerFormat.setToolTip(groupSpan.value("tooltip").toString());
        } else padding->ownerFormat.setToolTip(groupSpan.value("explanation").toString());
        if (plain(children).trimmed().isEmpty()) throw std::runtime_error("empty inline padding group");
    }
    const int first = cursor.position();
    for (const auto &value : children) {
        const auto span = value.toObject(); validateLeaf(span);
        if (padding && plain(QJsonArray{span}).isEmpty())
            throw std::runtime_error("empty inline padding child metrics not yet supported");
        QJsonObject childOwner{{"font", spanFont(span)}, {"direction", ""},
            {"inline_style", span.value("inline_style")}, {"foreground", span.value("foreground")},
            {"background", span.value("background")}};
        const auto child = resolveOwner(childOwner, context);
        QTextCharFormat format = childFormat(child, place(child, &placement).shift - groupShift);
        if (provenance.hasProperty(SemanticHtml::sourceRunProperty))
            format.setProperty(SemanticHtml::sourceRunProperty, provenance.property(SemanticHtml::sourceRunProperty));
        if (format.foreground().style() == Qt::NoBrush)
            format.setForeground(padding ? padding->ownerFormat.foreground() : inheritedInk);
        format.setFontUnderline(span.value("underline").toBool()); format.setFontStrikeOut(span.value("strike").toBool());
        const auto childAction = href(span);
        if (!inheritedAction.isEmpty() && !childAction.isEmpty())
            throw std::runtime_error("competing inline padding child action");
        const auto action = inheritedAction.isEmpty() ? childAction : inheritedAction;
        if (!action.isEmpty()) {
            qint64 id = actionOwner;
            if (padding && inheritedAction.isEmpty()) {
                if (*context.actionOwnerCounter >= (1 << 20)) throw std::runtime_error("Ruby action-owner budget exceeded");
                id = ++*context.actionOwnerCounter;
            }
            format.setAnchor(true); format.setAnchorHref(action);
            format.setProperty(QCompiledInline::RubyAnchorProperty, id);
        }
        if (SemanticHtml::present(span.value("tooltip"))) format.setToolTip(span.value("tooltip").toString());
        else if (padding && !padding->ownerFormat.toolTip().isEmpty()) format.setToolTip(padding->ownerFormat.toolTip());
        else format.setToolTip(span.value("explanation").toString());
        cursor.insertText(span.value("text").toString(), format);
        auto policy = QCompiledInline::policy(format); policy.remove("wrap"); format.setProperty(QCompiledInline::Property, policy);
        cursor.insertText(span.value("trail").toString(), format);
    }
    ImportedChild result;
    result.range = TrackedRange(cursor.document(), first, cursor.position());
    result.native.ownerFont = resolved.font;
    result.native.option = context.option;
    result.native.option.setTextDirection(direction(owner.value("direction").toString(), plain(spans), context.option.textDirection()));
    result.native.usedAbove = resolved.above; result.native.usedBelow = resolved.below;
    result.native.baselineDelta = groupShift;
    result.native.foreground = inheritedInk;
    result.native.background = resolved.format.background();
    result.native.underline = underline; result.native.strike = strike;
    result.native.inlinePadding = padding;
    return result;
}
inline QString collapseGap(const QString &raw, const QString &before, const QString &after) {
    if (raw.isEmpty()) return {};
    if (raw.contains('\f'))
        throw std::runtime_error("Ruby form-feed paint normalization not yet supported");
    if (before.isEmpty() || after.isEmpty())
        throw std::runtime_error("Ruby gap adjoining empty content requires cross-box normalization");
    const auto edge = [](const QString &text, bool last) {
        if (last) {
            const int i = text.size() - 1;
            return text[i].isLowSurrogate() && i > 0 && text[i - 1].isHighSurrogate()
                ? QChar::surrogateToUcs4(text[i - 1], text[i]) : char32_t(text[i].unicode());
        }
        return text[0].isHighSurrogate() && text.size() > 1 && text[1].isLowSurrogate()
            ? QChar::surrogateToUcs4(text[0], text[1]) : char32_t(text[0].unicode());
    };
    const auto left = edge(before, true), right = edge(after, false);
    if (left == ' ' || right == ' ')
        throw std::runtime_error("Ruby gap adjoining body whitespace requires cross-box normalization");
    if (!raw.contains('\n') && !raw.contains('\r')) return QStringLiteral(" ");
    const auto eastAsianLetter = [](char32_t c) {
        const auto script = QChar::script(c);
        return QChar::isLetter(c) && (script == QChar::Script_Han || script == QChar::Script_Hiragana
            || script == QChar::Script_Katakana);
    };
    if (eastAsianLetter(left) && eastAsianLetter(right)) return {};
    // Only these context-independent cases are admitted by this initial
    // transformation. Language-sensitive and punctuation cases need their
    // actual CSS segment-break context, not a guessed universal CJK rule.
    if ((left < 0x80 && !QChar::isSpace(left)) || (right < 0x80 && !QChar::isSpace(right)))
        return QStringLiteral(" ");
    throw std::runtime_error("Ruby segment-break context not yet supported");
}
inline ImportedGap insertGap(QTextCursor &cursor, const QJsonValue &value,
        const QString &before, const QString &after, const Context &context,
        const ResolvedOwner &outer, const Placement &outerPlacement,
        const QTextCharFormat &provenance, bool ordinaryFlow = false, bool hidden = false) {
    const auto raw = gapText(value);
    const int first = cursor.position();
    ImportedGap result;
    bool found = false;
    QTextCharFormat common;
    ResolvedOwner resolved;
    Placement placement;
    for (const auto &item : array(value)) {
        const auto span = item.toObject();
        const auto current = resolveOwner(QJsonObject{{"font", spanFont(span)}, {"direction", ""},
            {"inline_style", span.value("inline_style")}, {"foreground", span.value("foreground")},
            {"background", span.value("background")}}, context);
        const auto position = place(current, &outerPlacement);
        auto format = childFormat(current, ordinaryFlow ? position.shift : 0);
        if (format.foreground().style() == Qt::NoBrush)
            format.setForeground(outer.format.foreground().style() == Qt::NoBrush ? context.foreground : outer.format.foreground());
        format.setFontUnderline(span.value("underline").toBool());
        format.setFontStrikeOut(span.value("strike").toBool());
        format.setToolTip(SemanticHtml::present(span.value("tooltip")) ? span.value("tooltip").toString()
            : span.value("explanation").toString());
        if (provenance.hasProperty(SemanticHtml::sourceRunProperty))
            format.setProperty(SemanticHtml::sourceRunProperty, provenance.property(SemanticHtml::sourceRunProperty));
        if (found && (format != common || position.shift != placement.shift
            || current.above != resolved.above || current.below != resolved.below))
            throw std::runtime_error("distinct styled Ruby gap runs not yet supported");
        found = true; common = format; resolved = current; placement = position;
    }
    if (!hidden && !raw.isEmpty()) {
        cursor.insertText(collapseGap(raw, before, after), common);
        result.logicalText = raw;
        result.child.native.ownerFont = resolved.font;
        result.child.native.option = context.option;
        result.child.native.usedAbove = resolved.above; result.child.native.usedBelow = resolved.below;
        result.child.native.baselineDelta = placement.shift;
        result.child.native.foreground = common.foreground();
    }
    result.child.range = TrackedRange(cursor.document(), first, cursor.position());
    return result;
}
inline Expansion expand(QTextDocument *document,
        const std::function<void(int, int, int)> &replaced = {}) {
    if (!document || document->isLayoutEnabled()) throw std::runtime_error("Ruby expansion requires the owned disabled layout transaction");
    Expansion result; result.document = document;
    struct Marker { QTextCursor cursor; QJsonObject data; QTextCharFormat provenance; };
    QList<Marker> markers;
    for (auto block = document->begin(); block.isValid(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().hasProperty(SemanticHtml::rubyImportProperty)) continue;
            for (const auto c : fragment.text()) if (c != QChar(0xe000))
                throw std::runtime_error("Ruby import anchor lost its exact extent");
            const auto data = fragment.charFormat().property(SemanticHtml::rubyImportProperty);
            if (data.metaType() != QMetaType::fromType<QJsonObject>()) throw std::runtime_error("invalid generated Ruby import metadata");
            for (int i = 0; i < fragment.length(); ++i) {
                QTextCursor cursor(document); cursor.setPosition(fragment.position() + i);
                cursor.setPosition(fragment.position() + i + 1, QTextCursor::KeepAnchor);
                markers.append({cursor, data.value<QJsonObject>(), fragment.charFormat()});
            }
        }
    qint64 nextActionOwner = 0;
    for (auto &marker : markers) {
        const auto span = marker.data.value("span").toObject();
        if (SemanticHtml::present(span.value("background")))
            throw std::runtime_error("whole Ruby container background not yet installed");
        Context context{marker.provenance.font().resolve(document->defaultFont()), marker.data.value("body_points").toDouble(),
            document->documentLayout()->paintDevice(), document->defaultTextOption(), marker.provenance.foreground()};
        context.actionOwnerCounter = &nextActionOwner;
        context.egyptianFamily = marker.data.value("egyptian_family").toString();
        context.option.setTextDirection(marker.cursor.blockFormat().layoutDirection());
        const qreal points = marker.data.value("context_points").toDouble();
        if (!std::isfinite(points) || points < 0) throw std::runtime_error("Ruby original context is missing");
        if (points > 0) context.originalFont.setPointSizeF(points);
        QJsonObject outerOwner{{"font", spanFont(span)}, {"direction", span.value("direction")},
            {"inline_style", span.value("inline_style")}, {"foreground", span.value("foreground")}, {"background", span.value("background")}};
        requireOwnerPolicy(outerOwner, true);
        const auto outer = resolveOwner(outerOwner, context);
        const auto outerPlacement = place(outer);
        const auto ruby = SemanticHtml::inlineObject(span.value("ruby"), {"segments"}, {"segments"});
        const auto segments = array(ruby.value("segments"));
        if (segments.isEmpty() || segments.size() > 65536) throw std::runtime_error("invalid Ruby segment census");
        if (span.value("underline").toBool() || span.value("strike").toBool()) {
            for (const auto &rawSegment : segments) {
                const auto segment = rawSegment.toObject();
                bool hasGap = !gapText(segment.value("gap_before")).isEmpty();
                for (const auto &base : array(segment.value("bases")))
                    hasGap |= !gapText(base.toObject().value("gap_before")).isEmpty();
                for (const auto &reading : array(segment.value("annotations")))
                    hasGap |= !gapText(reading.toObject().value("gap_before")).isEmpty();
                if (hasGap) throw std::runtime_error("Ruby decoration across allocated gaps not yet supported");
            }
        }
        marker.cursor.removeSelectedText();
        ImportedOwner imported; const int ownerFirst = marker.cursor.position();
        QString previousSegmentBases;
        for (const auto &raw : segments) {
            const auto segment = SemanticHtml::inlineObject(raw, {"gap_before", "bases", "annotations"}, {"gap_before", "bases", "annotations"});
            ImportedSegment output;
            const auto bases = array(segment.value("bases"));
            if (bases.isEmpty() || bases.size() > 65536) throw std::runtime_error("invalid Ruby base census");
            QStringList baseText, baseGapText;
            QString segmentBases;
            for (const auto &rawBase : bases) {
                const auto base = rawBase.toObject();
                baseText.append(plain(array(base.value("spans"))));
                baseGapText.append(gapText(base.value("gap_before")));
                segmentBases += baseGapText.last() + baseText.last();
            }
            if (imported.segments.isEmpty() && !gapText(segment.value("gap_before")).isEmpty())
                throw std::runtime_error("leading Ruby segment gap");
            output.gap = insertGap(marker.cursor, segment.value("gap_before"), previousSegmentBases,
                segmentBases, context, outer, outerPlacement, marker.provenance, true);
            const int segmentFirst = marker.cursor.position();
            for (const auto &rawBase : bases) {
                const auto base = SemanticHtml::inlineObject(rawBase, {"owner", "gap_before", "spans"}, {"owner", "gap_before", "spans"});
                const int index = output.bases.size();
                if (!index && !baseGapText[index].isEmpty()) throw std::runtime_error("leading Ruby base gap");
                output.baseGaps.append(insertGap(marker.cursor, base.value("gap_before"), index ? baseText[index - 1] : QString(),
                    baseText[index], context, outer, outerPlacement, marker.provenance));
                const auto body = array(base.value("spans"));
                output.bases.append(insertChild(marker.cursor, base.value("owner").toObject(), body, context, outer,
                    outerPlacement, span.value("underline").toBool(), span.value("strike").toBool(), marker.provenance));
            }
            int previousLevel = -1, previousEnd = 0;
            QString previousReading;
            for (const auto &rawReading : array(segment.value("annotations"))) {
                const auto reading = SemanticHtml::inlineObject(rawReading,
                    {"owner", "base_start", "base_count", "level", "gap_before", "spans", "fallback_before", "fallback_after", "explicit_fallback"},
                    {"owner", "base_start", "base_count", "level", "gap_before", "spans", "fallback_before", "fallback_after", "explicit_fallback"});
                const int start = integer(reading.value("base_start")), count = integer(reading.value("base_count")), level = integer(reading.value("level"));
                if (!count || start >= bases.size() || count > bases.size() - start || level < previousLevel || level > previousLevel + 1)
                    throw std::runtime_error("invalid Ruby association");
                if (level != previousLevel) {
                    previousEnd = 0; previousReading.clear();
                    if (!gapText(reading.value("gap_before")).isEmpty()) throw std::runtime_error("leading Ruby annotation gap");
                }
                if (start < previousEnd) throw std::runtime_error("overlapping Ruby associations");
                previousLevel = level; previousEnd = start + count;
                QString covered;
                for (int i = start; i < start + count; ++i) covered += (i == start ? QString() : baseGapText[i]) + baseText[i];
                const auto body = array(reading.value("spans"));
                const auto readingText = plain(body);
                const bool hidden = readingText == covered;
                if (!reading.value("explicit_fallback").isBool()) throw std::runtime_error("invalid Ruby fallback flag");
                for (const auto &key : {"fallback_before", "fallback_after"})
                    for (const auto &leaf : array(reading.value(key))) validateLeaf(leaf.toObject());
                const auto gap = insertGap(marker.cursor, reading.value("gap_before"), previousReading,
                    readingText, context, outer, outerPlacement, marker.provenance, false, hidden);
                ImportedChild child;
                if (hidden) {
                    // Validate hidden payload and declaring owner without inventing glyphs/actions.
                    for (const auto &leaf : body) validateLeaf(leaf.toObject());
                    child = insertChild(marker.cursor, reading.value("owner").toObject(), {}, context, outer,
                        outerPlacement, false, false, marker.provenance);
                } else child = insertChild(marker.cursor, reading.value("owner").toObject(), body, context, outer,
                    outerPlacement, false, false, marker.provenance, true);
                output.readings.append({child, start, count, level, hidden, gap});
                previousReading = hidden ? QString() : readingText;
            }
            output.range = TrackedRange(document, segmentFirst, marker.cursor.position());
            output.direction = direction(span.value("direction").toString(), baseText.join(QString()), context.option.textDirection());
            output.baselineOrigin = outerPlacement.shift;
            imported.segments.append(output);
            previousSegmentBases = segmentBases;
        }
        if (marker.cursor.position() == ownerFirst) throw std::runtime_error("empty complete Ruby owner not yet installed");
        imported.range = TrackedRange(document, ownerFirst, marker.cursor.position()); result.owners.append(imported);
        if (replaced) replaced(ownerFirst, 1, marker.cursor.position() - ownerFirst);
    }
    return result;
}
struct Finalized { QVariantList descriptors; std::unique_ptr<QTextRubyRangeMap> map; };
inline Finalized finalize(const Expansion &expansion, QVariantList descriptors) {
    auto *document = expansion.document.data();
    if (!document) throw std::runtime_error("Ruby document was replaced during composition");
    if (expansion.empty()) return {descriptors, {}};
    const auto stored = document->toRawText();
    QString semantic;
    QList<QTextRubyRangeMap::Piece> pieces;
    int documentPosition = 0;
    const auto ordinary = [&](int first, int last) -> QTextRubyRangeMap::Range {
        if (first != documentPosition || last < first || last > stored.size())
            throw std::runtime_error("Ruby logical traversal lost document coverage");
        const int begin = semantic.size();
        if (first != last) {
            semantic += stored.mid(first, last - first);
            pieces.append({{begin, int(semantic.size())}, {first, last}, false});
        }
        documentPosition = last;
        return {begin, int(semantic.size())};
    };
    const auto gapRange = [&](const ImportedGap &gap) -> QTextRubyRangeMap::Range {
        const auto range = gap.child.range.native();
        if (range.first != documentPosition || range.last < range.first || range.last > stored.size())
            throw std::runtime_error("Ruby gap lost document coverage");
        const auto painted = stored.mid(range.first, range.last - range.first);
        if (!painted.isEmpty() && painted != QStringLiteral(" "))
            throw std::runtime_error("Ruby gap storage changed during composition");
        const int begin = semantic.size();
        semantic += gap.logicalText;
        if (!gap.logicalText.isEmpty())
            pieces.append({{begin, int(semantic.size())}, {range.first, range.last}, true});
        else if (!painted.isEmpty()) throw std::runtime_error("Ruby empty gap gained storage");
        documentPosition = range.last;
        return {begin, int(semantic.size())};
    };
    QList<QTextRubyRangeMap::Owner> roots;
    struct Part { int first, last; QVariantMap value; bool used = false; };
    QList<Part> replacements;
    for (const auto &owner : expansion.owners) {
        ordinary(documentPosition, owner.range.first.position());
        QTextRubyRangeMap::Owner root; root.range.first = semantic.size();
        for (const auto &segment : owner.segments) {
            QTextRubyRangeMap::Segment logical;
            logical.gap = gapRange(segment.gap);
            QTextRubyLayout::Description native; native.direction = segment.direction; native.baselineOrigin = segment.baselineOrigin;
            native.actionFormat = segment.actionFormat;
            for (int index = 0; index < segment.bases.size(); ++index) {
                const auto &base = segment.bases[index];
                const auto &gap = segment.baseGaps[index];
                const auto logicalGap = gapRange(gap);
                auto child = base.native; child.source = base.range.native(); native.bases.append(child); native.gaps.append(0);
                if (gap.child.range.first.position() != gap.child.range.last.position()) {
                    auto gapChild = gap.child.native; gapChild.source = gap.child.range.native();
                    native.gapSources.append({gapChild, index, -1});
                }
                const auto range = ordinary(child.source.first, child.source.last);
                logical.bases.append({logicalGap, {range, {}}});
            }
            for (int index = 0; index < segment.readings.size(); ++index) {
                const auto &reading = segment.readings[index];
                const auto logicalGap = gapRange(reading.gap);
                auto child = reading.child.native; child.source = reading.child.range.native();
                native.readings.append({child, reading.start, reading.count, reading.level, reading.hidden});
                if (reading.gap.child.range.first.position() != reading.gap.child.range.last.position()) {
                    auto gapChild = reading.gap.child.native; gapChild.source = reading.gap.child.range.native();
                    native.gapSources.append({gapChild, -1, index});
                }
                const auto range = ordinary(child.source.first, child.source.last);
                logical.annotations.append({reading.start, reading.count, reading.level, reading.hidden,
                    logicalGap, {range, {}}});
            }
            root.segments.append(logical);
            const int first = segment.range.first.position(), last = segment.range.last.position();
            replacements.append({first, last, {{"kind", "ruby"}, {"anchor", first}, {"value", QVariant::fromValue(native)}}, false});
        }
        if (documentPosition != owner.range.last.position()) throw std::runtime_error("Ruby owner lost its complete extent");
        root.range.last = semantic.size();
        roots.append(root);
    }
    std::sort(replacements.begin(), replacements.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    const auto splice = [&](auto &&self, const QVariantList &parts) -> QVariantList {
        QVariantList result;
        for (qsizetype index = 0; index < parts.size(); ++index) {
            auto part = parts[index].toMap();
            if (part.value("kind") == "scope") { part.insert("parts", self(self, part.value("parts").toList())); result.append(part); continue; }
            if (part.value("kind") != "text") { result.append(part); continue; }
            int position = part.value("first").toInt(); int end = part.value("last").toInt();
            for (auto &ruby : replacements) {
                if (ruby.last <= position || ruby.first >= end) continue;
                if (ruby.used || ruby.first < position) throw std::runtime_error("Ruby crosses a compiled logical part");
                const auto block = document->findBlock(ruby.first);
                if (!block.isValid() || document->findBlock(ruby.last - 1) != block)
                    throw std::runtime_error("Ruby crosses ordinary paragraph");
                if (ruby.first > position) { auto prefix = part; prefix.insert("first", position); prefix.insert("last", ruby.first); result.append(prefix); }
                // Font/action changes split one inline run into QTextFragments.
                // Consume only exact text siblings; structural boundaries remain barriers.
                while (end < ruby.last) {
                    if (index + 1 >= parts.size()) throw std::runtime_error("Ruby crosses a compiled logical part");
                    const auto next = parts[index + 1].toMap();
                    if (next.value("kind") != "text" || next.value("first").toInt() != end
                        || next.value("last").toInt() <= end)
                        throw std::runtime_error("Ruby crosses a compiled logical part");
                    ++index; part = next; end = part.value("last").toInt();
                }
                result.append(ruby.value); ruby.used = true; position = ruby.last;
            }
            if (position < end) { part.insert("first", position); result.append(part); }
        }
        return result;
    };
    for (auto &raw : descriptors) { auto owner = raw.toMap(); owner.insert("parts", splice(splice, owner.value("parts").toList())); raw = owner; }
    for (const auto &ruby : replacements) if (!ruby.used) {
        const auto block = document->findBlock(ruby.first);
        if (!block.isValid() || document->findBlock(ruby.last - 1) != block) throw std::runtime_error("Ruby crosses ordinary paragraph");
        bool existing = false;
        for (const auto &raw : descriptors) { const auto owner = raw.toMap(); existing |= owner.value("first").toInt() < block.position() + block.length() - 1
            && owner.value("last").toInt() > block.position(); }
        if (existing) throw std::runtime_error("Ruby source is not in its declared flow text");
        QVariantList parts{QVariantMap{{"kind", "text"}, {"first", block.position()}, {"last", block.position() + block.length() - 1}}};
        descriptors.append(QVariantMap{{"first", block.position()}, {"last", block.position() + block.length() - 1},
            {"direction", int(block.blockFormat().layoutDirection())}, {"language", ""}, {"joins", QVariantList{}}, {"parts", splice(splice, parts)}});
    }
    const int end = document->characterCount() - 1;
    ordinary(documentPosition, end);
    QString error;
    auto map = QTextRubyRangeMap::createMany(document, std::move(semantic), std::move(pieces), roots, 1 << 20, &error);
    if (!map) throw std::runtime_error((QStringLiteral("invalid Ruby logical projection: ") + error).toStdString());
    return {descriptors, std::move(map)};
}
} // namespace CompiledRuby
