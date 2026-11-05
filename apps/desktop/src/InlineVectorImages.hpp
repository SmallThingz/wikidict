#pragma once

#include <QAbstractTextDocumentLayout>
#include <QHash>
#include <QPainter>
#include <QPointer>
#include <QSvgRenderer>
#include <QTextDocument>
#include <QTextImageFormat>
#include <memory>

// Keep ordinary image layout, accessibility and raster painting in Qt. Only a
// validated shared vector paints directly into the current device/transform.
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
    }

    void setVector(const QUrl &url, const std::shared_ptr<QSvgRenderer> &vector) {
        vectors_.removeIf([](const auto &entry) { return entry.value().expired(); });
        if (vector) vectors_.insert(url.toString(), vector);
        else vectors_.remove(url.toString());
    }

    QSizeF intrinsicSize(QTextDocument *document, int position, const QTextFormat &format) override {
        return fallbackOwner_ ? fallback_->intrinsicSize(document, position, format) : QSizeF();
    }

    void drawObject(QPainter *painter, const QRectF &rect, QTextDocument *document,
                    int position, const QTextFormat &format) override {
        const auto vector = vectors_.value(format.toImageFormat().name()).lock();
        if (!vector) {
            if (fallbackOwner_) fallback_->drawObject(painter, rect, document, position, format);
            return;
        }
        // No disk/network access, parse or occurrence-sized intermediate bitmap.
        // QPainter already carries the device pixel ratio and viewport transform.
        painter->save();
        painter->setClipRect(rect, Qt::IntersectClip);
        painter->setRenderHint(QPainter::Antialiasing);
        if (vector->animated()) vector->setCurrentFrame(0);
        vector->render(painter, rect);
        painter->restore();
    }

private:
    QTextObjectInterface *fallback_;
    QPointer<QObject> fallbackOwner_;
    QHash<QString, std::weak_ptr<QSvgRenderer>> vectors_;
};
