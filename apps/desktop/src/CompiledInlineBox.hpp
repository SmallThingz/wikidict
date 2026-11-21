#pragma once
#include "CompiledContent.hpp"
#include "CompiledRubyFont.hpp"
#include "SemanticHtml.hpp"
#include <QtGui/private/qtextinlinebox_p.h>
#include <QtGui/private/qtextlogicalflow_p.h>
#include <QTextTable>
#include <QJsonDocument>
#include <QPointer>
#include <QTextDocumentFragment>
#include <QTextImageFormat>
#include <algorithm>

// The marker exists only inside the owned disabled import transaction. The
// installed document contains the original ordinary child characters and links.
namespace CompiledInlineBox {
inline constexpr auto scheme = "wikidict-inline-box:";
inline constexpr auto roundedCapability = "wikidict.inline-box-rounded-link/1";
inline constexpr auto overlayCapability = "wikidict.inline-box-overlay/1";
inline constexpr auto childLinkCapability = "wikidict.inline-box-child-link/1";
inline constexpr auto percentDottedCapability = "wikidict.inline-box-percent-dotted/1";
inline bool childLink(const QJsonObject &span) {
    const auto children = span.value("inline_box_group").toObject().value("spans").toArray();
    return span.value("kind") == "text" && children.size() == 1
        && children.first().toObject().value("kind") == "link";
}
inline void require(bool yes) {
    if (!yes) throw std::runtime_error("unsupported or stale compiled inline-box geometry");
}
inline void requireCapability(QTextDocument *document) {
    require(document && !document->isLayoutEnabled()
        && document->documentLayout()->property("_wikidictInlineBoxCapability").toString()
            == QString::fromLatin1(QCompiledInlineBox::Capability));
}
inline void requireExtendedCapability(QTextDocument *document, const QJsonObject &span) {
    requireCapability(document);
    const auto group = CompiledContent::inlineBoxGroup(span);
    if (CompiledContent::hasNestedPitchChildren(span))
        require(document->documentLayout()->property("_wikidictInlineBoxNestedPitchCapability").toString()
            == QString::fromLatin1(QCompiledInlineBox::NestedPitchCapability));
    if (childLink(span)) require(document->documentLayout()->property("_wikidictInlineBoxChildLinkCapability").toString()
        == QString::fromLatin1(childLinkCapability));
    if (CompiledContent::inlineBoxUsesBorderSource(span))
        require(document->documentLayout()->property("_wikidictInlineBoxOverlayCapability").toString()
            == QString::fromLatin1(overlayCapability));
    const auto children = group.value("spans").toArray();
    if (group.value("radius").toObject().value("unit") == QStringLiteral("percent")
        || group.value("border").toObject().value("top").toObject().contains("dotted")
        || CompiledContent::present(span.value("inline_style"))
        || std::any_of(children.cbegin(), children.cend(),
            [](const QJsonValue &child) { return CompiledContent::present(child.toObject().value("inline_style")); }))
        require(document->documentLayout()->property("_wikidictInlineBoxPercentDottedCapability").toString()
            == QString::fromLatin1(percentDottedCapability));
    if (span.value("kind") == QStringLiteral("link") || CompiledContent::present(group.value("radius")))
        require(document->documentLayout()->property("_wikidictInlineBoxRoundedLinkCapability").toString()
            == QString::fromLatin1(roundedCapability));
}
inline QVariant actionIdentity(const QTextCharFormat &format) {
    const auto raw = format.property(QCompiledInlineBox::Property);
    QCompiledInlineBox::Box box;
    if (!QCompiledInlineBox::parse(raw, &box) || !QCompiledInlineBox::hasAction(box)) return {};
    return raw;
}
inline QString marker(const QJsonObject &span, const QString &childrenHtml,
                      const QString &ownerHtml, qreal basePoints, int sourceRun) {
    CompiledContent::inlineBoxGroup(span);
    const QJsonObject data{{"span", span}, {"html", childrenHtml}, {"owner_html", ownerHtml}, {"base_points", basePoints}};
    const auto bytes = QJsonDocument(data).toJson(QJsonDocument::Compact);
    require(bytes.size() <= 16 * 1024 * 1024 && basePoints > 0 && std::isfinite(basePoints));
    QString html = QStringLiteral("<img src=\"%1%2\" />")
        .arg(QString::fromLatin1(scheme), QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)));
    if (sourceRun >= 0) html = QStringLiteral("<span data-wikidict-source-run=\"%1\">%2</span>").arg(sourceRun).arg(html);
    return html;
}
struct Owner {
    QTextCursor first, last;
    QFont font;
    QColor background;
    QString source;
    QVariantList padding, widths, colors;
    QVariant radius;
    bool percentRadius = false, dottedBorder = false;
    QVariantMap action, childAction;
    QByteArray borderSource;
    QVariantList currentColors, overlays;
    QList<QPair<int, QJsonObject>> nested;
};
struct Expansion {
    QPointer<QTextDocument> document;
    QPointer<QAbstractTextDocumentLayout> layout;
    QList<Owner> owners;
};
inline QColor borderColor(const QJsonValue &value, const QJsonObject &owner, const QTextCharFormat &declaring, bool sourceBound = false) {
    const auto color = CompiledContent::object(value); require(color.size() == 1);
    if (color.contains("rgb")) return SemanticHtml::styleColor(color.value("rgb"));
    const QString tag = color.keys().first();
    require((tag == "transparent" || tag == "current_color") && color.value(tag).isObject()
        && color.value(tag).toObject().isEmpty());
    if (tag == "transparent" || sourceBound) return QColor(Qt::transparent);
    // A fixed explicit declaring color has no palette or action-state dependency.
    // Source-bound currentColor was retained above for native draw-time resolution.
    const QColor explicitInk = SemanticHtml::styleColor(owner.value("foreground"));
    require(declaring.foreground().style() == Qt::SolidPattern && declaring.foreground().color() == explicitInk);
    return explicitInk;
}
inline Expansion expand(QTextDocument *document) {
    Expansion result; result.document = document;
    require(document && !document->isLayoutEnabled());
    result.layout = document->documentLayout();
    const auto current = [&] {
        require(result.document && result.layout && result.document->documentLayout() == result.layout
            && !result.document->isLayoutEnabled());
    };
    struct Marker { QTextCursor range; QTextCharFormat provenance; QJsonObject data; };
    QList<Marker> markers;
    for (auto block = document->begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (!fragment.isValid() || !fragment.charFormat().isImageFormat()) continue;
            const auto name = fragment.charFormat().toImageFormat().name();
            if (!name.startsWith(QString::fromLatin1(scheme))) continue;
            requireCapability(document);
            const auto encoded = name.mid(qstrlen(scheme)).toLatin1();
            require(encoded.size() <= 24 * 1024 * 1024);
            QJsonParseError error;
            const auto parsed = QJsonDocument::fromJson(QByteArray::fromBase64(encoded, QByteArray::Base64UrlEncoding), &error);
            require(error.error == QJsonParseError::NoError && parsed.isObject());
            const auto data = CompiledContent::containerObject(parsed.object(),
                {"span", "html", "owner_html", "base_points"}, {"span", "html", "owner_html", "base_points"});
            for (int i = 0; i < fragment.length(); ++i) {
                require(fragment.text().at(i) == QChar::ObjectReplacementCharacter && markers.size() < (1 << 20));
                QTextCursor range(document); range.setPosition(fragment.position() + i);
                range.setPosition(fragment.position() + i + 1, QTextCursor::KeepAnchor);
                markers.append({range, fragment.charFormat(), data});
            }
        }
    }
    qsizetype total = 0;
    for (auto &item : markers) {
        current();
        const auto span = item.data.value("span").toObject();
        const auto group = CompiledContent::inlineBoxGroup(span);
        requireExtendedCapability(document, span);
        const bool wholeLink = span.value("kind") == QStringLiteral("link");
        const bool sourceBound = CompiledContent::inlineBoxUsesBorderSource(span);
        QJsonArray leaves = group.value("spans").toArray();
        QList<QPair<int, QJsonObject>> nested;
        if (CompiledContent::hasNestedPitchChildren(span))
            require(CompiledContent::nestedPitchSource(span, &leaves, &nested));
        QString source;
        for (const auto &raw : leaves)
            source += raw.toObject().value("text").toString() + raw.toObject().value("trail").toString();
        require(source.size() <= (1 << 20) - total); total += source.size();
        const qreal points = item.data.value("base_points").toDouble();
        require(item.data.value("base_points").isDouble() && std::isfinite(points) && points > 0
            && item.data.value("html").isString() && item.data.value("owner_html").isString());
        // The marker inherits the enclosing body/Flow font, independently of
        // the declaring owner. Preserve that context in both temporary imports.
        QFont base = item.provenance.font().resolve(document->defaultFont());
        base.setPointSizeF(points);
        QTextDocument ownerContext;
        ownerContext.setDefaultFont(base);
        ownerContext.setDefaultStyleSheet(document->defaultStyleSheet());
        ownerContext.setDefaultTextOption(document->defaultTextOption());
        ownerContext.documentLayout()->setPaintDevice(result.layout->paintDevice());
        QTextCharFormat declaring;
        if (wholeLink) {
            SemanticHtml::inlineFontSnapshot(CompiledRuby::spanFont(span));
            SemanticHtml::setHtml(&ownerContext, item.data.value("owner_html").toString());
            current();
            require(ownerContext.blockCount() == 1 && ownerContext.toPlainText() == QStringLiteral("X"));
            declaring = ownerContext.find(QStringLiteral("X")).charFormat();
            declaring.setFont(declaring.font().resolve(base));
            const QString href = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(span.value("target").toString()));
            require(declaring.isAnchor() && declaring.anchorHref() == href && declaring.anchorNames().isEmpty());
        } else declaring = SemanticHtml::inlineSnapshotFormat(&ownerContext, CompiledRuby::spanFont(span),
            item.data.value("owner_html").toString(), points);
        current();
        require(declaring.verticalAlignment() == QTextCharFormat::AlignNormal
            && (!declaring.hasProperty(QCompiledInline::Property)
                || QCompiledInlineBox::helpOnly(declaring.property(QCompiledInline::Property))));
        QTextDocument child;
        child.setDefaultFont(base); child.setDefaultStyleSheet(document->defaultStyleSheet());
        child.setDefaultTextOption(document->defaultTextOption());
        child.documentLayout()->setPaintDevice(result.layout->paintDevice());
        SemanticHtml::setHtml(&child, item.data.value("html").toString());
        current();
        require(child.blockCount() == 1 && child.rootFrame()->childFrames().isEmpty() && child.toPlainText() == source);
        const QFont font = declaring.font().resolve(base);
        require(font.pointSizeF() > 0);
        // Normalize only inherited font resolution and original provenance. The
        // renderer's child colors, anchor URLs and decorations remain intact.
        struct Run { int first, length; QTextCharFormat format; };
        QList<Run> runs;
        for (auto it = child.begin().begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment(); if (!fragment.isValid()) continue;
            auto format = fragment.charFormat(); format.setFont(format.font().resolve(base));
            // Fragment insertion copies the temporary formats without merging
            // destination ink. Explicit child and link colors still win.
            if (!format.hasProperty(QTextFormat::ForegroundBrush)
                && item.provenance.hasProperty(QTextFormat::ForegroundBrush))
                format.setForeground(item.provenance.foreground());
            require(format.objectType() == QTextFormat::NoObject
                && format.verticalAlignment() == QTextCharFormat::AlignNormal
                && (!format.hasProperty(QCompiledInline::Property)
                    || QCompiledInlineBox::helpOnly(format.property(QCompiledInline::Property)))
                && QCompiledInlineBox::sameMetricFont(format.font(), font));
            // Keep the ordinary link renderer's resolved ink/decoration/focus
            // authority. The child contributes its unchanged original characters.
            if (wholeLink) format = declaring;
            if (sourceBound && CompiledContent::present(span.value("foreground")))
                format.setForeground(declaring.foreground());
            if (sourceBound) require(QCompiledInlineBox::borderFormat(span, format));
            if (item.provenance.hasProperty(SemanticHtml::sourceRunProperty))
                format.setProperty(SemanticHtml::sourceRunProperty, item.provenance.property(SemanticHtml::sourceRunProperty));
            if (format.hasProperty(QTextFormat::BackgroundBrush)) {
                require(CompiledContent::present(span.value("background"))
                    && format.background().style() == Qt::SolidPattern
                    && format.background().color() == SemanticHtml::styleColor(span.value("background")));
                // The exact duplicate effective paint belongs to the full box,
                // not a second glyph-run rectangle over its sliced border.
                format.clearProperty(QTextFormat::BackgroundBrush);
            }
            if (!format.hasProperty(QCompiledInline::Property) && declaring.hasProperty(QCompiledInline::Property))
                format.setProperty(QCompiledInline::Property, declaring.property(QCompiledInline::Property));
            if (!format.hasProperty(QTextFormat::TextToolTip)
                && declaring.hasProperty(QTextFormat::TextToolTip))
                format.setToolTip(declaring.toolTip());
            runs.append({fragment.position(), fragment.length(), format});
        }
        for (const auto &run : runs) {
            QTextCursor cursor(&child); cursor.setPosition(run.first);
            cursor.setPosition(run.first + run.length, QTextCursor::KeepAnchor); cursor.setCharFormat(run.format);
        }
        if (!item.provenance.anchorNames().isEmpty()) {
            QTextCursor first(&child); first.setPosition(0); first.setPosition(1, QTextCursor::KeepAnchor);
            auto format = first.charFormat(); auto names = format.anchorNames();
            for (const auto &name : item.provenance.anchorNames()) if (!names.contains(name)) names.append(name);
            format.setAnchor(true); format.setAnchorNames(names); first.setCharFormat(format);
        }
        Owner owner; owner.font = font; owner.source = source; owner.nested = nested;
        if (childLink(span)) {
            const auto original = group.value("spans").toArray().first().toObject();
            const QString href = QStringLiteral("dict:") + QString::fromLatin1(QUrl::toPercentEncoding(original.value("target").toString()));
            for (const auto &run : runs) require(run.format.isAnchor() && run.format.anchorHref() == href);
            owner.childAction = QVariantMap{{"source", QJsonDocument(span).toJson(QJsonDocument::Compact)}, {"href", href}};
        }
        if (sourceBound) owner.borderSource = QJsonDocument(span).toJson(QJsonDocument::Compact);
        if (wholeLink) owner.action = QVariantMap{{"source", QJsonDocument(span).toJson(QJsonDocument::Compact)},
            {"href", declaring.anchorHref()}};
        if (CompiledContent::present(group.value("radius"))) {
            const auto radius = group.value("radius").toObject();
            owner.radius = radius.value("value").toDouble();
            owner.percentRadius = radius.value("unit") == QStringLiteral("percent");
            owner.dottedBorder = group.value("border").toObject().value("top").toObject().contains("dotted");
        }
        if (CompiledContent::present(span.value("background"))) {
            owner.background = SemanticHtml::styleColor(span.value("background"));
            require(declaring.background().style() == Qt::SolidPattern
                && declaring.background().color() == owner.background);
        }
        const auto padding = group.value("padding").toObject(), border = group.value("border").toObject();
        for (const auto key : {"top", "right", "bottom", "left"}) {
            const qreal p = SemanticHtml::styleLengthUnits(padding.value(key), document, font.pointSizeF());
            const auto edge = border.value(key).toObject(); const auto mode = edge.keys().first();
            qreal width = 0; QColor color(Qt::transparent);
            if (mode == "solid" || mode == "dotted") {
                width = SemanticHtml::styleLengthUnits(edge.value(mode).toObject().value("width"), document, font.pointSizeF());
                color = borderColor(edge.value(mode).toObject().value("color"), span, declaring, sourceBound);
            }
            require(QCompiledInlineBox::finite(p) && QCompiledInlineBox::finite(width)
                && QCompiledInlineBox::finite(p + width));
            owner.padding.append(double(p)); owner.widths.append(double(width)); owner.colors.append(color);
            if (sourceBound) owner.currentColors.append(mode == "solid"
                && edge.value(mode).toObject().value("color").toObject().contains("current_color"));
        }
        if (sourceBound) for (const auto &raw : group.value("overlays").toArray()) {
            const auto overlay = raw.toObject();
            QVariantList insets, widths, colors, currentColors;
            for (const auto key : {"top", "right", "bottom", "left"}) {
                const auto inset = overlay.value("insets").toObject().value(key);
                if (inset.isNull()) insets.append(QVariant{});
                else insets.append(QVariantMap{{"unit", inset.toObject().value("unit").toString()},
                    {"value", inset.toObject().value("value").toDouble()}});
                const auto edge = overlay.value("border").toObject().value(key).toObject();
                const auto solid = edge.value("solid").toObject();
                const qreal width = edge.contains("solid")
                    ? SemanticHtml::styleLengthUnits(solid.value("width"), document, font.pointSizeF()) : 0;
                require(QCompiledInlineBox::finite(width));
                widths.append(double(width));
                colors.append(edge.contains("solid") ? borderColor(solid.value("color"), span, declaring, true) : QColor(Qt::transparent));
                currentColors.append(edge.contains("solid") && solid.value("color").toObject().contains("current_color"));
            }
            owner.overlays.append(QVariantMap{{"insets", insets}, {"widths", widths}, {"colors", colors}, {"currentColors", currentColors}});
        }
        current();
        require(item.range.selectedText() == QString(QChar::ObjectReplacementCharacter));
        item.range.removeSelectedText(); current();
        owner.first = item.range; owner.first.setKeepPositionOnInsert(true);
        item.range.insertFragment(QTextDocumentFragment(&child)); current();
        owner.last = item.range; owner.last.setKeepPositionOnInsert(true);
        owner.first.clearSelection(); owner.last.clearSelection();
        require(owner.last.position() - owner.first.position() == source.size());
        result.owners.append(owner);
    }
    return result;
}
inline void finalize(const Expansion &result) {
    if (result.owners.isEmpty()) return;
    auto current = [&] {
        require(result.document && result.layout && result.document->documentLayout() == result.layout
            && !result.document->isLayoutEnabled());
    };
    current(); requireCapability(result.document);
    for (const auto &owner : result.owners) {
        current();
        QTextCursor range(result.document); range.setPosition(owner.first.position());
        range.setPosition(owner.last.position(), QTextCursor::KeepAnchor);
        require(range.selectedText() == owner.source && range.block() == owner.first.block());
        if (range.currentFrame() != result.document->rootFrame()) {
            // Bind the actual final table/cell, after all imports and Flow moves.
            // No root-coordinate waiver or arbitrary nested frame is admitted.
            auto *table = qobject_cast<QTextTable *>(range.currentFrame());
            // Paint ownership and table placement are independent. Fixed-color
            // circles do not acquire currentColor/source metadata to enter a cell.
            const bool fixedCircle = owner.percentRadius && owner.dottedBorder
                && owner.radius == QVariant(50.0) && !owner.background.isValid()
                && owner.action.isEmpty() && owner.childAction.isEmpty() && owner.nested.isEmpty();
            require((!owner.borderSource.isEmpty() || fixedCircle) && table
                && table->parentFrame() == result.document->rootFrame()
                && table->frameFormat().position() == QTextFrameFormat::InFlow
                && !QTextLogicalFlowProjection::inlineTable(table)
                && !table->format().hasProperty(SemanticHtml::tableViewportProperty)
                && !table->format().hasProperty(SemanticHtml::tableViewportGridProperty)
                && !table->format().hasProperty(SemanticHtml::tableFloatViewportProperty));
            const auto first = table->cellAt(owner.first.position()), last = table->cellAt(owner.last.position() - 1);
            require(first.isValid() && last.isValid() && first == last
                && owner.first.position() >= first.firstPosition() && owner.last.position() <= first.lastPosition());
        }
        QVariantMap metadata{{"capability", QString::fromLatin1(QCompiledInlineBox::Capability)},
            {"document", QVariant::fromValue(static_cast<QObject *>(result.document.data()))},
            {"first", owner.first.position()}, {"last", owner.last.position()}, {"source", owner.source},
            {"font", owner.font}, {"padding", owner.padding}, {"widths", owner.widths}, {"colors", owner.colors}};
        if (owner.background.isValid()) metadata.insert("background", owner.background);
        if (owner.radius.isValid()) metadata.insert("radius", owner.radius);
        if (owner.percentRadius) metadata.insert("radiusUnit", QStringLiteral("percent"));
        if (owner.dottedBorder) metadata.insert("borderStyle", QStringLiteral("dotted"));
        if (!owner.action.isEmpty()) metadata.insert("action", owner.action);
        if (!owner.childAction.isEmpty()) metadata.insert("childAction", owner.childAction);
        if (!owner.borderSource.isEmpty()) {
            metadata.insert("borderSource", owner.borderSource);
            metadata.insert("currentColors", owner.currentColors);
            metadata.insert("overlays", owner.overlays);
        }
        if (!owner.nested.isEmpty()) {
            QVariantList children;
            for (const auto &nested : owner.nested) {
                const int first = owner.first.position() + nested.first;
                const QString text = nested.second.value("inline_box_group").toObject().value("spans").toArray().first().toObject().value("text").toString();
                children.append(QVariantMap{{"capability", QString::fromLatin1(QCompiledInlineBox::Capability)},
                    {"document", QVariant::fromValue(static_cast<QObject *>(result.document.data()))},
                    {"first", first}, {"last", first + 1}, {"source", text}, {"font", owner.font},
                    {"padding", QVariantList{0.0,0.0,0.0,0.0}}, {"widths", QVariantList{1.0,1.0,1.0,1.0}},
                    {"colors", QVariantList{QColor("#808080"),QColor("#808080"),QColor("#808080"),QColor("#808080")}},
                    {"radius", 50.0}, {"radiusUnit", QStringLiteral("percent")}, {"borderStyle", QStringLiteral("dotted")}});
            }
            metadata.insert("nestedChildren", children);
        }
        require(QCompiledInlineBox::parse(metadata, nullptr));
        QTextCharFormat property; property.setProperty(QCompiledInlineBox::Property, metadata);
        range.mergeCharFormat(property); current();
    }
}
}
