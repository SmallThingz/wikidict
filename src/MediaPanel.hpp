#pragma once

#include <QJsonObject>
#include <QWidget>
#include <memory>

class QNetworkAccessManager;

// Native controls for the media references already present in a compiled entry.
class MediaPanel final : public QWidget {
public:
    explicit MediaPanel(QWidget *parent = nullptr, QNetworkAccessManager *network = nullptr);
    ~MediaPanel() override;

    void setEntry(const QJsonObject &entry);
    void sayWord(const QString &title, const QString &languageCode);
    void stopPlayback();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
