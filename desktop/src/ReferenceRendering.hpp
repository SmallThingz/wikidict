#pragma once

#include "ReferencePolicy.hpp"
#include "FlowConstruction.hpp"
#include <QPointer>
#include <QTextList>

namespace ReferenceRendering {
inline void begin(QTextDocument *document, quint64 epoch) {
    CompiledContent::require(document && epoch > 0);
    const QPointer<QTextDocument> guard(document);
    document->setProperty(ReferencePolicy::targetProperty, QVariant());
    CompiledContent::require(guard);
    document->setProperty(ReferencePolicy::epochProperty, QVariant::fromValue<qulonglong>(epoch));
}
inline void finalize(QTextDocument *document, const QVector<QPointer<QTextFrame>> &containers,
                     const std::function<bool()> &isCurrent) {
    const QPointer<QTextDocument> guarded(document);
    const auto current = [&] { return guarded && isCurrent && isCurrent(); };
    CompiledContent::require(current() && !document->isLayoutEnabled());
    for (const auto &pointer : containers) {
        CompiledContent::require(current() && pointer && pointer->document() == document);
        const auto original = pointer->frameFormat();
        if (!original.hasProperty(ReferencePolicy::pendingItemProperty)) continue;
        CompiledContent::require(document->documentLayout()->property("_wikidictReferenceLayoutCapability")
            == QVariant(ReferencePolicy::capability));
        const auto source = CompiledReferences::itemSource(ReferencePolicy::source(original.property(ReferencePolicy::pendingItemProperty)));
        const auto reference = source.value("reference").toObject(), item = source.value("item").toObject();
        CompiledContent::require(ReferencePolicy::source(original.property(FlowConstruction::containerSourceProperty))
            == CompiledReferences::itemProjection(reference, item));
        CompiledContent::require(pointer->childFrames().isEmpty());
        QTextBlock principal;
        for (auto it = pointer->begin(); !it.atEnd(); ++it) {
            const auto block = it.currentBlock();
            if (!block.isValid() || !block.isVisible()) continue;
            CompiledContent::require(!principal.isValid()); principal = block;
        }
        CompiledContent::require(principal.isValid() && !principal.textList()
            && QTextCursor(principal).currentFrame() == pointer);
        const auto policy = principal.blockFormat().property(FlowConstruction::containerTypographyProperty).toMap();
        CompiledContent::require(policy.value("font").metaType().id() == QMetaType::QFont
            && qvariant_cast<QFont>(policy.value("font")) == principal.charFormat().font());
        const auto direction = reference.value("body_typography").toObject().value("direction").toString();
        CompiledContent::require(principal.blockFormat().layoutDirection()
            == (direction == QStringLiteral("rtl") ? Qt::RightToLeft : Qt::LeftToRight));
        QTextCursor cursor(principal);
        QTextListFormat list; list.setStyle(QTextListFormat::ListDecimal); list.setIndent(0); list.setStart(1);
        // The typed branch uses the original unsigned counter. Qt's signed list
        // start is only a neutral entry into the existing list paint path.
        const QPointer<QTextList> nativeList(cursor.createList(list));
        CompiledContent::require(current() && pointer && nativeList && nativeList->count() == 1
            && nativeList->item(0) == principal);
        auto format = principal.blockFormat();
        format.setProperty(ReferencePolicy::itemProperty, QVariantMap{{"capability", ReferencePolicy::capability},
            {"source", ReferencePolicy::source(source)},
            {"number", QVariant::fromValue<quint32>(CompiledReferences::integer(reference.value("group_number"), true, true))},
            {"owner", QVariant::fromValue(static_cast<QObject *>(pointer.data()))}});
        cursor.setBlockFormat(format);
        CompiledContent::require(current() && pointer);
        cursor.setPosition(principal.position()); cursor.setPosition(principal.position() + 1, QTextCursor::KeepAnchor);
        auto character = cursor.charFormat(); auto anchors = character.anchorNames();
        const auto anchor = CompiledReferences::referenceAnchor(reference);
        CompiledContent::require(!anchors.contains(anchor)); anchors.append(anchor);
        character.setAnchor(true); character.setAnchorNames(anchors); cursor.setCharFormat(character);
        CompiledContent::require(current() && pointer && !document->isLayoutEnabled());
        auto completed = pointer->frameFormat(); completed.clearProperty(ReferencePolicy::pendingItemProperty);
        pointer->setFrameFormat(completed);
        CompiledContent::require(current());
    }
}
inline bool target(QTextDocument *document, const QString &fragment) {
    CompiledContent::require(document);
    const auto epoch = document->property(ReferencePolicy::epochProperty);
    CompiledContent::require(epoch.metaType().id() == QMetaType::ULongLong && epoch.toULongLong() > 0);
    QVariantMap selected;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        const auto item = block.blockFormat().property(ReferencePolicy::itemProperty);
        if (item.isValid()) {
            CompiledContent::require(item.metaType().id() == QMetaType::QVariantMap);
            const auto map = item.toMap(); const auto source = ReferencePolicy::source(map.value("source"));
            const auto reference = source.value("reference").toObject();
            if (fragment == CompiledReferences::referenceAnchor(reference)) {
                CompiledContent::require(selected.isEmpty());
                selected = {{"kind", QStringLiteral("item")},
                    {"number", QVariant::fromValue<quint32>(CompiledReferences::integer(reference.value("number"), true))},
                    {"source", map.value("source")}, {"epoch", epoch}};
            }
        }
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto text = it.fragment(); if (!text.isValid()) continue;
            const auto raw = text.charFormat().property(ReferencePolicy::citationProperty);
            if (!raw.isValid()) continue;
            CompiledContent::require(raw.metaType().id() == QMetaType::QVariantMap);
            const auto policy = raw.toMap(); const auto span = ReferencePolicy::source(policy.value("source"));
            if (span.value("citation_marker").toObject().value("anchor") != fragment) continue;
            const QVariantMap candidate{{"kind", QStringLiteral("citation")}, {"owner", policy.value("owner")},
                {"source", policy.value("source")}, {"epoch", epoch}};
            CompiledContent::require(selected.isEmpty() || selected == candidate); selected = candidate;
        }
    }
    document->setProperty(ReferencePolicy::targetProperty, selected.isEmpty() ? QVariant() : QVariant(selected));
    return !selected.isEmpty();
}
}
