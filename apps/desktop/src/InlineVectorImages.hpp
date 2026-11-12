#pragma once

#include "SemanticHtml.hpp"
#include "SemanticFigure.hpp"
#include "MediaPanel.hpp"

#include <QAbstractTextDocumentLayout>
#include <QHash>
#include <QColorSpace>
#include <QPaintEngine>
#include <QPainter>
#include <QPointer>
#include <QSvgRenderer>
#include <QRegularExpression>
#include <QTextDocument>
#include <QTextImageFormat>
#include <QtMath>
#include <memory>

// Keep content sizing, accessibility and raster painting in Qt. Authored borders
// extend the object outside its content; shared vectors paint at device resolution.
class InlineVectorImages final : public QObject, public QTextObjectInterface {
    Q_OBJECT
    Q_INTERFACES(QTextObjectInterface)
public:
    explicit InlineVectorImages(QAbstractTextDocumentLayout *layout)
        : QObject(layout), fallback_(layout->handlerForObject(QTextFormat::ImageObject)) {
        for (QObject *child : layout->children())
            if (qobject_cast<QTextObjectInterface *>(child) == fallback_) fallbackOwner_ = child;
        Q_ASSERT(fallback_ && fallbackOwner_);
        layout->registerHandler(QTextFormat::ImageObject, this);
        connect(layout, &QAbstractTextDocumentLayout::update, this, [this] { ++paintEpoch_; painted_.clear(); });
        connect(layout, &QAbstractTextDocumentLayout::documentSizeChanged, this, [this] { ++paintEpoch_; painted_.clear(); });
        connect(layout->document(), &QTextDocument::contentsChange, this, [this] { ++paintEpoch_; painted_.clear(); });
    }

    void setVector(const QUrl &url, const std::shared_ptr<QSvgRenderer> &vector) {
        vectors_.removeIf([](const auto &entry) { return entry.value().expired(); });
        if (vector) vectors_.insert(url.toString(), vector);
        else vectors_.remove(url.toString());
    }

    struct MapHit { bool mapped = false; int position = -1; CompiledImageMap::Hit hit; QUrl source; };
    static QJsonObject compiledImage(const QTextFormat &format) {
        if (format.hasProperty(SemanticHtml::imageCompiledDataProperty))
            return format.property(SemanticHtml::imageCompiledDataProperty).value<QJsonObject>();
        return SemanticHtml::inlineImageData(QUrl(format.toImageFormat().name()));
    }
    static QRectF descriptionRect(const QRectF &content, const QString &placement) {
        if (placement == QStringLiteral("none") || content.width() <= 0 || content.height() <= 0) return {};
        const qreal size = qMin(qreal(18), qMin(content.width(), content.height()));
        return QRectF(placement.endsWith(QStringLiteral("right")) ? content.right() - size : content.left(),
            placement.startsWith(QStringLiteral("bottom")) ? content.bottom() - size : content.top(), size, size);
    }
    MapHit mapAt(QTextDocument *document, QPointF point, bool spatial = true) const {
        const QPointer<const InlineVectorImages> self(this);
        const QPointer<QTextDocument> guard(document);
        const int position = document->documentLayout()->hitTest(point, Qt::ExactHit);
        if (!self || !guard || position < 0) return {};
        const QTextBlock block = document->findBlock(position);
        QTextFragment fragment;
        for (auto it = block.begin(); !it.atEnd(); ++it)
            if (it.fragment().isValid() && it.fragment().contains(position)) { fragment = it.fragment(); break; }
        if (!fragment.isValid() || !fragment.charFormat().isImageFormat()
            || document->characterAt(position) != QChar::ObjectReplacementCharacter) return {};
        const QTextImageFormat format = fragment.charFormat().toImageFormat();
        const QUrl url(format.name()); if (url.scheme() != SemanticHtml::inlineImageScheme) return {};
        const QJsonObject image = compiledImage(format);
        if (!SemanticHtml::present(image.value(QStringLiteral("map")))) return {};
        MapHit result; result.mapped = true; result.position = position; result.hit.kind = CompiledImageMap::Hit::Unavailable;
        if (!spatial || (format.hasProperty(SemanticHtml::figureImageProperty)
            && !format.boolProperty(SemanticFigure::sizingReadyProperty))) return result;
        const auto record = painted_.constFind(position);
        if (record == painted_.cend() || record->document != guard || record->revision != document->revision()
            || record->epoch != paintEpoch_ || record->format != fragment.charFormat()) return result;
        const QRectF content = record->content;
        if (!std::isfinite(content.x()) || !std::isfinite(content.y()) || !std::isfinite(point.x()) || !std::isfinite(point.y())
            || !CompiledImageMap::positive(content.width()) || !CompiledImageMap::positive(content.height())) return result;
        const double dx = point.x() - content.x(), dy = point.y() - content.y();
        if (!std::isfinite(dx) || !std::isfinite(dy)) return result;
        if (dx < 0 || dy < 0 || dx >= content.width() || dy >= content.height()) {
            result.hit.kind = CompiledImageMap::Hit::Outside; return result;
        }
        const QJsonObject map = image.value(QStringLiteral("map")).toObject();
        if (descriptionRect(record->content, map.value(QStringLiteral("description")).toString()).contains(point)) {
            result.source = QUrl(QStringLiteral("media-source:") + QString::fromLatin1(QUrl::toPercentEncoding(
                QStringLiteral("File:") + image.value(QStringLiteral("file")).toString())) + QLatin1Char('#'));
            return result;
        }
        if (document->property("wikidict.figure.geometryError").isValid()) return result;
        try {
            if (!record->preparedAttempted) {
                record->preparedAttempted = true;
                record->prepared = std::make_shared<CompiledImageMap::Prepared>(CompiledImageMap::prepare(image.value(QStringLiteral("map")).toObject(),
                    format.property(SemanticHtml::imageOriginalSizeProperty).toSizeF(),
                    format.property(SemanticHtml::imageLayoutSizeProperty).toSizeF()));
            }
            if (record->prepared) result.hit = record->prepared->hit(record->content, point);
        } catch (const CompiledImageMap::GeometryUnavailable &) {}
        return result;
    }

