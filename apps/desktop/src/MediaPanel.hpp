#pragma once

#include <QJsonObject>
#include <QImage>
#include <QUrl>
#include <functional>
#include <QWidget>
#include <memory>

class QNetworkAccessManager;
class QSvgRenderer;

// Native controls for the media references already present in a compiled entry.
class MediaPanel final : public QWidget {
public:
    explicit MediaPanel(QWidget *parent = nullptr, QNetworkAccessManager *network = nullptr);
    ~MediaPanel() override;

    void setEntry(const QJsonObject &entry, const QString &sourceHost = {});
    void sayWord(const QString &title, const QString &languageCode);
    void stopPlayback();

    enum class InlineImageState { Disabled, Loading, Ready, Error };
    struct InlineImageAsset { InlineImageState state; QImage image; QString message; QSizeF intrinsic; QString originalMime; std::shared_ptr<QSvgRenderer> vector; };
    InlineImageAsset requestInlineImage(const QString &file, QObject *owner, const QString &key,
        std::function<void(const InlineImageAsset &)> changed);
    QUrl inlineImageSource(const QString &compiledTarget) const;
    bool openInlineImageSource(const QString &compiledTarget);


private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
