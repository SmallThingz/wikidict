#pragma once

#include "CompiledReferences.hpp"
#include "MissingFigurePaint.hpp"
#include <QJsonDocument>
#include <QTextFormat>

namespace ReferencePolicy {
inline constexpr int itemProperty = QTextFormat::UserProperty + 0x5867;
inline constexpr int citationProperty = QTextFormat::UserProperty + 0x5868;
inline constexpr int pendingItemProperty = QTextFormat::UserProperty + 0x5869;
inline const QString capability = QStringLiteral("wikidict.reference-layout/1");
inline constexpr char targetProperty[] = "wikidict.reference.target";
inline constexpr char epochProperty[] = "wikidict.reference.epoch";
inline QByteArray source(const QJsonObject &value) { return QJsonDocument(value).toJson(QJsonDocument::Compact); }
inline QJsonObject source(const QVariant &value) {
    CompiledContent::require(value.metaType().id() == QMetaType::QByteArray);
    QJsonParseError error;
    const auto parsed = QJsonDocument::fromJson(value.toByteArray(), &error);
    CompiledContent::require(error.error == QJsonParseError::NoError && parsed.isObject()
        && source(parsed.object()) == value.toByteArray());
    return parsed.object();
}
inline QVariantMap citation(const QJsonObject &span, qint64 owner, qreal em) {
    const auto marker = CompiledReferences::marker(span);
    CompiledContent::require(!marker.isEmpty() && owner >= (qint64(1) << 32) && owner < (qint64(1) << 33)
        && std::isfinite(em) && em > 0);
    if (CompiledContent::present(span.value("link_paint"))) MissingFigurePaint::validateOrdinary(span.value("link_paint"), em);
    QVariantMap outline;
    if (CompiledContent::present(marker.value("target_style"))) {
        const auto target = marker.value("target_style").toObject();
        const auto paint = MissingFigurePaint::validateOrdinary(target.value("paint"), em);
        outline = MissingFigurePaint::outline(paint, em);
        if (CompiledContent::present(target.value("background"))) {
            const auto color = target.value("background").toObject();
            CompiledContent::require((color.value("kind") == QStringLiteral("rgb")
                && MissingFigurePaint::canonicalRgb(color.value("value")))
                || (color.value("kind") == QStringLiteral("transparent") && !CompiledContent::present(color.value("value"))));
        }
    }
    return {{"capability", capability}, {"source", source(span)}, {"owner", QVariant::fromValue(owner)},
        {"nowrap", marker.value("nowrap").toBool()}, {"em", double(em)}, {"target_outline", outline}};
}
inline QVariantMap citationImport(const QJsonObject &value) {
    const auto input = CompiledContent::containerObject(value, {"span", "owner", "em"}, {"span", "owner", "em"});
    const auto number = input.value("owner");
    CompiledContent::require(number.isDouble() && std::isfinite(number.toDouble()) && std::floor(number.toDouble()) == number.toDouble()
        && number.toDouble() >= double(qint64(1) << 32) && number.toDouble() < double(qint64(1) << 33)
        && input.value("em").isDouble());
    return citation(CompiledContent::object(input.value("span")), qint64(number.toDouble()), input.value("em").toDouble());
}
inline bool targetedCitation(const QTextDocument *document, const QTextCharFormat &format) {
    if (!document || !format.hasProperty(citationProperty)) return false;
    const auto raw = format.property(citationProperty), state = document->property(targetProperty);
    if (raw.metaType().id() != QMetaType::QVariantMap || state.metaType().id() != QMetaType::QVariantMap) return false;
    const auto policy = raw.toMap(), target = state.toMap(); const auto epoch = document->property(epochProperty);
    return policy.size() == 6 && policy.value("capability").metaType().id() == QMetaType::QString
        && policy.value("capability") == capability && target.size() == 4
        && target.value("kind").metaType().id() == QMetaType::QString && target.value("kind") == QStringLiteral("citation")
        && policy.value("owner").metaType().id() == QMetaType::LongLong
        && policy.value("source").metaType().id() == QMetaType::QByteArray
        && target.value("source").metaType().id() == QMetaType::QByteArray
        && target.value("owner").metaType().id() == QMetaType::LongLong
        && policy.value("owner") == target.value("owner") && policy.value("source") == target.value("source")
        && epoch.metaType().id() == QMetaType::ULongLong && epoch.toULongLong() > 0
        && target.value("epoch").metaType().id() == QMetaType::ULongLong
        && target.value("epoch") == epoch;
}
}
