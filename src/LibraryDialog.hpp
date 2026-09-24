#pragma once

#include "LibraryStore.hpp"
#include <QDialog>
#include <QPointer>
#include <atomic>
#include <functional>
#include <memory>

class QComboBox;
class QLabel;
class QLineEdit;
class QNetworkAccessManager;
class QNetworkReply;
class QProgressBar;
class QPushButton;
class QTemporaryFile;
class QThread;
class QTreeWidget;

class LibraryDialog final : public QDialog {
public:
    LibraryDialog(QWidget *parent, const QString &root);
    ~LibraryDialog() override;
    QString selectedRoot() const { return root_; }
    bool libraryChanged() const { return changed_; }
protected:
    void reject() override;
private:
    void refreshInstalled();
    void refreshCatalogView();
    void chooseRoot();
    void importFile();
    void removeSelected();
    void refreshCatalogs();
    void fetchNextCatalog();
    void downloadSelected();
    void addSource();
    void removeSource();
    void startImport(const QString &file, const QByteArray &hash = {}, qint64 bytes = -1);
    void finishOperation(const QString &message, bool error = false);
    void setBusy(bool busy, const QString &label = {});
    void runWorker(std::function<void()> task, std::function<void(const QString &)> finished);
    LibraryStorage::Progress progressCallback();
    QNetworkReply *get(const QUrl &url);
    void cancelOperation();
    void saveSources();
    QString root_;
    bool changed_ = false;
    bool busy_ = false;
    bool closeWhenDone_ = false;
    std::atomic_bool cancelled_ = false;
    QThread *worker_ = nullptr;
    QNetworkAccessManager *network_ = nullptr;
    QPointer<QNetworkReply> reply_;
    std::unique_ptr<QTemporaryFile> download_;
    QList<LibraryStorage::Dictionary> dictionaries_;
    QList<LibraryStorage::CatalogItem> catalog_;
    QStringList pendingSources_;
    QStringList catalogErrors_;
    QLabel *rootLabel_ = nullptr;
    QLabel *installedSummary_ = nullptr;
    QLabel *availableSummary_ = nullptr;
    QLabel *status_ = nullptr;
    QTreeWidget *installed_ = nullptr;
    QTreeWidget *available_ = nullptr;
    QLineEdit *filter_ = nullptr;
    QComboBox *sources_ = nullptr;
    QProgressBar *progress_ = nullptr;
    QPushButton *chooseButton_ = nullptr;
    QPushButton *importButton_ = nullptr;
    QPushButton *removeButton_ = nullptr;
    QPushButton *downloadButton_ = nullptr;
    QPushButton *refreshButton_ = nullptr;
    QPushButton *addSourceButton_ = nullptr;
    QPushButton *removeSourceButton_ = nullptr;
    QPushButton *cancelButton_ = nullptr;
};
