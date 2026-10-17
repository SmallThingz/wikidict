#include "LibraryDialog.hpp"

#include <QComboBox>
#include <QDialogButtonBox>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFileDialog>
#include <QFileInfo>
#include <QHeaderView>
#include <QInputDialog>
#include <QLabel>
#include <QLineEdit>
#include <QLocale>
#include <QMessageBox>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProgressBar>
#include <QPushButton>
#include <QSettings>
#include <QSet>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QTemporaryFile>
#include <QThread>
#include <QTimer>
#include <QTreeWidget>
#include <QVBoxLayout>
#include <algorithm>
#include <stdexcept>

namespace {
const QTreeWidgetItem *selectedDictionary(const QTreeWidget *tree) {
    const auto selected = tree->selectedItems();
    return selected.size() == 1 ? selected.first() : nullptr;
}
QString exceptionText(const std::exception &error) { return QString::fromUtf8(error.what()); }
QTreeWidget *dictionaryList(QWidget *parent, const QStringList &columns) {
    auto *tree = new QTreeWidget(parent);
    tree->setHeaderLabels(columns);
    tree->setRootIsDecorated(false);
    tree->setAlternatingRowColors(true);
    tree->setSelectionMode(QAbstractItemView::SingleSelection);
    tree->setUniformRowHeights(true);
    tree->header()->setSectionResizeMode(0, QHeaderView::Stretch);
    for (int i = 1; i < columns.size(); ++i) tree->header()->setSectionResizeMode(i, QHeaderView::ResizeToContents);
    return tree;
}
}

