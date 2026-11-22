#pragma once
#include "CompiledRuby.hpp"
#include <QTextBlock>
#include <QTextCursor>
#include <QUrl>
#include <QSet>
#include <algorithm>

// Decoded source-anchor ownership. This carries no source markup or padding.
namespace CompiledInlineAction {
inline bool present(const QJsonObject &span) {
    return SemanticHtml::present(span.value("inline_action_group"));
}
inline QJsonObject checkedSpan(const QJsonValue &value) {
    const auto span = SemanticHtml::inlineObject(value, {"kind", "role", "text", "target", "trail", "language", "classes",
        "direction", "explanation", "font_scale", "font_scale_basis", "font_features", "link_paint",
        "inline_style", "font_family", "image", "target_fragment", "tooltip", "ruby", "inline_padding_group",
        "inline_action_group", "foreground", "background", "bold", "italic", "small", "subscript",
        "superscript", "code", "underline", "strike"});
    for (const auto &key : {"kind", "text", "target", "trail"})
        if (!span.value(key).isString()) throw std::runtime_error("invalid inline action string field");
    for (const auto &key : {"tooltip", "explanation", "direction", "language", "target_fragment"})
        if (SemanticHtml::present(span.value(key)) && !span.value(key).isString())
            throw std::runtime_error("invalid inline action optional string");
    for (const auto &key : {"underline", "strike", "bold", "italic", "small", "superscript", "subscript", "code"})
        if (span.contains(key) && !span.value(key).isBool())
            throw std::runtime_error("invalid inline action boolean field");
    // Natural bidi shaping remains native. Authored isolation needs a distinct
    // shaping boundary; accepting a direction string alone would discard it.
    if (!span.value("direction").toString().isEmpty())
        throw std::runtime_error("inline action authored bidi isolation is not yet supported");
    return span;
}
inline QJsonArray array(const QJsonValue &value) {
    if (!value.isArray()) throw std::runtime_error("invalid inline action child array");
    return value.toArray();
}
inline bool hasAction(const QJsonObject &span) {
    return span.value("kind") == "link" || span.value("kind") == "external_link";
}
inline QString href(const QJsonObject &owner) {
    const auto target = owner.value("target").toString();
    if (owner.value("kind") == "link") {
        QString result = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(target));
        if (SemanticHtml::present(owner.value("target_fragment")))
            result += QChar('#') + QString::fromLatin1(QUrl::toPercentEncoding(owner.value("target_fragment").toString()));
        return result;
    }
    QUrl result(target);
    if (target.startsWith("//") && result.scheme().isEmpty()) result.setScheme("https");
    if (owner.value("kind") != "external_link" || !result.isValid() || result.host().isEmpty()
        || (result.scheme() != "https" && result.scheme() != "http"))
        throw std::runtime_error("unsupported inline action target");
    return result.toString(QUrl::FullyEncoded);
}
inline QJsonObject group(const QJsonObject &owner) {
    checkedSpan(owner);
    const auto result = SemanticHtml::inlineObject(owner.value("inline_action_group"), {"spans"}, {"spans"});
    if (!hasAction(owner) || !owner.value("target").isString() || owner.value("target").toString().isEmpty()
        || !owner.value("text").isString() || !owner.value("text").toString().isEmpty()
        || !owner.value("trail").isString() || !owner.value("trail").toString().isEmpty()
        || SemanticHtml::present(owner.value("image")) || SemanticHtml::present(owner.value("ruby"))
        || SemanticHtml::present(owner.value("inline_padding_group")) || array(result.value("spans")).isEmpty())
        throw std::runtime_error("invalid inline action group owner");
    for (const auto &name : {"underline", "strike", "bold", "italic", "small", "superscript", "subscript", "code"})
        if (owner.contains(name) && !owner.value(name).isBool()) throw std::runtime_error("invalid inline action font flag");
    for (const auto &name : {"tooltip", "explanation", "direction"})
        if (SemanticHtml::present(owner.value(name)) && !owner.value(name).isString())
            throw std::runtime_error("invalid inline action metadata");
    if (SemanticHtml::present(owner.value("target_fragment"))
        && (owner.value("kind") != "link" || !owner.value("target_fragment").isString()))
        throw std::runtime_error("invalid inline action fragment");
    const auto direction = owner.value("direction").toString();
    if (!direction.isEmpty() && direction != "ltr" && direction != "rtl" && direction != "auto")
        throw std::runtime_error("invalid inline action direction");
    CompiledRuby::spanFont(owner);
    // The owner is structural; validate its existing style against real semantic
    // text without publishing that validation value or changing its font basis.
    auto styleOwner = owner; styleOwner.insert("kind", "text"); styleOwner.insert("target", "");
    styleOwner.insert("text", "X"); styleOwner.insert("trail", "");
    SemanticHtml::inlineTextStyle(styleOwner);
    for (const auto &name : {"foreground", "background"})
        if (SemanticHtml::present(owner.value(name))) SemanticHtml::styleColor(owner.value(name));
    if (SemanticHtml::present(owner.value("link_paint"))) {
        if (!owner.value("link_paint").isObject()) throw std::runtime_error("invalid inline action paint");
        const auto paint = owner.value("link_paint").toObject();
        MissingFigurePaint::validateOrdinary(paint, 1);
        if (owner.value("underline").toBool() != paint.value("normal").toObject().value("underline").toBool()
            || (SemanticHtml::present(owner.value("foreground"))
                && owner.value("foreground") != paint.value("normal").toObject().value("foreground")))
            throw std::runtime_error("inline action owner paint conflicts with its normal state");
    }
    href(owner);
    return result;
}
inline void noDescendantAction(const QJsonObject &span) {
    if (span.value("kind") != "text" || !span.value("target").toString().isEmpty()
        || SemanticHtml::present(span.value("target_fragment")) || SemanticHtml::present(span.value("link_paint"))
        || present(span)) throw std::runtime_error("competing inline action descendant");
}
inline void validateBody(const QJsonArray &spans, const QJsonObject &owner,
                         int contentDepth, int rubyDepth, qsizetype &remaining, bool gap = false) {
    if (contentDepth > 16 || rubyDepth > 16 || spans.size() > remaining)
        throw std::runtime_error("inline action presentation budget exceeded");
    remaining -= spans.size();
    for (const auto &raw : spans) {
        const auto span = checkedSpan(raw); noDescendantAction(span);
        if (SemanticHtml::present(span.value("image"))) throw std::runtime_error("inline action image domain not admitted");
        const bool ruby = SemanticHtml::present(span.value("ruby"));
        const bool padding = SemanticHtml::present(span.value("inline_padding_group"));
        if ((ruby && padding) || (gap && (ruby || padding))) throw std::runtime_error("invalid inline action structural child");
        if (!span.value("text").isString() || !span.value("trail").isString())
            throw std::runtime_error("invalid inline action text child");
        for (QChar c : span.value("text").toString() + span.value("trail").toString())
            if (c == QChar(0) || c == QChar::ObjectReplacementCharacter || c == QChar::ParagraphSeparator
                || c == QChar::LineSeparator || (!gap && (c == '\t' || c == '\n' || c == '\r' || c == '\f')))
                throw std::runtime_error("unsupported inline action text control");
        CompiledRuby::spanFont(span);
        if (SemanticHtml::present(owner.value("link_paint")) && !gap) {
            const auto normal = owner.value("link_paint").toObject().value("normal").toObject();
            if (SemanticHtml::present(span.value("foreground")) && span.value("foreground") != normal.value("foreground"))
                throw std::runtime_error("inline action descendant has incompatible state foreground");
        }
        if (padding) {
            const auto payload = SemanticHtml::inlineObject(span.value("inline_padding_group"), {"left", "right", "spans"}, {"left", "right", "spans"});
            bool nonzero = false;
            for (const auto &name : {"left", "right"}) {
                const auto edge = SemanticHtml::inlineObject(payload.value(name), {"unit", "value"}, {"unit", "value"});
                if (edge.value("unit") != "px" && edge.value("unit") != "em") throw std::runtime_error("invalid action child padding unit");
                nonzero |= SemanticHtml::inlineNumber(edge.value("value")) != 0;
            }
            const auto children = array(payload.value("spans"));
            if (!nonzero || children.isEmpty() || !span.value("text").toString().isEmpty() || !span.value("trail").toString().isEmpty())
                throw std::runtime_error("invalid action child padding owner");
            validateBody(children, owner, contentDepth + 1, rubyDepth, remaining);
        } else if (ruby) {
            const auto payload = SemanticHtml::inlineObject(span.value("ruby"), {"segments"}, {"segments"});
            const auto segments = array(payload.value("segments"));
            if (contentDepth >= 16 || rubyDepth >= 16 || segments.isEmpty() || segments.size() > remaining
                || !span.value("text").toString().isEmpty() || !span.value("trail").toString().isEmpty())
                throw std::runtime_error("invalid action child Ruby owner");
            remaining -= segments.size();
            for (const auto &rawSegment : segments) {
                const auto segment = SemanticHtml::inlineObject(rawSegment, {"gap_before", "bases", "annotations"}, {"gap_before", "bases", "annotations"});
                validateBody(array(segment.value("gap_before")), owner, contentDepth + 1, rubyDepth + 1, remaining, true);
                for (const auto &key : {"bases", "annotations"}) {
                    const auto children = array(segment.value(key));
                    if (children.size() > remaining) throw std::runtime_error("inline action Ruby budget exceeded");
                    remaining -= children.size();
                    for (const auto &rawChild : children) {
                        if (!rawChild.isObject()) throw std::runtime_error("invalid action Ruby child");
                        const auto child = rawChild.toObject();
                        validateBody(array(child.value("spans")), owner, contentDepth + 1, rubyDepth + 1, remaining);
                        validateBody(array(child.value("gap_before")), owner, contentDepth + 1, rubyDepth + 1, remaining, true);
                        if (QLatin1StringView(key) == QLatin1StringView("annotations"))
                            for (const auto &fallback : {"fallback_before", "fallback_after"})
                                validateBody(array(child.value(fallback)), owner, contentDepth + 1, rubyDepth + 1, remaining, true);
                    }
                }
            }
        }
    }
}
inline void validateEntry(const QJsonObject &entry) {
    CompiledRuby::validatePaddingEntry(entry, [](const QJsonObject &span, int depth, int rubyDepth, qsizetype &remaining) {
        if (!present(span)) return false;
        validateBody(array(group(span).value("spans")), span, depth + 1, rubyDepth, remaining);
        return true;
    });
}
inline QString marker(const QJsonObject &span, qint64 identity, qreal bodyPoints,
        qreal contextPoints, int sourceRun, const QJsonValue &contextFamily, const QString &egyptianFamily) {
    group(span);
    if (identity < (qint64(1) << 32) || identity >= (qint64(1) << 33))
        throw std::runtime_error("inline action identity budget exceeded");
    const QJsonObject data{{"span", span}, {"owner", double(identity)}, {"body_points", bodyPoints},
        {"context_points", contextPoints}, {"egyptian_family", egyptianFamily}};
    return SemanticHtml::scaledText(QStringLiteral("&#xe000;"), 1, {}, SemanticHtml::Basis::Context,
        0, false, false, false, 0, {}, true, sourceRun, {}, -1, 0, false, {}, false, {}, 0, 0,
        {}, contextFamily, {}, data);
}
struct Owner {
    int first = 0, last = 0;
    QTextCharFormat action;
    CompiledRuby::ResolvedOwner declaring;
};
struct EmptyMetric { int position = 0; QTextCharFormat action; };
struct Expansion {
    QPointer<QTextDocument> document;
    QList<Owner> owners;
    QList<EmptyMetric> emptyMetrics;
    void replaced(int first, int removed, int inserted) {
        const auto adjust = [=](int &position) {
            if (position >= first + removed) position += inserted - removed;
            else if (position > first) throw std::runtime_error("inline action boundary splits a Ruby marker");
        };
        for (auto &owner : owners) { adjust(owner.first); adjust(owner.last); }
        for (auto &metric : emptyMetrics) adjust(metric.position);
    }
};
inline QTextCharFormat actionFormat(const QJsonObject &span, qint64 identity,
        const CompiledRuby::ResolvedOwner &declaring, const CompiledRuby::Context &context) {
    QTextCharFormat action;
    action.setAnchor(true); action.setAnchorHref(href(span));
    action.setProperty(QCompiledInline::ActionOwnerProperty, identity);
    auto metric = declaring.format;
    if (metric.foreground().style() == Qt::NoBrush) metric.setForeground(context.foreground);
    metric.setFontUnderline(span.value("underline").toBool());
    metric.setFontStrikeOut(span.value("strike").toBool());
    action.setProperty(QCompiledInline::ActionMetricProperty, QVariant::fromValue(QTextFormat(metric)));
    if (SemanticHtml::present(span.value("tooltip"))) action.setToolTip(span.value("tooltip").toString());
    else action.setToolTip(span.value("explanation").toString());
    if (SemanticHtml::present(span.value("link_paint"))) {
        const auto paint = span.value("link_paint").toObject();
        const qreal em = declaring.font.pointSizeF() * QFontMetricsF(QFont()).fontDpi() / 72;
        MissingFigurePaint::validateOrdinary(paint, em);
        action.setProperty(MissingFigurePaint::policyProperty, MissingFigurePaint::ordinaryPolicy);
        action.setProperty(MissingFigurePaint::ownerProperty, identity);
        action.setProperty(MissingFigurePaint::fixedPolicyProperty, paint.toVariantMap());
        action.setProperty(MissingFigurePaint::outlineProperty, MissingFigurePaint::outline(paint, em));
        action.setProperty(MissingFigurePaint::underlineProperty, span.value("underline").toBool());
        action.setProperty(MissingFigurePaint::zeroFontProperty, false);
    }
    if (!QCompiledInline::actionMetric(action)) throw std::runtime_error("invalid resolved inline action owner");
    return action;
}
inline Expansion expand(QTextDocument *document) {
    if (!document || document->isLayoutEnabled())
        throw std::runtime_error("inline action expansion requires the owned disabled layout transaction");
    Expansion result; result.document = document;
    struct Marker { QTextCursor cursor; QJsonObject data; QTextCharFormat provenance; };
    QList<Marker> markers;
    for (auto block = document->begin(); block.isValid(); block = block.next())
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().hasProperty(SemanticHtml::actionImportProperty)) continue;
            const auto data = fragment.charFormat().property(SemanticHtml::actionImportProperty);
            if (data.metaType() != QMetaType::fromType<QJsonObject>())
                throw std::runtime_error("invalid inline action import metadata");
            for (int i = 0; i < fragment.length(); ++i) {
                if (fragment.text().at(i) != QChar(0xe000)) throw std::runtime_error("inline action import extent changed");
                QTextCursor cursor(document); cursor.setPosition(fragment.position() + i);
                cursor.setPosition(fragment.position() + i + 1, QTextCursor::KeepAnchor);
                markers.append({cursor, data.value<QJsonObject>(), fragment.charFormat()});
            }
        }
    QSet<qint64> identities;
    for (auto &item : markers) {
        const auto span = item.data.value("span").toObject(); const auto payload = group(span);
        const double rawIdentity = item.data.value("owner").toDouble(-1);
        if (!std::isfinite(rawIdentity) || rawIdentity != std::floor(rawIdentity)
            || rawIdentity < double(qint64(1) << 32) || rawIdentity >= double(qint64(1) << 33)
            || identities.contains(qint64(rawIdentity))) throw std::runtime_error("invalid inline action occurrence identity");
        const qint64 identity = qint64(rawIdentity); identities.insert(identity);
        CompiledRuby::Context context{item.provenance.font().resolve(document->defaultFont()),
            item.data.value("body_points").toDouble(), document->documentLayout()->paintDevice(),
            document->defaultTextOption(), item.provenance.foreground()};
        context.egyptianFamily = item.data.value("egyptian_family").toString();
        const qreal points = item.data.value("context_points").toDouble();
        if (!std::isfinite(points) || points < 0) throw std::runtime_error("inline action original font context missing");
        if (points > 0) context.originalFont.setPointSizeF(points);
        const auto resolved = CompiledRuby::resolveOwner(QJsonObject{{"font", CompiledRuby::spanFont(span)},
            {"direction", span.value("direction").toString()}, {"inline_style", span.value("inline_style")},
            {"foreground", span.value("foreground")}, {"background", span.value("background")}}, context);
        const auto action = actionFormat(span, identity, resolved, context);
        item.cursor.removeSelectedText(); const int first = item.cursor.position();
        for (const auto &raw : array(payload.value("spans"))) {
            const auto child = checkedSpan(raw); noDescendantAction(child);
            if (SemanticHtml::present(child.value("inline_padding_group")))
                throw std::runtime_error("inline padding outside a complete Ruby reading is not yet supported");
            if (SemanticHtml::present(child.value("ruby"))) {
                auto format = item.provenance;
                format.clearProperty(SemanticHtml::actionImportProperty);
                format.setProperty(SemanticHtml::rubyImportProperty, QVariant::fromValue(QJsonObject{
                    {"span", child}, {"body_points", context.bodyPoints}, {"context_points", points},
                    {"egyptian_family", context.egyptianFamily}}));
                format.merge(action); item.cursor.insertText(QString(QChar(0xe000)), format);
                continue;
            }
            const auto childOwner = CompiledRuby::resolveOwner(QJsonObject{{"font", CompiledRuby::spanFont(child)},
                {"direction", child.value("direction").toString()}, {"inline_style", child.value("inline_style")},
                {"foreground", child.value("foreground")}, {"background", child.value("background")}}, context);
            auto format = CompiledRuby::childFormat(childOwner, CompiledRuby::place(childOwner).shift);
            if (item.provenance.hasProperty(SemanticHtml::sourceRunProperty))
                format.setProperty(SemanticHtml::sourceRunProperty, item.provenance.property(SemanticHtml::sourceRunProperty));
            if (format.foreground().style() == Qt::NoBrush)
                format.setForeground(resolved.format.foreground().style() != Qt::NoBrush ? resolved.format.foreground() : context.foreground);
            format.setFontUnderline(child.value("underline").toBool());
            format.setFontStrikeOut(child.value("strike").toBool());
            format.merge(action);
            if (SemanticHtml::present(child.value("tooltip"))) format.setToolTip(child.value("tooltip").toString());
            else if (!child.value("explanation").toString().isEmpty()) format.setToolTip(child.value("explanation").toString());
            if (child.value("text").toString().isEmpty() && child.value("trail").toString().isEmpty()) {
                auto empty = action;
                empty.setProperty(QCompiledInline::ActionMetricProperty, QVariant::fromValue(QTextFormat(childOwner.format)));
                result.emptyMetrics.append({item.cursor.position(), empty});
            }
            item.cursor.insertText(child.value("text").toString(), format);
            auto policy = QCompiledInline::policy(format); policy.remove("wrap");
            if (policy.size() == 2 && !policy.value("normalized").toBool()) format.clearProperty(QCompiledInline::Property);
            else if (!policy.isEmpty()) format.setProperty(QCompiledInline::Property, policy);
            item.cursor.insertText(child.value("trail").toString(), format);
        }
        result.owners.append({first, item.cursor.position(), action, resolved});
    }
    return result;
}
inline QVariantList finalize(const Expansion &expansion, CompiledRuby::Expansion &ruby) {
    auto *document = expansion.document.data();
    if (!document || document->isLayoutEnabled() || ruby.document != document)
        throw std::runtime_error("inline action finalization lost its owned document");
    QVariantList registry;
    for (const auto &owner : expansion.owners) {
        const int first = owner.first, last = owner.last;
        if (first < 0 || last < first || last >= document->characterCount()
            || document->findBlock(first) != document->findBlock(last))
            throw std::runtime_error("inline action crosses its original native block");
        registry.append(QVariantMap{{"first", first}, {"last", last},
            {"format", QVariant::fromValue(QTextFormat(owner.action))}});
        for (auto &rubyOwner : ruby.owners) {
            if (rubyOwner.range.last.position() <= first || rubyOwner.range.first.position() >= last) continue;
            if (rubyOwner.range.first.position() < first || rubyOwner.range.last.position() > last)
                throw std::runtime_error("inline action partially owns a Ruby container");
            for (auto &segment : rubyOwner.segments) {
                segment.actionFormat = owner.action;
                const auto apply = [&](const CompiledRuby::ImportedChild &child) {
                    if (child.range.first.position() == child.range.last.position()) return;
                    // No fonts or local decoration are replaced; Ruby gaps and
                    // terminal fallback punctuation never receive an action.
                    QList<QPair<QTextCursor, QTextCharFormat>> pieces;
                    for (auto block = document->findBlock(child.range.first.position());
                         block.isValid() && block.position() < child.range.last.position(); block = block.next()) {
                        for (auto it = block.begin(); !it.atEnd(); ++it) {
                            const auto fragment = it.fragment();
                            const int begin = qMax(fragment.position(), child.range.first.position());
                            const int end = qMin(fragment.position() + fragment.length(), child.range.last.position());
                            if (!fragment.isValid() || begin >= end) continue;
                            auto action = owner.action;
                            if (!fragment.charFormat().toolTip().isEmpty()) action.clearProperty(QTextFormat::TextToolTip);
                            QTextCursor range(document); range.setPosition(begin); range.setPosition(end, QTextCursor::KeepAnchor);
                            pieces.append({range, action});
                        }
                    }
                    for (auto &piece : pieces) piece.first.mergeCharFormat(piece.second);
                };
                for (auto &base : segment.bases) { apply(base); base.native.actionDecoration = owner.action; }
                for (auto &reading : segment.readings) {
                    apply(reading.child);
                    if (reading.child.native.inlinePadding) {
                        auto action = owner.action;
                        auto &format = reading.child.native.inlinePadding->ownerFormat;
                        if (!format.toolTip().isEmpty()) action.clearProperty(QTextFormat::TextToolTip);
                        format.merge(action);
                    }
                }
            }
        }
    }
    QMap<int, QVariantList> empty;
    const auto append = [&](int position, const QTextCharFormat &format) {
        const auto block = document->findBlock(position);
        if (!block.isValid() || position > block.position() + block.text().size()
            || !QCompiledInline::actionMetric(format)) throw std::runtime_error("invalid empty action metric");
        empty[block.position()].append(QVariantMap{{"offset", position - block.position()},
            {"format", QVariant::fromValue(QTextFormat(format))}});
    };
    for (const auto &owner : expansion.owners)
        if (owner.first == owner.last) append(owner.first, owner.action);
    for (const auto &metric : expansion.emptyMetrics) append(metric.position, metric.action);
    for (auto it = empty.cbegin(); it != empty.cend(); ++it) {
        QTextCursor cursor(document); cursor.setPosition(it.key());
        auto format = cursor.blockFormat();
        auto metrics = it.value();
        std::stable_sort(metrics.begin(), metrics.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap().value("offset").toInt() < b.toMap().value("offset").toInt();
        });
        format.setProperty(QCompiledInline::EmptyActionOwners,
            QVariantMap{{"text", cursor.block().text()}, {"owners", metrics}});
        cursor.setBlockFormat(format);
    }
    return registry;
}
} // namespace CompiledInlineAction