    static QVariantMap figureMediaPolicy(QTextDocument *document, int position) {
        auto *frame = document->frameAt(position);
        if (!frame || frame->frameFormat().stringProperty(SemanticFigure::roleProperty) != QStringLiteral("image")) return {};
        const auto policy = frame->frameFormat().property(SemanticFigure::tableCaptionProperty).toMap();
        return policy.value(QStringLiteral("capability")).toString() == SemanticFigure::tableCaptionCapability ? policy : QVariantMap();
    }
    static QSizeF figureStatusText(QTextDocument *document, const QTextFormat &format, const QVariantMap &policy,
                                  qreal width, QPainter *painter = nullptr, QPointF origin = {}) {
        const auto image = compiledImage(format);
        const auto altValue = image.value(QStringLiteral("alt"));
        const QString alt = altValue.toString();
        if (alt.isEmpty()) {
            if (altValue.isString()) return QSizeF(qMax(qreal(0), width), 0);
            const qreal side = qMin(qreal(18), qMax(qreal(0), width));
            if (painter && side > 0) {
                painter->save(); painter->setPen(format.toCharFormat().foreground().style() == Qt::NoBrush
                    ? QPen(painter->pen().color()) : QPen(format.toCharFormat().foreground(), 1));
                const QRectF marker(origin + QPointF(.5, .5), QSizeF(qMax(qreal(0), side - 1), qMax(qreal(0), side - 1)));
                painter->drawRect(marker); painter->drawLine(marker.topLeft(), marker.bottomRight()); painter->drawLine(marker.topRight(), marker.bottomLeft());
                painter->restore();
            }
            return QSizeF(side, side);
        }
        QFont font = format.toCharFormat().font().resolve(document->defaultFont());
        QTextLayout text(alt, font, document->documentLayout()->paintDevice());
        QTextOption option; option.setWrapMode(QTextOption::WrapAtWordBoundaryOrAnywhere);
        option.setTextDirection(Qt::LayoutDirection(policy.value(QStringLiteral("direction")).toInt()));
        text.setTextOption(option); text.beginLayout();
        qreal y = 0, widest = 0;
        while (true) {
            auto line = text.createLine(); if (!line.isValid()) break;
            line.setLineWidth(qMax(qreal(0), width)); line.setPosition(QPointF(0, y));
            y += line.height(); widest = qMax(widest, line.naturalTextWidth());
        }
        text.endLayout();
        if (painter) {
            painter->save();
            if (format.toCharFormat().foreground().style() != Qt::NoBrush) painter->setPen(QPen(format.toCharFormat().foreground(), 1));
            text.draw(painter, origin); painter->restore();
        }
        return QSizeF(qMin(qMax(qreal(0), width), widest), y);
    }
    static void paintFigureImageBox(QPainter *painter, const QRectF &object, const QVariantMap &policy,
                                    QTextDocument *document) {
        const QFontMetricsF metrics(document->defaultFont(), document->documentLayout()->paintDevice());
        const qreal scale = metrics.fontDpi() / QFontMetricsF(QFont()).fontDpi();
        const auto box = policy.value(QStringLiteral("box")).toList();
        const auto paint = policy.value(QStringLiteral("image_paint")).toMap();
        const qreal border = paint.value(QStringLiteral("border_width")).toDouble() * scale;
        const QRectF outer = object.adjusted(box[3].toDouble() * scale - border, box[0].toDouble() * scale - border,
            -box[1].toDouble() * scale + border, -box[2].toDouble() * scale + border);
        painter->save();
        const QColor background = paint.value(QStringLiteral("background")).value<QColor>();
        if (background.isValid()) painter->fillRect(outer, background);
        if (border > 0) {
            const QColor ink = paint.value(QStringLiteral("border_color")).value<QColor>();
            painter->setPen(QPen(ink, border)); painter->setBrush(Qt::NoBrush);
            painter->drawRect(outer.adjusted(border / 2, border / 2, -border / 2, -border / 2));
        }
        painter->restore();
    }
    static std::shared_ptr<QSvgRenderer> figureGraphic(const QString &name) {
        // These source bytes are the two authenticated Commons skin assets.
        // Use SVG's meet transform and clip the viewport at the call site.
        static const auto ltr = [] {
            auto result = std::make_shared<QSvgRenderer>(QByteArrayLiteral(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"15\" height=\"11\" viewBox=\"0 0 11 15\">\n"
                "\t<g id=\"magnify-clip\" fill=\"#fff\" stroke=\"#000\">\n"
                "\t\t<path id=\"bigbox\" d=\"M1.509 1.865h10.99v7.919H1.509z\"/>\n"
                "\t\t<path id=\"smallbox\" d=\"M-1.499 6.868h5.943v4.904h-5.943z\"/>\n"
                "\t</g>\n"
                "</svg>\n"));
            result->setAspectRatioMode(Qt::KeepAspectRatio); return result;
        }();
        static const auto rtl = [] {
            auto result = std::make_shared<QSvgRenderer>(QByteArrayLiteral(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"15\" height=\"11\" viewBox=\"0 0 11 15\">\n"
                "\t<g id=\"magnify-clip\" fill=\"#fff\" stroke=\"#000\">\n"
                "\t\t<path id=\"bigbox\" d=\"M9.491 1.865h-10.99v7.919h10.99z\"/>\n"
                "\t\t<path id=\"smallbox\" d=\"M12.499 6.868H6.556v4.904h5.943z\"/>\n"
                "\t</g>\n"
                "</svg>\n"));
            result->setAspectRatioMode(Qt::KeepAspectRatio); return result;
        }();
        return name == QStringLiteral("magnify_clip_ltr_v1") ? ltr
            : name == QStringLiteral("magnify_clip_rtl_v1") ? rtl : std::shared_ptr<QSvgRenderer>();
    }
    bool paintFigureDecoration(QPainter *painter, QTextDocument *document, int position, const QTextFormat &format) {
        constexpr int decorationProperty = QTextFormat::UserProperty + 0x57af;
        if (!format.hasProperty(decorationProperty)) return false;
        const auto decoration = format.property(decorationProperty).toMap();
        const auto policy = figureMediaPolicy(document, position);
        auto *frame = document->frameAt(position);
        if (policy.isEmpty() || decoration.value(QStringLiteral("policy")).toMap() != policy
            || !decoration.value(QStringLiteral("handled")).toBool()
            || decoration.value(QStringLiteral("revision")).toInt() != document->revision()
            || decoration.value(QStringLiteral("position")).toInt() != position
            || decoration.value(QStringLiteral("owner")).toInt() != frame->objectIndex()) return true;
        // Native paint supplies the stored image format, including its importer
        // object identity. QTextCursor::charFormat intentionally removes that identity.
        QTextFragment original;
        const auto block = document->findBlock(position);
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const auto fragment = it.fragment();
            if (fragment.isValid() && fragment.position() == position) { original = fragment; break; }
        }
        auto sourceFormat = format.toCharFormat(); sourceFormat.clearProperty(decorationProperty);
        if (!original.isValid() || original.length() != 1 || !original.charFormat().isImageFormat()
            || original.charFormat() != sourceFormat
            || document->characterAt(position) != QChar::ObjectReplacementCharacter) return true;
        const QPointer<InlineVectorImages> self(this);
        const QPointer<QTextDocument> guard(document);
        const qreal scale = decoration.value(QStringLiteral("scale")).toDouble();
        const auto after = policy.value(QStringLiteral("after")).toMap();
        const QRectF rectangle = decoration.value(QStringLiteral("after")).toRectF();
        if (!after.isEmpty() && !rectangle.isEmpty()) {
            const auto vector = figureGraphic(after.value(QStringLiteral("graphic")).toString());
            if (vector) {
                painter->save(); painter->setClipRect(rectangle, Qt::IntersectClip);
                painter->setRenderHint(QPainter::Antialiasing);
                if (after.value(QStringLiteral("invert")).toBool()) paintFiltered(painter, rectangle, document, sourceFormat, vector, true);
                else vector->render(painter, rectangle);
                painter->restore();
                if (!self || !guard) return true;
            }
        }
        const auto focus = policy.value(QStringLiteral("focus")).toMap();
        if (decoration.value(QStringLiteral("focus_visible")).toBool() && !focus.isEmpty()) {
            const qreal width = focus.value(QStringLiteral("width")).toDouble() * scale;
            if (width > 0) {
                const qreal radius = qMax(qreal(0), (focus.value(QStringLiteral("radius")).toDouble()
                    + focus.value(QStringLiteral("offset")).toDouble()) * scale + width / 2);
                const QRectF outline = decoration.value(QStringLiteral("focus")).toRectF().adjusted(width / 2, width / 2, -width / 2, -width / 2);
                painter->save(); painter->setRenderHint(QPainter::Antialiasing);
                painter->setPen(QPen(focus.value(QStringLiteral("color")).value<QColor>(), width)); painter->setBrush(Qt::NoBrush);
                painter->drawRoundedRect(outline, radius, radius);
                painter->restore();
            }
        }
        // Decoration never enters painted_: the original source image owns that cache.
        return true;
    }
    QSizeF intrinsicSize(QTextDocument *document, int position, const QTextFormat &format) override {
        if (!fallbackOwner_) return {};
        const QPointer<InlineVectorImages> self(this);
        const QPointer<QTextDocument> guard(document);
        const auto media = figureMediaPolicy(document, position);
        if (!media.isEmpty()) {
            double width = -1;
            const bool queried = QMetaObject::invokeMethod(document->documentLayout(), "wikidictFigureContentWidth", Qt::DirectConnection,
                Q_RETURN_ARG(double, width), Q_ARG(int, position));
            if (!self || !guard || !queried || !std::isfinite(width) || width < 0) return {};
            const qreal scale = QFontMetricsF(document->defaultFont(), document->documentLayout()->paintDevice()).fontDpi() / QFontMetricsF(QFont()).fontDpi();
            const bool ready = format.boolProperty(SemanticFigure::sizingReadyProperty)
                && format.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Ready);
            QSizeF content;
            if (ready) {
                content = QSizeF(format.toImageFormat().width(), format.toImageFormat().height()) * scale;
                if (!std::isfinite(content.width()) || content.width() <= 0 || !std::isfinite(content.height()) || content.height() < 0) return {};
                if (content.width() > width) content *= width / content.width();
            } else content = figureStatusText(document, format, media, width);
            const auto box = media.value(QStringLiteral("box")).toList();
            return content + QSizeF(box[1].toDouble() + box[3].toDouble(), box[0].toDouble() + box[2].toDouble()) * scale;
        }
        // Qt's stock image fallback treats zero dimensions as unspecified. A
        // source-resolved figure height of zero is instead exact logical data.
        const bool figure = format.hasProperty(SemanticHtml::figureImageProperty);
        QSizeF content = figure ? QSizeF(format.toImageFormat().width(), format.toImageFormat().height())
                                : fallback_->intrinsicSize(document, position, format);
        if (!self || !guard) return {};
        if (figure) {
            if (!std::isfinite(content.width()) || content.width() <= 0
                || !std::isfinite(content.height()) || content.height() < 0) return {};
            double width = -1;
            const bool queried = QMetaObject::invokeMethod(document->documentLayout(), "wikidictFigureContentWidth", Qt::DirectConnection,
                Q_RETURN_ARG(double, width), Q_ARG(int, position));
            if (!self || !guard) return {};
            const auto sourceFigure = QJsonDocument::fromJson(
                format.property(SemanticHtml::figureImageProperty).toByteArray()).object();
            const bool tableCaption = sourceFigure.value(QStringLiteral("table_caption_layout")).isObject();
            if (queried && (CompiledImageMap::positive(width)
                || (tableCaption && std::isfinite(width) && width == 0)) && content.width() > width)
                content *= width / content.width();
        }
        return content.isValid() && !figure && format.boolProperty(SemanticHtml::inlineImageBorderProperty)
            ? content + QSizeF(2, 2) : content;
    }

    static QRectF posterWrapper(const QRectF &content, const QTextFormat &format, QTextDocument *document) {
        if (!format.hasProperty(SemanticHtml::figureImageProperty))
            return format.boolProperty(SemanticHtml::inlineImageBorderProperty) ? content.adjusted(-1, -1, 1, 1) : content;
        const auto figure = QJsonDocument::fromJson(format.property(SemanticHtml::figureImageProperty).toByteArray()).object();
        const QFont font = document->defaultFont();
        const QFontMetricsF metrics(font, document->documentLayout()->paintDevice());
        const qreal em = font.pixelSize() > 0 ? font.pixelSize() : font.pointSizeF() * metrics.fontDpi() / 72;
        const auto inset = SemanticFigure::edges(figure.value("image_insets"), em);
        const qreal border = SemanticFigure::borderWidth(figure.value("image_border"), em);
        // The wrapper contains image margins and border. The separate Figure
        // frame border is outside this box and cannot shift the badge origin.
        return content.adjusted(-inset.left - border, -inset.top - border,
            inset.right + border, inset.bottom + border);
    }
    static QRectF paintStaticPoster(QPainter *painter, const QRectF &content, QTextDocument *document,
                                   const QTextFormat &format) {
        if (QUrl(format.toImageFormat().name()).scheme() != SemanticHtml::inlineImageScheme) return {};
        const auto poster = SemanticHtml::checkedStaticPoster(compiledImage(format));
        if (poster.isEmpty()) return {};
        const QRectF wrapper = posterWrapper(content, format, document);
        if (!wrapper.isValid()) return {};
        QFont font(QStringLiteral("sans-serif"));
        font.setStyleHint(QFont::SansSerif);
        const QFontMetricsF deviceMetrics(font, document->documentLayout()->paintDevice());
        font.setPointSizeF(14 * 72 / deviceMetrics.fontDpi()); font.setWeight(QFont::Bold);
        // Source white-space is normal. Collapse CSS ASCII whitespace, without
        // treating nonbreaking spaces or the compiled Unicode label as markup.
        QString text = poster.value("label").toString();
        text.replace(QRegularExpression(QStringLiteral("[ \\t\\r\\n\\f]+")), QStringLiteral(" "));
        if (text.startsWith(QChar(' '))) text.remove(0, 1);
        if (text.endsWith(QChar(' '))) text.chop(1);
        QTextLayout layout(text, font, document->documentLayout()->paintDevice());
        QTextOption option = document->defaultTextOption();
        option.setTextDirection(Qt::LeftToRight);
        option.setWrapMode(QTextOption::WordWrap); layout.setTextOption(option);
        const qreal available = qMax(qreal(0), wrapper.width() - 11 - 10);
        qreal width = 0, height = 0;
        layout.beginLayout();
        while (!text.isEmpty()) {
            auto line = layout.createLine(); if (!line.isValid()) break;
            line.setLineWidth(available);
            line.setPosition(QPointF(0, height + (19 - line.height()) / 2));
            width = qMax(width, line.naturalTextWidth()); height += 19;
        }
        layout.endLayout();
        const QRectF badge(wrapper.topLeft() + QPointF(11, 11), QSizeF(width + 10, height + 4));
        // CSS opacity belongs to the completed badge, not independently to its
        // overlapping background and text. Bounded device tiles avoid a label-
        // sized allocation while retaining the painter transform and DPR once.
        const auto transform = painter->deviceTransform();
        if (!transform.isInvertible()) return {};
        // The source clips only at its wrapper. Native glyph bearings and
        // combining-mark ink may extend beyond the badge advance/background box.
        QRect bounds = transform.mapRect(wrapper).toAlignedRect();
        if (painter->hasClipping()) bounds &= transform.mapRect(painter->clipBoundingRect()).toAlignedRect();
        const auto systemClip = painter->paintEngine()->systemClip();
        if (!systemClip.isEmpty()) bounds &= systemClip.boundingRect();
        const auto *target = painter->paintEngine()->paintDevice();
        if (!target) target = painter->device();
        const qreal dpr = target->devType() == QInternal::Widget ? qMax(qreal(1), target->devicePixelRatioF()) : 1;
        bounds &= QRect(0, 0, qCeil(target->width() * dpr), qCeil(target->height() * dpr));
        for (int y = bounds.top(); y <= bounds.bottom(); y += 256)
            for (int x = bounds.left(); x <= bounds.right(); x += 256) {
                const QRect tileRect(x, y, qMin(256, bounds.right() - x + 1), qMin(256, bounds.bottom() - y + 1));
                QImage tile(tileRect.size(), QImage::Format_ARGB32_Premultiplied); tile.fill(Qt::transparent);
                {
                    QPainter scratch(&tile); scratch.setRenderHint(QPainter::Antialiasing);
                    scratch.setWorldTransform(transform * QTransform::fromTranslate(-x, -y));
                    scratch.setClipRect(wrapper); scratch.setPen(Qt::NoPen);
                    scratch.setBrush(QColor(QStringLiteral("#f8f9fa"))); scratch.drawRoundedRect(badge, 2, 2);
                    scratch.setPen(QColor(QStringLiteral("#1e1f21")));
                    layout.draw(&scratch, badge.topLeft() + QPointF(5, 2));
                }
                painter->save(); painter->setOpacity(painter->opacity() * .8);
                painter->setWorldTransform(QTransform());
                painter->setWorldTransform(painter->deviceTransform().inverted());
                painter->drawImage(tileRect.topLeft(), tile); painter->restore();
            }
        return badge.intersected(wrapper);
    }

    void drawObject(QPainter *painter, const QRectF &rect, QTextDocument *document,
                    int position, const QTextFormat &format) override {
        if (paintFigureDecoration(painter, document, position, format)) return;
        const bool figure = format.hasProperty(SemanticHtml::figureImageProperty);
        const auto media = figure ? figureMediaPolicy(document, position) : QVariantMap();
        const bool resolvedFigure = figure && format.boolProperty(SemanticFigure::sizingReadyProperty)
            && (media.isEmpty() || format.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Ready));
        if (media.isEmpty() && resolvedFigure && format.toImageFormat().height() == 0) return;
        const bool border = !figure && format.boolProperty(SemanticHtml::inlineImageBorderProperty);
        QRectF content = border ? rect.adjusted(1, 1, -1, -1) : rect;
        if (!media.isEmpty()) {
            const qreal scale = QFontMetricsF(document->defaultFont(), document->documentLayout()->paintDevice()).fontDpi() / QFontMetricsF(QFont()).fontDpi();
            const auto box = media.value(QStringLiteral("box")).toList();
            content = rect.adjusted(box[3].toDouble() * scale, box[0].toDouble() * scale, -box[1].toDouble() * scale, -box[2].toDouble() * scale);
            paintFigureImageBox(painter, rect, media, document);
            if (!resolvedFigure) {
                figureStatusText(document, format, media, content.width(), painter, content.topLeft());
                return;
            }
            if (content.isEmpty()) return;
        }
        const QPointer<InlineVectorImages> self(this);
        const QPointer<QTextDocument> guard(document);
        const quint64 epoch = paintEpoch_;
        const auto retainPaint = [self, guard, epoch, content, position, format, figure, resolvedFigure] {
            if (!self || !guard || self->paintEpoch_ != epoch || (figure && !resolvedFigure)) return;
            auto previous = self->painted_.find(position);
            if (previous != self->painted_.end() && previous->document == guard && previous->revision == guard->revision()
                && previous->epoch == epoch && previous->format == format.toCharFormat()) {
                previous->content = content;
                return;
            }
            self->painted_.insert(position, {guard, guard->revision(), epoch, content, format.toCharFormat()});
        };
        const auto paintDescription = [&] {
            if (figure && !resolvedFigure) return;
            const QUrl url(format.toImageFormat().name());
            if (url.scheme() != SemanticHtml::inlineImageScheme) return;
            const QJsonObject image = compiledImage(format);
            if (!image.value(QStringLiteral("map")).isObject()) return;
            const QRectF icon = descriptionRect(content, image.value(QStringLiteral("map")).toObject().value(QStringLiteral("description")).toString());
            if (icon.isEmpty()) return;
            painter->save();
            painter->setClipRect(content, Qt::IntersectClip);
            painter->setPen(Qt::black); painter->setBrush(QColor(255, 255, 255, 230));
            painter->drawEllipse(icon.adjusted(1, 1, -1, -1));
            QFont font = painter->font(); font.setPixelSize(qMax(1, int(icon.height() * .7))); font.setBold(true); painter->setFont(font);
            painter->drawText(icon, Qt::AlignCenter, QStringLiteral("i"));
            painter->restore();
        };
        // One resource URL can be shared by ordinary images and figures with
        // different sizing policies. An unsupported occurrence must retain its
        // own normal placeholder, even if that URL already holds Ready pixels.
        if (figure && !resolvedFigure) {
            const QImage placeholder = format.property(SemanticFigure::placeholderPixelsProperty).value<QImage>();
            if (!placeholder.isNull()) {
                painter->save();
                painter->setClipRect(content, Qt::IntersectClip);
                painter->drawImage(content, placeholder);
                painter->restore();
            }
            paintStaticPoster(painter, content, document, format);
            return;
        }
        const auto vector = vectors_.value(format.toImageFormat().name()).lock();
        const bool filtered = document->property(SemanticHtml::imageDarkThemeProperty).toBool()
            && format.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Ready)
            && compiledImage(format).value(QStringLiteral("dark_mode_filter")).toString() == QStringLiteral("invert_hue_rotate_180");
        if (!border && !vector && !filtered) {
            if (fallbackOwner_) fallback_->drawObject(painter, content, document, position, format);
            if (!self || !guard) return;
            paintDescription();
            paintStaticPoster(painter, content, document, format);
            retainPaint();
            return;
        }
        // No disk/network access, parse or occurrence-sized intermediate bitmap.
        // Logical-pixel bands follow the same painter transform/DPR as content.
        painter->save();
        painter->setClipRect(rect, Qt::IntersectClip);
        if (border) {
            const QColor color(0xea, 0xec, 0xf0);
            painter->fillRect(QRectF(rect.left(), rect.top(), rect.width(), 1), color);
            painter->fillRect(QRectF(rect.left(), rect.bottom() - 1, rect.width(), 1), color);
            painter->fillRect(QRectF(rect.left(), rect.top() + 1, 1, rect.height() - 2), color);
            painter->fillRect(QRectF(rect.right() - 1, rect.top() + 1, 1, rect.height() - 2), color);
        }
        painter->setClipRect(content, Qt::IntersectClip);
        if (filtered) {
            paintFiltered(painter, content, document, format, vector);
        } else if (vector) {
            painter->setRenderHint(QPainter::Antialiasing);
            if (vector->animated()) vector->setCurrentFrame(0);
            vector->render(painter, content);
        } else if (fallbackOwner_) {
            fallback_->drawObject(painter, content, document, position, format);
        }
        painter->restore();
        if (!self || !guard) return;
        paintDescription();
        paintStaticPoster(painter, content, document, format);
        retainPaint();
    }

