#pragma once

#include "SemanticHtml.hpp"

#include <QAbstractTextDocumentLayout>
#include <QHash>
#include <QPainter>
#include <QPointer>
#include <QSvgRenderer>
#include <QTextDocument>
#include <QTextImageFormat>
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
    }

    void setVector(const QUrl &url, const std::shared_ptr<QSvgRenderer> &vector) {
        vectors_.removeIf([](const auto &entry) { return entry.value().expired(); });
        if (vector) vectors_.insert(url.toString(), vector);
        else vectors_.remove(url.toString());
    }

    QSizeF intrinsicSize(QTextDocument *document, int position, const QTextFormat &format) override {
        if (!fallbackOwner_) return {};
        const QSizeF content = fallback_->intrinsicSize(document, position, format);
        return content.isValid() && format.boolProperty(SemanticHtml::inlineImageBorderProperty)
            ? content + QSizeF(2, 2) : content;
    }

    void drawObject(QPainter *painter, const QRectF &rect, QTextDocument *document,
                    int position, const QTextFormat &format) override {
        const bool border = format.boolProperty(SemanticHtml::inlineImageBorderProperty);
        const auto vector = vectors_.value(format.toImageFormat().name()).lock();
        if (!border && !vector) {
            if (fallbackOwner_) fallback_->drawObject(painter, rect, document, position, format);
            return;
        }
        const QRectF content = border ? rect.adjusted(1, 1, -1, -1) : rect;
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
        if (vector) {
            painter->setRenderHint(QPainter::Antialiasing);
            if (vector->animated()) vector->setCurrentFrame(0);
            vector->render(painter, content);
        } else if (fallbackOwner_) {
            fallback_->drawObject(painter, content, document, position, format);
        }
        painter->restore();
    }

private:
    QTextObjectInterface *fallback_;
    QPointer<QObject> fallbackOwner_;
    QHash<QString, std::weak_ptr<QSvgRenderer>> vectors_;
};
