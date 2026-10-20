#pragma once

#include "LibraryStore.hpp"
#include <QDialog>
#include <QNetworkAccessManager>
#include <QPointer>
#include <atomic>
#include <functional>
#include <memory>

class QComboBox;
class QLabel;
class QLineEdit;
class QNetworkReply;
class QProgressBar;
class QPushButton;
class QTemporaryFile;
class QThread;
class QTreeWidget;

class LibraryDialog final : public QDialog {
public:
    // Consumes an unparented manager on the dialog thread; QObject owns it after adoption.
    LibraryDialog(QWidget *parent, const QString &root,
                  std::unique_ptr<QNetworkAccessManager> network = {});
    ~LibraryDialog() override;
    QString selectedRoot() const { return root_; }
    bool libraryChanged() const { return changed_; }
    bool originalRootChanged() const { return originalRootChanged_; }
protected:
    void reject() override;
private:
    friend class MainWindowTest;
    void refreshInstalled(std::function<void(const QString &)> finished = {});
    void refreshCatalogView();
    void chooseRoot();
    void noteRootChange(const QString &root);
    void importFile();
    void removeSelected();
    void refreshCatalogs();
    void fetchNextCatalog();
    void downloadSelected();
    void addSource();
    void removeSource();
    void startImport(const QString &file, const QByteArray &hash = {}, qint64 bytes = -1, const QString &sourceName = {});
    void finishOperation(const QString &message, bool error = false);
    void setBusy(bool busy, const QString &label = {});
    void runWorker(std::function<void()> task, std::function<void(const QString &)> finished, bool reconcileInstalled = true);
    LibraryStorage::Progress progressCallback();
    QNetworkReply *get(const QUrl &url);
    void cancelOperation();
    void saveSources();
    QString root_;
    QString originalRoot_;
    bool originalRootChanged_ = false;
    bool changed_ = false;
    bool busy_ = false;
    bool nativeValidationFailure_ = false;
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
