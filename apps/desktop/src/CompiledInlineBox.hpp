#pragma once
#include "CompiledContent.hpp"
#include "CompiledRubyFont.hpp"
#include "SemanticHtml.hpp"
#include <QtGui/private/qtextinlinebox_p.h>
#include <QJsonDocument>
#include <QPointer>
#include <QTextDocumentFragment>
#include <QTextImageFormat>

// The marker exists only inside the owned disabled import transaction. The
// installed document contains the original ordinary child characters and links.
namespace CompiledInlineBox {
inline constexpr auto scheme = "wikidict-inline-box:";
inline void require(bool yes) {
    if (!yes) throw std::runtime_error("unsupported or stale compiled inline-box geometry");
}
inline void requireCapability(QTextDocument *document) {
    require(document && !document->isLayoutEnabled()
        && document->documentLayout()->property("_wikidictInlineBoxCapability").toString()
            == QString::fromLatin1(QCompiledInlineBox::Capability));
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
    QString source;
    QVariantList padding, widths, colors;
};
struct Expansion {
    QPointer<QTextDocument> document;
    QPointer<QAbstractTextDocumentLayout> layout;
    QList<Owner> owners;
};
inline QColor borderColor(const QJsonValue &value, const QJsonObject &owner, const QTextCharFormat &declaring) {
    const auto color = CompiledContent::object(value); require(color.size() == 1);
    if (color.contains("rgb")) return SemanticHtml::styleColor(color.value("rgb"));
    const QString tag = color.keys().first();
    require((tag == "transparent" || tag == "current_color") && color.value(tag).isObject()
        && color.value(tag).toObject().isEmpty());
    if (tag == "transparent") return QColor(Qt::transparent);
    // A fixed explicit declaring color has no palette or action-state dependency.
    // Inherited/theme/state-dependent currentColor remains an explicit refusal.
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
        QString source;
        for (const auto &raw : group.value("spans").toArray())
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
        const auto declaring = SemanticHtml::inlineSnapshotFormat(&ownerContext, CompiledRuby::spanFont(span),
            item.data.value("owner_html").toString(), points);
        current();
        require(declaring.verticalAlignment() == QTextCharFormat::AlignNormal
            && !declaring.hasProperty(QCompiledInline::Property));
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
                && !format.hasProperty(QCompiledInline::Property)
                && QCompiledInlineBox::sameMetricFont(format.font(), font));
            if (item.provenance.hasProperty(SemanticHtml::sourceRunProperty))
                format.setProperty(SemanticHtml::sourceRunProperty, item.provenance.property(SemanticHtml::sourceRunProperty));
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
        Owner owner; owner.font = font; owner.source = source;
        const auto padding = group.value("padding").toObject(), border = group.value("border").toObject();
        for (const auto key : {"top", "right", "bottom", "left"}) {
            const qreal p = SemanticHtml::styleLengthUnits(padding.value(key), document, font.pointSizeF());
            const auto edge = border.value(key).toObject(); const auto mode = edge.keys().first();
            qreal width = 0; QColor color(Qt::transparent);
            if (mode == "solid") {
                width = SemanticHtml::styleLengthUnits(edge.value(mode).toObject().value("width"), document, font.pointSizeF());
                color = borderColor(edge.value(mode).toObject().value("color"), span, declaring);
            }
            require(QCompiledInlineBox::finite(p) && QCompiledInlineBox::finite(width)
                && QCompiledInlineBox::finite(p + width));
            owner.padding.append(double(p)); owner.widths.append(double(width)); owner.colors.append(color);
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
        require(range.selectedText() == owner.source && range.block() == owner.first.block()
            && range.currentFrame() == result.document->rootFrame());
        QVariantMap metadata{{"capability", QString::fromLatin1(QCompiledInlineBox::Capability)},
            {"document", QVariant::fromValue(static_cast<QObject *>(result.document.data()))},
            {"first", owner.first.position()}, {"last", owner.last.position()}, {"source", owner.source},
            {"font", owner.font}, {"padding", owner.padding}, {"widths", owner.widths}, {"colors", owner.colors}};
        require(QCompiledInlineBox::parse(metadata, nullptr));
        QTextCharFormat property; property.setProperty(QCompiledInlineBox::Property, metadata);
        range.mergeCharFormat(property); current();
    }
}
}
