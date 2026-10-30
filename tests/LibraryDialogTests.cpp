#include "LibraryDialog.hpp"
#include "LibraryStore.hpp"
#include "LibraryStoreRecovery_p.hpp"
#include <QAbstractButton>
#include <QApplication>
#include <QItemSelectionModel>
#include <QDialog>
#include <QDialogButtonBox>
#include <QScopeGuard>
#include <algorithm>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileDialog>
#include <QLabel>
#include <QLocale>
#include <QLineEdit>
#include <QMessageBox>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProgressBar>
#include <QPushButton>
#include <QSettings>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QTreeWidget>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
template <typename T> T *control(QObject &parent, const char *name) {
    auto *result = parent.findChild<T *>(QString::fromLatin1(name));
    require(result != nullptr, name);
    return result;
}
// Deliberately completes on the event loop so the real finished callback runs.
class MissingCatalogReply final : public QNetworkReply {
public:
    MissingCatalogReply(QNetworkAccessManager::Operation operation, const QNetworkRequest &request, QObject *parent, bool connectionFailure = false)
        : QNetworkReply(parent) {
        setOperation(operation);
        setRequest(request);
        setUrl(request.url());
        open(QIODevice::ReadOnly | QIODevice::Unbuffered);
        if (connectionFailure) {
            setError(QNetworkReply::ConnectionRefusedError, QStringLiteral("Connection refused"));
        } else {
            setAttribute(QNetworkRequest::HttpStatusCodeAttribute, 404);
            setError(QNetworkReply::ContentNotFoundError,
                     QStringLiteral("Error transferring https://user:secret@catalogue.example/private?token=secret - server replied: Not Found"));
        }
        QTimer::singleShot(0, this, [this] { setFinished(true); emit finished(); });
    }
    void abort() override {}
protected:
    qint64 readData(char *, qint64) override { return -1; }
};
class MissingCatalogNetwork final : public QNetworkAccessManager {
public:
    explicit MissingCatalogNetwork(int &destructions, bool connectionFailure = false)
        : destructions_(destructions), connectionFailure_(connectionFailure) {}
    ~MissingCatalogNetwork() override { ++destructions_; }
    int requests = 0;
protected:
    QNetworkReply *createRequest(Operation operation, const QNetworkRequest &request, QIODevice *) override {
        ++requests;
        return new MissingCatalogReply(operation, request, this, connectionFailure_);
    }
private:
    int &destructions_;
    bool connectionFailure_;
};
// Queued partial payload stays pending until the real UI cancellation calls abort.
class CancelDownloadReply final : public QNetworkReply {
public:
    CancelDownloadReply(QNetworkAccessManager::Operation operation, const QNetworkRequest &request,
                        QObject *parent, int &aborts, int &downloadFinishes, int &downloadBytesRead)
        : QNetworkReply(parent), aborts_(aborts), downloadFinishes_(downloadFinishes), downloadBytesRead_(downloadBytesRead),
          download_(request.url().path().endsWith(QStringLiteral(".wikblb"))),
          bytes_(download_ ? QByteArray(32, 'x') : QByteArrayLiteral(
              "https://download.example/French.wikblb\tFrench\t1024\n")) {
        setOperation(operation); setRequest(request); setUrl(request.url());
        open(QIODevice::ReadOnly | QIODevice::Unbuffered);
        QTimer::singleShot(0, this, [this] {
            available_ = true;
            emit readyRead();
            if (!download_) { setFinished(true); emit finished(); }
        });
    }
    qint64 bytesAvailable() const override {
        return (available_ ? bytes_.size() - offset_ : 0) + QNetworkReply::bytesAvailable();
    }
    void abort() override {
        if (isFinished() || abortQueued_) return;
        abortQueued_ = true; ++aborts_;
        QTimer::singleShot(0, this, [this] {
            setError(QNetworkReply::OperationCanceledError, QStringLiteral("Synthetic cancelled transfer"));
            setFinished(true); ++downloadFinishes_; emit finished();
        });
    }
protected:
    qint64 readData(char *data, qint64 maximum) override {
        if (!available_ || offset_ == bytes_.size()) return -1;
        const qint64 count = qMin(maximum, qint64(bytes_.size() - offset_));
        std::copy_n(bytes_.constData() + offset_, count, data); offset_ += count;
        if (download_) downloadBytesRead_ += int(count);
        return count;
    }
private:
    int &aborts_, &downloadFinishes_, &downloadBytesRead_;
    bool download_, available_ = false, abortQueued_ = false;
    QByteArray bytes_;
    qint64 offset_ = 0;
};
class CancelDownloadNetwork final : public QNetworkAccessManager {
public:
    int aborts = 0, downloadFinishes = 0, downloadBytesRead = 0;
protected:
    QNetworkReply *createRequest(Operation operation, const QNetworkRequest &request, QIODevice *) override {
        return new CancelDownloadReply(operation, request, this, aborts, downloadFinishes, downloadBytesRead);
    }
};
void checkDownloadCancellationFocus(const QString &source, const QString &root) {
    std::atomic_bool cancelled = false;
    auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled,
        [](const QString &, qint64, qint64) {});
    LibraryStorage::commitImport(root, *prepared);
    auto read = [](const QString &path) {
        QFile file(path); require(file.open(QIODevice::ReadOnly), "read isolated installed state");
        return file.readAll();
    };
    const auto installed = LibraryStorage::installed(root);
    require(installed.size() == 1, "download cancellation starts with one installed dictionary");
    const QByteArray payload = read(installed.first().path);
    const QByteArray manifest = read(QDir(root).filePath(QStringLiteral(".desktop-library.json")));
    const QByteArray languages = read(QDir(root).filePath(QStringLiteral("languages.tsv")));
    const QVariant oldSources = QSettings().value(QStringLiteral("library/catalogSources"));
    auto restore = qScopeGuard([&] { QSettings().setValue(QStringLiteral("library/catalogSources"), oldSources); });
    QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{QStringLiteral("https://catalogue.example/list")});
    auto network = std::make_unique<CancelDownloadNetwork>();
    auto *observed = network.get();
    LibraryDialog dialog(nullptr, root, std::move(network));
    dialog.resize(580, 480); dialog.show(); dialog.activateWindow();
    auto *available = control<QTreeWidget>(dialog, "availableDictionaries");
    auto *progress = control<QProgressBar>(dialog, "libraryProgress");
    auto *status = control<QLabel>(dialog, "libraryStatus");
    auto *cancel = control<QPushButton>(dialog, "cancelLibraryOperation");
    auto *download = control<QPushButton>(dialog, "downloadDictionary");
    auto *buttons = dialog.findChild<QDialogButtonBox *>();
    require(buttons != nullptr, "library close controls");
    auto *close = buttons->button(QDialogButtonBox::Close);
    require(close != nullptr, "library Close button");
    require(QTest::qWaitFor([&] { return !progress->isVisible() && available->topLevelItemCount() == 1; }, 5000), "queued catalogue is ready");
    available->setCurrentItem(available->topLevelItem(0));
    require(download->isEnabled(), "partial download is selectable");
    QTest::mouseClick(download, Qt::LeftButton);
    require(QTest::qWaitFor([&] {
        return progress->isVisible() && observed->downloadBytesRead == 32 &&
            observed->aborts == 0 && observed->downloadFinishes == 0;
    }, 5000), "real readyRead callback reaches a pending partial download");
    cancel->setFocus();
    require(QTest::qWaitFor([&] { return cancel->hasFocus(); }, 5000), "Cancel owns keyboard focus");
    require(dialog.rect().contains(QRect(cancel->mapTo(&dialog, QPoint()), cancel->size())) &&
        dialog.rect().contains(QRect(close->mapTo(&dialog, QPoint()), close->size())), "Cancel and Close remain within small dialog");
    QTest::keyClick(QApplication::focusWidget(), Qt::Key_Space);
    require(QTest::qWaitFor([&] { return !progress->isVisible(); }, 5000), "queued abort finished callback completes");
    require(observed->aborts == 1 && observed->downloadFinishes == 1 && status->text() == QStringLiteral("Cancelled"), "one cancellation has plain completed status");
    require(!cancel->isVisible() && download->isEnabled() && control<QPushButton>(dialog, "importDictionary")->isEnabled(), "cancellation restores ordinary controls");
    require(QDir(root).entryList({QStringLiteral(".download-*")}, QDir::Files | QDir::Hidden).isEmpty(), "partial owned download is retired");
    require(read(installed.first().path) == payload && read(QDir(root).filePath(QStringLiteral(".desktop-library.json"))) == manifest &&
        read(QDir(root).filePath(QStringLiteral("languages.tsv"))) == languages && LibraryStorage::installed(root).size() == 1,
        "cancelled download preserves installed payload and manifests");
    auto focusUsable = [&] { auto *focus = QApplication::focusWidget(); return focus && dialog.isAncestorOf(focus) && focus->isVisible() && focus->isEnabled(); };
    require(QTest::qWaitFor(focusUsable, 5000), "hidden Cancel does not strand keyboard focus");
    for (int step = 0; step < 40 && QApplication::focusWidget() != close; ++step)
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Tab);
    require(QApplication::focusWidget() == close, "Close remains reachable through the restored focus chain");
    QTest::keyClick(close, Qt::Key_Space);
    require(!dialog.isVisible(), "keyboard Close exits the idle library normally");
}
void answerFile(const QString &path) {
    QTimer::singleShot(300, [path] {
        for (auto *widget : QApplication::topLevelWidgets()) {
            if (auto *dialog = qobject_cast<QFileDialog *>(widget)) {
                dialog->setDirectory(QFileInfo(path).absolutePath());
                QTimer::singleShot(500, dialog, [dialog, path] {
                    auto *filename = dialog->findChild<QLineEdit *>(QStringLiteral("fileNameEdit"));
                    require(filename != nullptr, "file name field");
                    filename->setText(path);
                    require(QMetaObject::invokeMethod(dialog, "accept"), "file dialog accepts");
                });
                return;
            }
        }
    });
}

