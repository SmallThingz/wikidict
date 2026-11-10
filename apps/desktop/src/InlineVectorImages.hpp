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

    QSizeF intrinsicSize(QTextDocument *document, int position, const QTextFormat &format) override {
        if (!fallbackOwner_) return {};
        const QPointer<InlineVectorImages> self(this);
        const QPointer<QTextDocument> guard(document);
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
            if (queried && CompiledImageMap::positive(width) && content.width() > width)
                content *= width / content.width();
        }
        return content.isValid() && !figure && format.boolProperty(SemanticHtml::inlineImageBorderProperty)
            ? content + QSizeF(2, 2) : content;
    }

    void drawObject(QPainter *painter, const QRectF &rect, QTextDocument *document,
                    int position, const QTextFormat &format) override {
        const bool figure = format.hasProperty(SemanticHtml::figureImageProperty);
        const bool resolvedFigure = figure && format.boolProperty(SemanticFigure::sizingReadyProperty);
        if (resolvedFigure && format.toImageFormat().height() == 0) return;
        const bool border = !figure && format.boolProperty(SemanticHtml::inlineImageBorderProperty);
        const QRectF content = border ? rect.adjusted(1, 1, -1, -1) : rect;
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
            return;
        }
        const auto vector = vectors_.value(format.toImageFormat().name()).lock();
        const bool filtered = document->property(SemanticHtml::imageDarkThemeProperty).toBool()
            && format.intProperty(SemanticHtml::inlineImageStateProperty) == int(MediaPanel::InlineImageState::Ready)
            && compiledImage(format).value(QStringLiteral("dark_mode_filter")).toString() == QStringLiteral("invert_hue_rotate_180");
        if (!border && !vector && !filtered) {
            if (fallbackOwner_) fallback_->drawObject(painter, rect, document, position, format);
            if (!self || !guard) return;
            paintDescription();
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
                       const QTextFormat &format, const std::shared_ptr<QSvgRenderer> &vector) {
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
                filterPixels(tile);
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
