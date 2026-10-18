#include "LibraryDialog.hpp"
#include "LibraryStore.hpp"
#include <QAbstractButton>
#include <QApplication>
#include <QItemSelectionModel>
#include <QDialog>
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
            // The UI test exercises library framing; pass a real dictionary for a corpus smoke.
            QByteArray bytes("WIKBLB08", 8);
            bytes.append(char(1));
            bytes.append("en", 2); bytes.append(char(0));
            bytes.append("English", 7); bytes.append(char(0));
            bytes.append("apple", 5); bytes.append(char(0));
            bytes.append(char(4)); bytes.append("DPR2", 4);
            QFile file(source);
            require(file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size(), "write framed UI fixture");
        }
        QSettings().setValue(QStringLiteral("library/catalogSources"), QStringList{});
        LibraryDialog dialog(nullptr, temp.filePath(QStringLiteral("dictionaries")));
        dialog.show();
        QTest::qWait(50);
        auto *installed = control<QTreeWidget>(dialog, "installedDictionaries");
        auto *status = control<QLabel>(dialog, "libraryStatus");
        auto *progress = control<QProgressBar>(dialog, "libraryProgress");
        diagnosticStatus = status;
        diagnosticProgress = progress;
        diagnosticStage = "initial empty library";
        auto *import = control<QPushButton>(dialog, "importDictionary");
        auto *remove = control<QPushButton>(dialog, "removeDictionary");
        require(installed->topLevelItemCount() == 0 && import->isEnabled() && !remove->isEnabled(), "actionable empty library");
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
        secondBytes.append(char(4)); secondBytes.append("DPR2", 4);
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
        unavailable.show();
        auto *failure = control<QLabel>(unavailable, "libraryStatus");
        diagnosticStatus = failure;
        diagnosticProgress = control<QProgressBar>(unavailable, "libraryProgress");
        diagnosticStage = "wait connection refusal";
        require(QTest::qWaitFor([&] { return unavailableNetwork->requests == 1 && failure->text() == QStringLiteral("Could not finish: 127.0.0.1: Connection refused"); }, 5000), "catalogue failure is visible");
        require(control<QPushButton>(unavailable, "importDictionary")->isEnabled(), "failed network operation does not disable local import");
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