LibraryDialog::LibraryDialog(QWidget *parent, const QString &root,
                             std::unique_ptr<QNetworkAccessManager> network)
    : QDialog(parent), root_(root.isEmpty()
          ? QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)).filePath(QStringLiteral("dictionaries"))
          : QDir(root).absolutePath()) {
    setWindowTitle(QStringLiteral("Dictionary library"));
    setObjectName(QStringLiteral("libraryDialog"));
    resize(780, 680);
    setMinimumSize(580, 480);
    if (network && (network->parent() || network->thread() != thread()))
        throw std::invalid_argument("Injected network manager must be unparented and on the dialog thread");
    if (network) {
        network->setParent(this);
        network_ = network.release();
    } else {
        network_ = new QNetworkAccessManager(this);
    }
    auto *layout = new QVBoxLayout(this);
    layout->setSpacing(10);
    auto *heading = new QLabel(QStringLiteral("Dictionary library"), this);
    QFont headingFont = heading->font();
    headingFont.setPointSize(headingFont.pointSize() + 6);
    headingFont.setBold(true);
    heading->setFont(headingFont);
    layout->addWidget(heading);
    auto *folderRow = new QHBoxLayout;
    rootLabel_ = new QLabel(root_, this);
    rootLabel_->setWordWrap(true);
    rootLabel_->setTextFormat(Qt::PlainText);
    rootLabel_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    rootLabel_->setAccessibleName(QStringLiteral("Dictionary folder"));
    chooseButton_ = new QPushButton(QStringLiteral("Choose folder..."), this);
    chooseButton_->setObjectName(QStringLiteral("chooseDictionaryFolder"));
    folderRow->addWidget(rootLabel_, 1);
    folderRow->addWidget(chooseButton_);
    layout->addLayout(folderRow);

    auto *installedActions = new QHBoxLayout;
    installedSummary_ = new QLabel(this);
    installedSummary_->setWordWrap(true);
    importButton_ = new QPushButton(QStringLiteral("Import file..."), this);
    importButton_->setObjectName(QStringLiteral("importDictionary"));
    removeButton_ = new QPushButton(QStringLiteral("Remove"), this);
    removeButton_->setObjectName(QStringLiteral("removeDictionary"));
    installedActions->addWidget(installedSummary_, 1);
    installedActions->addWidget(importButton_);
    installedActions->addWidget(removeButton_);
    layout->addLayout(installedActions);
    installed_ = dictionaryList(this, {QStringLiteral("On this device"), QStringLiteral("Words"), QStringLiteral("Size")});
    installed_->setObjectName(QStringLiteral("installedDictionaries"));
    installed_->setAccessibleName(QStringLiteral("Installed dictionaries"));
    layout->addWidget(installed_, 1);

    auto *availableActions = new QHBoxLayout;
    filter_ = new QLineEdit(this);
    filter_->setPlaceholderText(QStringLiteral("Filter available dictionaries"));
    filter_->setClearButtonEnabled(true);
    filter_->setAccessibleName(QStringLiteral("Filter available dictionaries"));
    downloadButton_ = new QPushButton(QStringLiteral("Download"), this);
    downloadButton_->setObjectName(QStringLiteral("downloadDictionary"));
    availableActions->addWidget(filter_, 1);
    availableActions->addWidget(downloadButton_);
    layout->addLayout(availableActions);
    available_ = dictionaryList(this, {QStringLiteral("Available to download"), QStringLiteral("Size"), QStringLiteral("Status")});
    available_->setObjectName(QStringLiteral("availableDictionaries"));
    available_->setAccessibleName(QStringLiteral("Available dictionaries"));
    layout->addWidget(available_, 1);
    availableSummary_ = new QLabel(QStringLiteral("Refresh the catalogue to browse available dictionaries."), this);
    availableSummary_->setWordWrap(true);
    layout->addWidget(availableSummary_);

    auto *sourcesRow = new QHBoxLayout;
    sources_ = new QComboBox(this);
    sources_->setAccessibleName(QStringLiteral("Catalogue sources"));
    sources_->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
    sources_->setMinimumContentsLength(18);
    sources_->setToolTip(QStringLiteral("HTTPS catalogues provide downloadable dictionaries."));
    QSettings settings;
    const QStringList saved = settings.value(QStringLiteral("library/catalogSources"),
        QStringList{LibraryStorage::defaultSource()}).toStringList();
    for (const auto &source : saved) if (LibraryStorage::isHttpsUrl(QUrl(source))) sources_->addItem(source);
    addSourceButton_ = new QPushButton(QStringLiteral("Add source..."), this);
    removeSourceButton_ = new QPushButton(QStringLiteral("Remove source"), this);
    refreshButton_ = new QPushButton(QStringLiteral("Refresh"), this);
    sourcesRow->addWidget(sources_, 1);
    sourcesRow->addWidget(addSourceButton_);
    sourcesRow->addWidget(removeSourceButton_);
    sourcesRow->addWidget(refreshButton_);
    layout->addLayout(sourcesRow);

    status_ = new QLabel(this);
    status_->setObjectName(QStringLiteral("libraryStatus"));
    status_->setTextFormat(Qt::PlainText);
    status_->setWordWrap(true);
    status_->setTextInteractionFlags(Qt::TextSelectableByMouse);
    layout->addWidget(status_);
    auto *progressRow = new QHBoxLayout;
    progress_ = new QProgressBar(this);
    progress_->setObjectName(QStringLiteral("libraryProgress"));
    progress_->setTextVisible(true);
    cancelButton_ = new QPushButton(QStringLiteral("Cancel"), this);
    cancelButton_->setObjectName(QStringLiteral("cancelLibraryOperation"));
    progressRow->addWidget(progress_, 1);
    progressRow->addWidget(cancelButton_);
    layout->addLayout(progressRow);
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, this);
    layout->addWidget(buttons);
    connect(buttons, &QDialogButtonBox::rejected, this, &LibraryDialog::reject);
    connect(chooseButton_, &QPushButton::clicked, this, &LibraryDialog::chooseRoot);
    connect(importButton_, &QPushButton::clicked, this, &LibraryDialog::importFile);
    connect(removeButton_, &QPushButton::clicked, this, &LibraryDialog::removeSelected);
    connect(downloadButton_, &QPushButton::clicked, this, &LibraryDialog::downloadSelected);
    connect(refreshButton_, &QPushButton::clicked, this, &LibraryDialog::refreshCatalogs);
    connect(addSourceButton_, &QPushButton::clicked, this, &LibraryDialog::addSource);
    connect(removeSourceButton_, &QPushButton::clicked, this, &LibraryDialog::removeSource);
    connect(cancelButton_, &QPushButton::clicked, this, &LibraryDialog::cancelOperation);
    connect(filter_, &QLineEdit::textChanged, this, &LibraryDialog::refreshCatalogView);
    connect(installed_, &QTreeWidget::itemSelectionChanged, this, [this] {
        removeButton_->setEnabled(!busy_ && selectedDictionary(installed_));
    });
    connect(available_, &QTreeWidget::itemSelectionChanged, this, [this] {
        const auto *item = selectedDictionary(available_);
        downloadButton_->setEnabled(!busy_ && item && !item->data(0, Qt::UserRole + 1).toBool());
    });
    setBusy(false);
    refreshInstalled();
    QTimer::singleShot(0, this, &LibraryDialog::refreshCatalogs);
}
LibraryDialog::~LibraryDialog() {
    cancelled_.store(true);
    if (reply_) { reply_->disconnect(this); reply_->abort(); }
    if (worker_) { worker_->disconnect(this); worker_->wait(); delete worker_; }
}
void LibraryDialog::reject() {
    if (busy_) {
        if (QMessageBox::question(this, QStringLiteral("Cancel operation?"),
                QStringLiteral("Cancel the current dictionary operation and close the library?"),
                QMessageBox::Yes | QMessageBox::No, QMessageBox::No) != QMessageBox::Yes) return;
        closeWhenDone_ = true;
        cancelOperation();
        return;
    }
    QDialog::reject();
}
void LibraryDialog::setBusy(bool busy, const QString &label) {
    busy_ = busy;
    chooseButton_->setEnabled(!busy);
    importButton_->setEnabled(!busy);
    sources_->setEnabled(!busy);
    addSourceButton_->setEnabled(!busy);
    removeSourceButton_->setEnabled(!busy && sources_->count() > 0);
    refreshButton_->setEnabled(!busy && sources_->count() > 0);
    removeButton_->setEnabled(!busy && selectedDictionary(installed_));
    const auto *item = selectedDictionary(available_);
    downloadButton_->setEnabled(!busy && item && !item->data(0, Qt::UserRole + 1).toBool());
    progress_->setVisible(busy);
    cancelButton_->setVisible(busy);
    cancelButton_->setEnabled(busy);
    if (busy) {
        cancelled_.store(false);
        status_->setText(label);
        progress_->setRange(0, 0);
    }
}
void LibraryDialog::finishOperation(const QString &message, bool error) {
    setBusy(false);
    download_.reset();
    status_->setText(error ? QStringLiteral("Could not finish: %1").arg(message) : message);
    if (closeWhenDone_) QDialog::reject();
}
LibraryStorage::Progress LibraryDialog::progressCallback() {
    auto timer = std::make_shared<QElapsedTimer>();
    timer->start();
    return [this, timer](const QString &label, qint64 completed, qint64 total) {
        if (timer->elapsed() < 50 && completed != total) return;
        timer->restart();
        QMetaObject::invokeMethod(this, [this, label, completed, total] {
            status_->setText(QStringLiteral("%1  %2").arg(label, LibraryStorage::formatBytes(completed)));
            if (total > 0) {
                progress_->setRange(0, 1000);
                progress_->setValue(int(std::min(1000.0, 1000.0 * completed / total)));
            } else progress_->setRange(0, 0);
        }, Qt::QueuedConnection);
    };
}
void LibraryDialog::runWorker(std::function<void()> task, std::function<void(const QString &)> finished) {
    auto error = std::make_shared<QString>();
    auto *worker = QThread::create([task = std::move(task), error] {
        try { task(); } catch (const std::exception &e) { *error = exceptionText(e); }
        catch (...) { *error = QStringLiteral("An unexpected dictionary error occurred."); }
    });
    worker_ = worker;
    connect(worker, &QThread::finished, this, [this, worker, finished = std::move(finished), error] {
        worker_ = nullptr;
        worker->deleteLater();
        finished(*error);
    });
    worker->start();
}
void LibraryDialog::refreshInstalled() {
    installed_->clear();
    try {
        dictionaries_ = LibraryStorage::installed(root_);
        qint64 total = 0;
        for (int i = 0; i < dictionaries_.size(); ++i) {
            const auto &dictionary = dictionaries_[i];
            auto *item = new QTreeWidgetItem(installed_, {dictionary.heading,
                dictionary.words < 0 ? QStringLiteral("-") : QLocale().toString(dictionary.words),
                LibraryStorage::formatBytes(dictionary.bytes)});
            item->setData(0, Qt::UserRole, i);
            item->setToolTip(0, dictionary.path);
            total += dictionary.bytes;
        }
        installedSummary_->setText(dictionaries_.isEmpty()
            ? QStringLiteral("No dictionaries yet. Import a file or download one below.")
            : QStringLiteral("%1 %2, %3").arg(dictionaries_.size())
                .arg(dictionaries_.size() == 1 ? QStringLiteral("dictionary") : QStringLiteral("dictionaries"), LibraryStorage::formatBytes(total)));
    } catch (const std::exception &e) {
        dictionaries_.clear();
        installedSummary_->setText(QStringLiteral("Cannot read this dictionary folder."));
        status_->setText(exceptionText(e));
    }
    refreshCatalogView();
}
void LibraryDialog::refreshCatalogView() {
    const auto *selected = selectedDictionary(available_);
    const QString selectedUrl = selected ? selected->data(0, Qt::UserRole + 2).toString() : QString();
    available_->clear();
    QSet<QByteArray> hashes;
    for (const auto &dictionary : dictionaries_) if (!dictionary.sha256.isEmpty()) hashes.insert(dictionary.sha256);
    QString installedEdition;
    bool validEdition = true;
    try {
        installedEdition = LibraryStorage::editionIdentity(root_);
    } catch (const std::exception &) {
        validEdition = false;
    }
    const QString filter = filter_->text().trimmed();
    for (int i = 0; i < catalog_.size(); ++i) {
        const auto &entry = catalog_[i];
        if (!filter.isEmpty() && !entry.label.contains(filter, Qt::CaseInsensitive)
            && !entry.url.toString().contains(filter, Qt::CaseInsensitive)) continue;
        const bool installed = validEdition && LibraryStorage::catalogItemInstalled(entry, installedEdition, hashes);
        auto *item = new QTreeWidgetItem(available_, {entry.label, LibraryStorage::formatBytes(entry.bytes),
            installed ? QStringLiteral("Installed") : QStringLiteral("Available")});
        item->setData(0, Qt::UserRole, i);
        item->setData(0, Qt::UserRole + 1, installed);
        item->setData(0, Qt::UserRole + 2, entry.url.toString());
        item->setToolTip(0, entry.url.toString());
        if (entry.url.toString() == selectedUrl) available_->setCurrentItem(item);
    }
    if (!catalog_.isEmpty()) availableSummary_->setText(QStringLiteral("%1 of %2 dictionaries shown").arg(available_->topLevelItemCount()).arg(catalog_.size()));
}
void LibraryDialog::chooseRoot() {
    const QString folder = QFileDialog::getExistingDirectory(this, QStringLiteral("Choose dictionary folder"), root_);
    if (folder.isEmpty() || folder == root_) return;
    root_ = folder;
    changed_ = true;
    rootLabel_->setText(root_);
    status_->clear();
    refreshInstalled();
}
void LibraryDialog::importFile() {
    const QString file = QFileDialog::getOpenFileName(this, QStringLiteral("Import dictionary"), QString(),
        QStringLiteral("Compiled dictionaries (*.wikblb *.wikblb.xz);;All files (*)"));
    if (!file.isEmpty()) startImport(file);
}
void LibraryDialog::startImport(const QString &file, const QByteArray &hash, qint64 bytes, const QString &sourceName) {
    setBusy(true, QStringLiteral("Preparing dictionary"));
    auto prepared = std::make_shared<std::shared_ptr<LibraryStorage::PreparedImport>>();
    const QString root = root_;
    const auto progress = progressCallback();
    runWorker([this, root, file, hash, bytes, prepared, progress, sourceName] {
        *prepared = LibraryStorage::prepareImport(root, file, hash, bytes, cancelled_, progress, sourceName);
    }, [this, prepared, root](const QString &error) {
        if (!error.isEmpty()) { finishOperation(error, error != QStringLiteral("Cancelled")); return; }
        if (cancelled_.load()) { finishOperation(QStringLiteral("Cancelled")); return; }
        const auto &dictionary = (*prepared)->dictionary;
        if (LibraryStorage::containsDictionary(root, dictionary)
            && QMessageBox::question(this, QStringLiteral("Replace dictionary?"),
                QStringLiteral("Replace the installed %1 dictionary with this file? Saved words and learning progress will remain.")
                    .arg(dictionary.heading), QMessageBox::Yes | QMessageBox::No, QMessageBox::No) != QMessageBox::Yes) {
            finishOperation(QStringLiteral("Import cancelled. The installed dictionary is unchanged."));
            return;
        }
        status_->setText(QStringLiteral("Finishing installation"));
        cancelButton_->setEnabled(false);
        runWorker([root, prepared] { LibraryStorage::commitImport(root, **prepared); },
            [this, prepared](const QString &commitError) {
                if (!commitError.isEmpty()) { finishOperation(commitError, true); return; }
                changed_ = true;
                refreshInstalled();
                const auto &dictionary = (*prepared)->dictionary;
                finishOperation(QStringLiteral("Installed %1: %2 %3.").arg(dictionary.heading,
                    QLocale().toString(dictionary.words), dictionary.words == 1 ? QStringLiteral("word") : QStringLiteral("words")));
            });
    });
}
void LibraryDialog::removeSelected() {
    const auto *item = selectedDictionary(installed_);
    if (!item) return;
    const auto dictionary = dictionaries_.at(item->data(0, Qt::UserRole).toInt());
    if (QMessageBox::question(this, QStringLiteral("Remove dictionary?"),
        QStringLiteral("Remove %1 from this device and free %2? You can import or download it again. Saved words and learning progress will remain.")
            .arg(dictionary.heading, LibraryStorage::formatBytes(dictionary.bytes)),
        QMessageBox::Yes | QMessageBox::No, QMessageBox::No) != QMessageBox::Yes) return;
    setBusy(true, QStringLiteral("Removing %1").arg(dictionary.heading));
    cancelButton_->setEnabled(false);
    const QString root = root_;
    runWorker([root, dictionary] { LibraryStorage::removeDictionary(root, dictionary); },
        [this, dictionary](const QString &error) {
            if (!error.isEmpty()) { finishOperation(error, true); return; }
            changed_ = true;
            refreshInstalled();
            finishOperation(QStringLiteral("Removed %1.").arg(dictionary.heading));
        });
}
QNetworkReply *LibraryDialog::get(const QUrl &url) {
    QNetworkRequest request(url);
    request.setTransferTimeout(30000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::UserVerifiedRedirectPolicy);
    auto *reply = network_->get(request);
    reply_ = reply;
    connect(reply, &QNetworkReply::redirected, this, [reply](const QUrl &target) {
        if (LibraryStorage::isHttpsUrl(target)) reply->redirectAllowed();
        else { reply->setProperty("libraryFailure", QStringLiteral("A download redirected to an unsupported address.")); reply->abort(); }
    });
    return reply;
}
void LibraryDialog::refreshCatalogs() {
    if (busy_) return;
    pendingSources_.clear();
    for (int i = 0; i < sources_->count(); ++i) pendingSources_.append(sources_->itemText(i));
    catalog_.clear();
    catalogErrors_.clear();
    refreshCatalogView();
    if (pendingSources_.isEmpty()) { availableSummary_->setText(QStringLiteral("Add an HTTPS catalogue source to find downloads.")); return; }
    setBusy(true, QStringLiteral("Reading catalogues"));
    fetchNextCatalog();
}
void LibraryDialog::fetchNextCatalog() {
    if (cancelled_.load()) { finishOperation(QStringLiteral("Cancelled")); return; }
    if (pendingSources_.isEmpty()) {
        refreshCatalogView();
        if (catalog_.isEmpty()) availableSummary_->setText(QStringLiteral("No downloads found. Add another source or import a dictionary file."));
        finishOperation(catalogErrors_.isEmpty() ? QStringLiteral("Catalogues refreshed.") : catalogErrors_.join(QLatin1Char('\n')), !catalogErrors_.isEmpty());
        return;
    }
    const QUrl url(pendingSources_.takeFirst());
    status_->setText(QStringLiteral("Reading %1").arg(url.host()));
    auto data = std::make_shared<QByteArray>();
    auto *reply = get(url);
    connect(reply, &QNetworkReply::readyRead, this, [reply, data] {
        data->append(reply->readAll());
        if (data->size() > 2 * 1024 * 1024) {
            reply->setProperty("libraryFailure", QStringLiteral("The catalogue exceeds 2 MiB."));
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, data, url] {
        data->append(reply->readAll());
        QString error = reply->property("libraryFailure").toString();
        const int httpStatus = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (error.isEmpty() && httpStatus == 404) {
            // Keep useful diagnostics without exposing URL credentials, paths or query values.
            qWarning().noquote() << "Catalogue request failed: host=" << url.host()
                                 << "http_status=" << httpStatus << "network_error=" << int(reply->error());
            error = QStringLiteral("Catalogue is not available yet. Import a dictionary or try again later.");
        }
        if (error.isEmpty() && reply->error() != QNetworkReply::NoError) error = reply->errorString();
        if (error.isEmpty()) {
            try {
                const auto entries = LibraryStorage::parseCatalog(*data);
                QSet<QUrl> seen;
                for (const auto &entry : catalog_) seen.insert(entry.url);
                for (const auto &entry : entries) if (!seen.contains(entry.url)) { catalog_.append(entry); seen.insert(entry.url); }
            } catch (const std::exception &e) { error = exceptionText(e); }
        }
        if (!error.isEmpty() && !cancelled_.load()) catalogErrors_.append(QStringLiteral("%1: %2").arg(url.host(), error));
        reply_ = nullptr;
        reply->deleteLater();
        fetchNextCatalog();
    });
}
void LibraryDialog::downloadSelected() {
    const auto *selected = selectedDictionary(available_);
    if (!selected) return;
    const auto item = catalog_.at(selected->data(0, Qt::UserRole).toInt());
    if (!QDir().mkpath(root_)) { finishOperation(QStringLiteral("Cannot create the dictionary folder."), true); return; }
    const QStorageInfo storage(root_);
    qint64 limit = LibraryStorage::MaxDownloadBytes;
    if (storage.isValid() && storage.bytesAvailable() >= 0) limit = std::min(limit, storage.bytesAvailable() - LibraryStorage::SpaceReserve);
    if (limit <= 0 || (item.bytes >= 0 && item.bytes > limit / 2)) {
        finishOperation(QStringLiteral("There is not enough free space to download and install this dictionary."), true);
        return;
    }
    download_ = std::make_unique<QTemporaryFile>(QDir(root_).filePath(QStringLiteral(".download-XXXXXX")));
    if (!download_->open()) { finishOperation(QStringLiteral("Cannot create the download file. Check folder permissions."), true); return; }
    setBusy(true, QStringLiteral("Downloading %1").arg(item.label));
    auto received = std::make_shared<qint64>(0);
    auto *reply = get(item.url);
    auto read = [this, reply, received, limit, item] {
        const QByteArray bytes = reply->readAll();
        *received += bytes.size();
        if (*received > limit / 2 || (item.bytes > 0 && *received > item.bytes)) {
            reply->setProperty("libraryFailure", QStringLiteral("The download exceeds the available space or advertised size."));
            reply->abort();
            return;
        }
        if (download_->write(bytes) != bytes.size()) {
            reply->setProperty("libraryFailure", QStringLiteral("Cannot save the download: %1").arg(download_->errorString()));
            reply->abort();
        }
    };
    connect(reply, &QNetworkReply::readyRead, this, read);
    connect(reply, &QNetworkReply::downloadProgress, this, [this, item](qint64 bytes, qint64 total) {
        if (item.bytes > 0) total = item.bytes;
        status_->setText(QStringLiteral("Downloading %1  %2").arg(item.label, LibraryStorage::formatBytes(bytes)));
        if (total > 0) { progress_->setRange(0, 1000); progress_->setValue(int(std::min(1000.0, 1000.0 * bytes / total))); }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, received, item, read] {
        if (reply->error() == QNetworkReply::NoError) read();
        QString error = reply->property("libraryFailure").toString();
        if (error.isEmpty() && reply->error() != QNetworkReply::NoError) error = reply->errorString();
        reply_ = nullptr;
        reply->deleteLater();
        if (cancelled_.load()) { finishOperation(QStringLiteral("Cancelled")); return; }
        if (!error.isEmpty()) { finishOperation(error, true); return; }
        if (item.bytes > 0 && *received != item.bytes) { finishOperation(QStringLiteral("The download is incomplete. Please try again."), true); return; }
        download_->close();
        startImport(download_->fileName(), item.sha256, item.bytes, QFileInfo(item.url.path()).fileName());
    });
}
void LibraryDialog::cancelOperation() {
    cancelled_.store(true);
    cancelButton_->setEnabled(false);
    status_->setText(QStringLiteral("Cancelling"));
    if (reply_) reply_->abort();
}
void LibraryDialog::saveSources() {
    QStringList sources;
    for (int i = 0; i < sources_->count(); ++i) sources.append(sources_->itemText(i));
    QSettings().setValue(QStringLiteral("library/catalogSources"), sources);
    setBusy(false);
}
void LibraryDialog::addSource() {
    bool ok = false;
    const QString text = QInputDialog::getText(this, QStringLiteral("Add catalogue source"),
        QStringLiteral("HTTPS catalogue URL"), QLineEdit::Normal, QString(), &ok).trimmed();
    if (!ok || text.isEmpty()) return;
    const QUrl url(text, QUrl::StrictMode);
    if (!LibraryStorage::isHttpsUrl(url)) { finishOperation(QStringLiteral("Enter an HTTPS URL without credentials or a fragment."), true); return; }
    const QString normalized = url.toString();
    if (sources_->findText(normalized) < 0) sources_->addItem(normalized);
    sources_->setCurrentText(normalized);
    saveSources();
    refreshCatalogs();
}
void LibraryDialog::removeSource() {
    if (sources_->currentIndex() < 0) return;
    sources_->removeItem(sources_->currentIndex());
    saveSources();
    refreshCatalogs();
}