// Exercise the real replacement prompt, independently of the direct storage tests.
void checkReplacementPreservesUserState(const QString &source, const QString &root,
                                       const QString &replacementSource) {
    std::atomic_bool cancelled = false;
    auto prepared = LibraryStorage::prepareImport(root, source, {}, -1, cancelled,
        [](const QString &, qint64, qint64) {});
    LibraryStorage::commitImport(root, *prepared);
    const auto initial = LibraryStorage::installed(root);
    require(initial.size() == 1, "replacement starts with one installed dictionary");
    const auto read = [](const QString &path) {
        QFile file(path);
        require(file.open(QIODevice::ReadOnly), "read replacement preservation file");
        return file.readAll();
    };
    const QByteArray original = read(initial.first().path);
    const QString manifest = QDir(root).filePath(QStringLiteral(".desktop-library.json"));
    const QString languages = QDir(root).filePath(QStringLiteral("languages.tsv"));
    const QByteArray originalManifest = read(manifest), originalLanguages = read(languages);
    QSettings learning(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
    QSettings settings;
    const QVariant oldLearning = learning.value(QStringLiteral("learning/state"));
    const QVariant oldTheme = settings.value(QStringLiteral("library/catalogSources"));
    auto restore = qScopeGuard([&] {
        if (oldLearning.isValid()) learning.setValue(QStringLiteral("learning/state"), oldLearning);
        else learning.remove(QStringLiteral("learning/state"));
        if (oldTheme.isValid()) settings.setValue(QStringLiteral("library/catalogSources"), oldTheme);
        else settings.remove(QStringLiteral("library/catalogSources"));
    });
    // Exact persisted LearningStore schema: saved history/bookmark and quiz progress.
    const QByteArray savedState = QByteArrayLiteral(R"({"history":[{"key":"en:cat","title":"cat","language":"English","kind":"Noun","clue":"a feline","views":3}],"bookmarks":[{"key":"en:cat","title":"cat","language":"English","kind":"Noun","clue":"a feline"}],"study":{"en:cat":{"right":2,"wrong":1,"last":123}},"settings":{"theme":"dark","quiz_length":7,"random_pool":"bookmarks"}})");
    learning.setValue(QStringLiteral("learning/state"), savedState);
    settings.setValue(QStringLiteral("library/catalogSources"), QStringList{});
    const auto assertUserState = [&] {
        require(QSettings(QStringLiteral("SmallThingz"), QStringLiteral("Dict"))
                    .value(QStringLiteral("learning/state")).toByteArray() == savedState,
                "replacement preserves saved words and learning progress exactly");
        require(QSettings().value(QStringLiteral("library/catalogSources")).toStringList() == QStringList{},
                "replacement preserves unrelated user settings");
    };
    LibraryDialog dialog(nullptr, root);
    dialog.show();
    auto *progress = control<QProgressBar>(dialog, "libraryProgress");
    auto *installed = control<QTreeWidget>(dialog, "installedDictionaries");
    auto *import = control<QPushButton>(dialog, "importDictionary");
    require(QTest::qWaitFor([&] { return !progress->isVisible() && installed->topLevelItemCount() == 1; }, 15000),
            "replacement library initial listing settles");
    const auto replace = [&](const QString &path, bool accept) {
        bool answered = false;
        QTimer responder;
        QObject::connect(&responder, &QTimer::timeout, &dialog, [&] {
            for (auto *widget : QApplication::topLevelWidgets()) {
                auto *box = qobject_cast<QMessageBox *>(widget);
                if (!box || !box->isVisible() || box->windowTitle() != QStringLiteral("Replace dictionary?")) continue;
                require(box->defaultButton() == box->button(QMessageBox::No), "replacement defaults to No");
                answered = true;
                responder.stop();
                if (accept) QTest::mouseClick(box->button(QMessageBox::Yes), Qt::LeftButton);
                else QTest::keyClick(box, Qt::Key_Return);
                return;
            }
        });
        responder.start(10);
        answerFile(path);
        QTest::mouseClick(import, Qt::LeftButton);
        require(QTest::qWaitFor([&] { return answered && !progress->isVisible(); }, 15000),
                "replacement prompt and operation finish");
        require(import->isEnabled() && installed->topLevelItemCount() == 1,
                "replacement restores controls and keeps one dictionary");
        require(QDir(root).entryList({QStringLiteral(".import-*")}, QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot).isEmpty(),
                "replacement retires staging");
        assertUserState();
    };
    replace(source, false);
    require(!dialog.libraryChanged(), "declining replacement does not request reader reload");
    require(control<QLabel>(dialog, "libraryStatus")->text() == QStringLiteral("Import cancelled. The installed dictionary is unchanged."),
            "declining replacement reports unchanged installation");
    require(read(initial.first().path) == original && read(manifest) == originalManifest && read(languages) == originalLanguages,
            "default-No preserves exact installed payload and manifests");
    // Distinct valid one-entry English dictionary, confined to this private library.
    QByteArray replacement("WIKBLB08", 8);
    replacement.append(char(1)); replacement.append("en", 2); replacement.append(char(0));
    replacement.append("English", 7); replacement.append(char(0));
    replacement.append("replacement-only", 16); replacement.append(char(0));
    replacement.append(char(32)); replacement.append("DPR2", 4); replacement.append(QByteArray(28, '\0'));
    require(replacement != original, "replacement fixture differs from installed content");
    QFile file(replacementSource);
    require(file.open(QIODevice::WriteOnly) && file.write(replacement) == replacement.size(), "write private replacement fixture");
    file.close();
    replace(replacementSource, true);
    const auto updated = LibraryStorage::installed(root);
    require(dialog.libraryChanged() && updated.size() == 1 && updated.first().words == 1,
            "accepted replacement requests reload and refreshes metadata without duplicates");
    require(read(updated.first().path) == replacement && read(languages) == originalLanguages,
            "accepted replacement installs exact new content and preserves language listing");
    dialog.close();
}
}
int main(int argc, char **argv) {
    try {
        require(QDir().mkpath(QStringLiteral(".tmp")), "temporary parent directory");
        QTemporaryDir temp(QDir::current().filePath(QStringLiteral(".tmp/library-dialog-tests-XXXXXX")));
        require(temp.isValid(), "temporary directory");
        const auto isolateEnvironment = [&temp](const char *name, const QString &directory) {
            const QString path = temp.filePath(directory);
            require(QDir().mkpath(path), "isolated environment directory");
            require(qputenv(name, QFile::encodeName(path)), "isolated environment variable");
        };
        isolateEnvironment("XDG_CONFIG_HOME", QStringLiteral("config"));
        isolateEnvironment("XDG_CACHE_HOME", QStringLiteral("cache"));
        isolateEnvironment("XDG_DATA_HOME", QStringLiteral("data"));
        isolateEnvironment("XDG_CONFIG_DIRS", QStringLiteral("system-config"));
        isolateEnvironment("XDG_DATA_DIRS", QStringLiteral("system-data"));
        for (const auto format : {QSettings::NativeFormat, QSettings::IniFormat}) {
            for (const auto scope : {QSettings::UserScope, QSettings::SystemScope}) {
                const QString path = temp.filePath(QStringLiteral("settings/%1/%2")
                    .arg(format == QSettings::NativeFormat ? QStringLiteral("native") : QStringLiteral("ini"),
                         scope == QSettings::UserScope ? QStringLiteral("user") : QStringLiteral("system")));
                require(QDir().mkpath(path), "isolated settings directory");
                QSettings::setPath(format, scope, path);
            }
        }
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
        QApplication app(argc, argv);
        app.setOrganizationName(QStringLiteral("WikidictLibraryTests"));
        app.setApplicationName(QStringLiteral("Library"));
        const auto assertIsolated = [&temp](const QSettings &settings) {
            const QString filename = QDir::cleanPath(QFileInfo(settings.fileName()).absoluteFilePath());
            const QString prefix = QDir::cleanPath(temp.path()) + QLatin1Char('/');
            require(filename.startsWith(prefix), "settings file escaped test directory");
        };
        assertIsolated(QSettings());
        assertIsolated(QSettings(QStringLiteral("WikidictLibraryTests"), QStringLiteral("Library")));
        assertIsolated(QSettings(QStringLiteral("SmallThingz"), QStringLiteral("Dict")));
        for (const auto format : {QSettings::NativeFormat, QSettings::IniFormat}) {
            for (const auto scope : {QSettings::UserScope, QSettings::SystemScope}) {
                assertIsolated(QSettings(format, scope, QStringLiteral("WikidictLibraryTests"), QStringLiteral("Library")));
                assertIsolated(QSettings(format, scope, QStringLiteral("SmallThingz"), QStringLiteral("Dict")));
            }
        }
        const char *diagnosticStage = "initial setup";
        QElapsedTimer diagnosticElapsed;
        diagnosticElapsed.start();
        QPointer<QLabel> diagnosticStatus;
        QPointer<QProgressBar> diagnosticProgress;
        QPointer<MissingCatalogNetwork> diagnosticNetwork;
        QTimer::singleShot(25000, &app, [&] {
            std::cerr << "UI smoke timed out\n"
                      << "stage=" << diagnosticStage << " elapsed_ms=" << diagnosticElapsed.elapsed()
                      << " requests=" << (diagnosticNetwork ? diagnosticNetwork->requests : -1) << '\n';
            if (diagnosticStatus) std::cerr << "status=" << diagnosticStatus->text().toStdString() << '\n';
            if (diagnosticProgress) std::cerr << "progress_visible=" << diagnosticProgress->isVisible() << '\n';
            for (auto *widget : QApplication::topLevelWidgets())
                if (widget->isVisible()) std::cerr << widget->metaObject()->className() << ": " << widget->windowTitle().toStdString() << '\n';
            std::exit(EXIT_FAILURE);
        });
        const QString source = argc > 1 ? QFileInfo(QString::fromLocal8Bit(argv[1])).absoluteFilePath() : temp.filePath(QStringLiteral("English.wikblb"));
        if (argc == 1) {
            // Complete empty compiled document; normal import now validates the full body.
            QByteArray bytes("WIKBLB08", 8);
            bytes.append(char(1));
            bytes.append("en", 2); bytes.append(char(0));
            bytes.append("English", 7); bytes.append(char(0));
            bytes.append("apple", 5); bytes.append(char(0));
            bytes.append(char(32)); bytes.append("DPR2", 4); bytes.append(QByteArray(28, '\0'));
            QFile file(source);
            require(file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size(), "write framed UI fixture");
        }
        diagnosticStage = "download cancellation keyboard focus";
        checkDownloadCancellationFocus(source, temp.filePath(QStringLiteral("cancel-download")));
        if (argc > 2 && QString::fromLocal8Bit(argv[2]) == QStringLiteral("--download-cancel-focus")) {
            std::cout << "Library UI: queued download cancellation, small-window focus and installed-state preservation passed\n";
            return EXIT_SUCCESS;
        }
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        checkReplacementPreservesUserState(source, temp.filePath(QStringLiteral("replacement-library")),
                                          temp.filePath(QStringLiteral("replacement-English.wikblb")));
        // The real pending-recovery path must return to the event loop before
        // publishing its recovered listing; no user files or worker test hook.
        {
            const QString recoveryRoot = temp.filePath(QStringLiteral("restart-library"));
            std::atomic_bool cancel = false;
            auto prepared = LibraryStorage::prepareImport(recoveryRoot, source, {}, -1, cancel,
                [](const QString &, qint64, qint64) {});
            LibraryStorage::commitImport(recoveryRoot, *prepared);
            const auto prior = LibraryStorage::installed(recoveryRoot).first();
            QFile original(prior.path);
            require(original.open(QIODevice::ReadOnly), "read recovery fixture");
            const QByteArray priorBytes = original.readAll(); original.close();
            QTemporaryDir staging(QDir(recoveryRoot).filePath(QStringLiteral(".import-XXXXXX")));
            LibraryStorage::detail::beginMutation(recoveryRoot, staging, {prior.path, prior.path + QStringLiteral(".xz")});
            require(QFile::rename(prior.path, staging.filePath(QStringLiteral("previous-0"))), "stage interrupted replacement");
            LibraryDialog recovering(nullptr, recoveryRoot);
            recovering.show();
            auto *recoveryProgress = control<QProgressBar>(recovering, "libraryProgress");
            require(recoveryProgress->isVisible() && !control<QPushButton>(recovering, "importDictionary")->isEnabled(), "recovery starts asynchronously with protected loading controls");
            bool eventLoopServiced = false;
            QTimer::singleShot(0, &recovering, [&] { eventLoopServiced = true; });
            require(QTest::qWaitFor([&] { return !recoveryProgress->isVisible(); }, 15000), "pending recovery listing finishes");
            require(eventLoopServiced && control<QTreeWidget>(recovering, "installedDictionaries")->topLevelItemCount() == 1, "event loop and recovered dictionary listing remain available");
            QFile restored(prior.path);
            require(restored.open(QIODevice::ReadOnly) && restored.readAll() == priorBytes, "UI worker restores exact prior bytes");
            require(recovering.libraryChanged() && recovering.originalRootChanged(), "recovered root reloads existing reader");
            require(!QFileInfo::exists(staging.path()) && !QFileInfo::exists(QDir(recoveryRoot).filePath(QStringLiteral(".desktop-mutation.json"))), "successful UI recovery retires owned staging and journal");
            recovering.close();
        }
        LibraryDialog dialog(nullptr, temp.filePath(QStringLiteral("dictionaries")));
        dialog.show();
        require(QTest::qWaitFor([&] { return !control<QProgressBar>(dialog, "libraryProgress")->isVisible(); }, 15000), "initial asynchronous library listing settles");
        auto *installed = control<QTreeWidget>(dialog, "installedDictionaries");
        auto *status = control<QLabel>(dialog, "libraryStatus");
        auto *progress = control<QProgressBar>(dialog, "libraryProgress");
        diagnosticStatus = status;
        diagnosticProgress = progress;
        diagnosticStage = "initial empty library";
        auto *import = control<QPushButton>(dialog, "importDictionary");
        auto *remove = control<QPushButton>(dialog, "removeDictionary");
        require(installed->topLevelItemCount() == 0 && import->isEnabled() && !remove->isEnabled(), "actionable empty library");
        require(control<QLabel>(dialog, "availableDictionariesSummary")->text() == QStringLiteral("Add a source to browse available dictionaries."), "empty source list offers an available action");
        require(control<QPushButton>(dialog, "addCatalogueSource")->isEnabled() && !control<QPushButton>(dialog, "refreshCatalogues")->isEnabled(), "source-free guidance matches enabled controls");
        diagnosticStage = "import English";
        answerFile(source);
        QTest::mouseClick(import, Qt::LeftButton);
        require(QTest::qWaitFor([&] { return !progress->isVisible() && installed->topLevelItemCount() == 1; }, 15000), "import finishes in UI");
        require(dialog.libraryChanged(), "import marks root for reader reload");
        const auto imported = LibraryStorage::installed(dialog.selectedRoot());
        require(imported.size() == 1 && imported.first().words >= 0, "one installed dictionary with its actual word count");
        const auto words = imported.first().words;
        const QString expectedStatus = QStringLiteral("Installed English: %1 %2.")
            .arg(QLocale().toString(words), words == 1 ? QStringLiteral("word") : QStringLiteral("words"));
        require(status->text() == expectedStatus, "successful import status uses the actual count and singular/plural word");
        if (argc > 2) require(dialog.grab().save(QString::fromLocal8Bit(argv[2])), "save library screenshot");
        // Accessibility row selection need not move the keyboard current index.
        const QString secondSource = temp.filePath(QStringLiteral("French.wikblb"));
        QByteArray secondBytes("WIKBLB08", 8);
        secondBytes.append(char(1));
        secondBytes.append("fr", 2); secondBytes.append(char(0));
        secondBytes.append("French", 6); secondBytes.append(char(0));
        secondBytes.append("chat", 4); secondBytes.append(char(0));
        secondBytes.append(char(32)); secondBytes.append("DPR2", 4); secondBytes.append(QByteArray(28, '\0'));
        QFile secondFile(secondSource);
        require(secondFile.open(QIODevice::WriteOnly) && secondFile.write(secondBytes) == secondBytes.size(), "write second distinct dictionary fixture");
        secondFile.close();
        diagnosticStage = "import French";
        answerFile(secondSource);
        QTest::mouseClick(import, Qt::LeftButton);
        require(QTest::qWaitFor([&] { return !progress->isVisible() && installed->topLevelItemCount() == 2; }, 15000), "second dictionary import finishes");
        QTreeWidgetItem *english = nullptr, *french = nullptr;
        for (int row = 0; row < installed->topLevelItemCount(); ++row) {
            auto *item = installed->topLevelItem(row);
            if (item->text(0) == QStringLiteral("English")) english = item;
            if (item->text(0) == QStringLiteral("French")) french = item;
        }
        require(english && french, "distinct real dictionaries are available for selection regression");
        diagnosticStage = "selected row controls";
        const auto declineSelectedEnglish = [&] {
            bool observedEnglish = false;
            QTimer::singleShot(50, [&] {
                for (auto *widget : QApplication::topLevelWidgets()) {
                    if (auto *box = qobject_cast<QMessageBox *>(widget); box && box->isVisible()) {
                        observedEnglish = box->text().startsWith(QStringLiteral("Remove English from"));
                        box->button(QMessageBox::No)->click();
                        return;
                    }
                }
            });
            QTest::mouseClick(remove, Qt::LeftButton);
            require(observedEnglish, "confirmation targets selected English, independently of keyboard current item");
            require(installed->topLevelItemCount() == 2, "declined selected-row deletion preserves both dictionaries");
        };
        installed->setCurrentItem(nullptr);
        installed->clearSelection();
        english->setSelected(true);
        require(!installed->currentItem() && installed->selectedItems() == QList<QTreeWidgetItem *>{english}, "null current with one selected row");
        require(remove->isEnabled(), "selection alone enables removal");
        declineSelectedEnglish();
        installed->setCurrentItem(french, 0, QItemSelectionModel::NoUpdate);
        require(installed->currentItem() == french && installed->selectedItems() == QList<QTreeWidgetItem *>{english}, "stale other current item does not change selected row");
        require(remove->isEnabled(), "selected row remains actionable with a different current item");
        declineSelectedEnglish();
        installed->clearSelection();
        require(!remove->isEnabled(), "current item without selection does not enable destructive action");
        diagnosticStage = "remove French";
        french->setSelected(true);
        QTimer::singleShot(50, [] {
            for (auto *widget : QApplication::topLevelWidgets())
                if (auto *box = qobject_cast<QMessageBox *>(widget); box && box->isVisible()) { box->button(QMessageBox::Yes)->click(); return; }
        });
        QTest::mouseClick(remove, Qt::LeftButton);
        require(QTest::qWaitFor([&] { return !progress->isVisible() && installed->topLevelItemCount() == 1; }, 5000), "remove only selected French fixture");
        require(installed->topLevelItem(0)->text(0) == QStringLiteral("English"), "unselected English survives selected French removal");
        diagnosticStage = "remove English";
        installed->setCurrentItem(installed->topLevelItem(0));
        require(remove->isEnabled(), "selected installed dictionary enables removal");
        QTimer::singleShot(50, [] {
            for (auto *widget : QApplication::topLevelWidgets()) {
                if (auto *box = qobject_cast<QMessageBox *>(widget); box && box->isVisible()) { box->button(QMessageBox::No)->click(); return; }
            }
        });
        QTest::mouseClick(remove, Qt::LeftButton);
        require(installed->topLevelItemCount() == 1, "declined deletion keeps dictionary");
        QTimer::singleShot(50, [] {
            for (auto *widget : QApplication::topLevelWidgets()) {
                if (auto *box = qobject_cast<QMessageBox *>(widget); box && box->isVisible()) { box->button(QMessageBox::Yes)->click(); return; }
            }
        });
        QTest::mouseClick(remove, Qt::LeftButton);
        require(QTest::qWaitFor([&] { return !progress->isVisible() && installed->topLevelItemCount() == 0; }, 5000), "confirmed deletion finishes");
        require(status->text().startsWith(QStringLiteral("Removed English")), "removal status");

        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{QStringLiteral("https://127.0.0.1:1/dictionaries.list")});
        int unavailableManagerDestructions = 0;
        auto unavailableManager = std::make_unique<MissingCatalogNetwork>(unavailableManagerDestructions, true);
        auto *unavailableNetwork = unavailableManager.get();
        diagnosticStage = "construct connection refusal dialog";
        diagnosticNetwork = unavailableNetwork;
        LibraryDialog unavailable(nullptr, temp.filePath(QStringLiteral("unavailable")), std::move(unavailableManager));
        require(control<QLabel>(unavailable, "availableDictionariesSummary")->text() == QStringLiteral("Refresh the catalogue to browse available dictionaries."), "configured source retains refresh guidance before its request starts");
        unavailable.show();
        auto *failure = control<QLabel>(unavailable, "libraryStatus");
        diagnosticStatus = failure;
        diagnosticProgress = control<QProgressBar>(unavailable, "libraryProgress");
        diagnosticStage = "wait connection refusal";
        require(QTest::qWaitFor([&] { return unavailableNetwork->requests == 1 && failure->text() == QStringLiteral("Could not finish: 127.0.0.1: Connection refused"); }, 5000), "catalogue failure is visible");
        require(control<QPushButton>(unavailable, "importDictionary")->isEnabled(), "failed network operation does not disable local import");
        require(control<QLabel>(unavailable, "availableDictionariesSummary")->text() == QStringLiteral("Could not check all catalogues. Try again or import a dictionary file."),
                "failed catalogue check is not reported as a successful empty result");
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{
            QStringLiteral("https://catalogue.example/private?token=secret")});
        int managerDestructions = 0;
        QPointer<MissingCatalogNetwork> observedManager;
        {
            auto manager = std::make_unique<MissingCatalogNetwork>(managerDestructions);
            observedManager = manager.get();
            diagnosticStage = "construct HTTP 404 dialog";
            diagnosticNetwork = manager.get();
            LibraryDialog missing(nullptr, temp.filePath(QStringLiteral("missing-catalogue")), std::move(manager));
            require(!manager && observedManager->parent() == &missing, "network manager ownership transfers to dialog");
            missing.show();
            auto *missingStatus = control<QLabel>(missing, "libraryStatus");
            auto *missingProgress = control<QProgressBar>(missing, "libraryProgress");
            diagnosticStatus = missingStatus;
            diagnosticProgress = missingProgress;
            diagnosticStage = "wait HTTP 404";
            require(QTest::qWaitFor([&] { return observedManager->requests == 1 && !missingProgress->isVisible(); }, 5000),
                    "asynchronous HTTP 404 callback finishes");
            require(missingStatus->text() == QStringLiteral("Could not finish: catalogue.example: Catalogue is not available yet. Import a dictionary or try again later."),
                    "typed HTTP 404 has actionable guidance without raw transfer diagnostics or URL secrets");
            require(control<QTreeWidget>(missing, "availableDictionaries")->topLevelItemCount() == 0,
                    "HTTP 404 does not create catalogue entries");
            require(control<QLabel>(missing, "availableDictionariesSummary")->text() == QStringLiteral("Could not check all catalogues. Try again or import a dictionary file."),
                    "HTTP 404 summary distinguishes an unavailable catalogue from no downloads");
            auto *localImport = control<QPushButton>(missing, "importDictionary");
            require(localImport->isEnabled(), "HTTP 404 preserves local import");
            diagnosticStage = "import after HTTP 404";
            answerFile(source);
            QTest::mouseClick(localImport, Qt::LeftButton);
            require(QTest::qWaitFor([&] { return !missingProgress->isVisible() && missing.libraryChanged(); }, 15000),
                    "actual local import succeeds after HTTP 404");
            require(control<QTreeWidget>(missing, "installedDictionaries")->topLevelItemCount() == 1,
                    "HTTP 404 recovery installs the local dictionary");
            diagnosticStage = "HTTP 404 dialog teardown";
            require(managerDestructions == 0, "adopted manager lives until dialog teardown");
        }
        diagnosticStage = "verify HTTP 404 manager teardown";
        require(observedManager.isNull() && managerDestructions == 1, "adopted manager is deleted exactly once with the dialog");
        std::cout << "Library UI: empty state, file import, confirmed removal and catalogue failure recovery passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