private:
    // CSS filter functions use unpremultiplied sRGB, in declaration order.
    // invert(1) followed by hue-rotate(180deg); alpha is an identity channel.
    static void filterPixels(QImage &image) {
        image = image.convertToFormat(QImage::Format_ARGB32);
        for (int y = 0; y < image.height(); ++y) {
            auto *row = reinterpret_cast<QRgb *>(image.scanLine(y));
            for (int x = 0; x < image.width(); ++x) {
                const QRgb p = row[x];
                const double r = 255 - qRed(p), g = 255 - qGreen(p), b = 255 - qBlue(p);
                const auto channel = [](double n) { return qBound(0, qRound(n), 255); };
                row[x] = qRgba(channel(-.574*r + 1.430*g + .144*b),
                    channel(.426*r + .430*g + .144*b), channel(.426*r + 1.430*g - .856*b), qAlpha(p));
            }
        }
    }
    void paintFiltered(QPainter *painter, const QRectF &content, QTextDocument *document,
                       const QTextFormat &format, const std::shared_ptr<QSvgRenderer> &vector, bool invertOnly = false) {
        const QPointer<InlineVectorImages> self(this);
        const QPointer<QTextDocument> guard(document);
        QImage raster;
        if (!vector) {
            raster = document->resource(QTextDocument::ImageResource, QUrl(format.toImageFormat().name())).value<QImage>();
            if (!self || !guard || raster.isNull()) return;
            if (raster.colorSpace().isValid()) raster.convertToColorSpace(QColorSpace::SRgb);
        }
        const QTransform transform = painter->deviceTransform();
        if (!transform.isInvertible()) return;
        QRect bounds = transform.mapRect(content).toAlignedRect();
        if (painter->hasClipping()) bounds &= transform.mapRect(painter->clipBoundingRect()).toAlignedRect();
        const QRegion systemClip = painter->paintEngine()->systemClip();
        if (!systemClip.isEmpty()) bounds &= systemClip.boundingRect();
        // deviceTransform includes QWidget backing-store redirection. Bound
        // its target, not the child widget's local dimensions. Image/pixmap
        // metrics already count physical pixels; widget metrics are logical.
        const QPaintDevice *target = painter->paintEngine()->paintDevice();
        if (!target) target = painter->device();
        const qreal dpr = target->devType() == QInternal::Widget
            ? qMax(qreal(1), target->devicePixelRatioF()) : qreal(1);
        bounds &= QRect(0, 0, qCeil(target->width() * dpr), qCeil(target->height() * dpr));
        // Device-space tiles preserve vector detail, transforms and clipping
        // without allocating a bitmap the size of a tall authored occurrence.
        for (int y = bounds.top(); y <= bounds.bottom(); y += 256)
            for (int x = bounds.left(); x <= bounds.right(); x += 256) {
                const QRect tileRect(x, y, qMin(256, bounds.right() - x + 1), qMin(256, bounds.bottom() - y + 1));
                QImage tile(tileRect.size(), QImage::Format_ARGB32_Premultiplied);
                tile.setColorSpace(QColorSpace::SRgb); tile.fill(Qt::transparent);
                {
                    QPainter scratch(&tile);
                    scratch.setRenderHints(painter->renderHints());
                    scratch.setWorldTransform(transform * QTransform::fromTranslate(-x, -y));
                    scratch.setClipRect(content);
                    if (vector) {
                        scratch.setRenderHint(QPainter::Antialiasing);
                        if (vector->animated()) vector->setCurrentFrame(0);
                        vector->render(&scratch, content);
                    } else scratch.drawImage(content, raster);
                }
                if (!self || !guard) return;
                if (invertOnly) tile.invertPixels(QImage::InvertRgb);
                else filterPixels(tile);
                painter->save();
                painter->setWorldTransform(QTransform());
                painter->setWorldTransform(painter->deviceTransform().inverted());
                painter->drawImage(tileRect.topLeft(), tile);
                painter->restore();
            }
    }
    struct Painted {
        QPointer<QTextDocument> document; int revision; quint64 epoch; QRectF content; QTextCharFormat format;
        mutable bool preparedAttempted = false;
        mutable std::shared_ptr<CompiledImageMap::Prepared> prepared;
    };
    quint64 paintEpoch_ = 0;
    QHash<int, Painted> painted_;
    QTextObjectInterface *fallback_;
    QPointer<QObject> fallbackOwner_;
    QHash<QString, std::weak_ptr<QSvgRenderer>> vectors_;
};
