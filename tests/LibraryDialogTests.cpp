#include "LibraryDialog.hpp"
#include <QAbstractButton>
#include <QApplication>
#include <QDialog>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QLabel>
#include <QLineEdit>
#include <QMessageBox>
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
        QTimer::singleShot(25000, [] {
            std::cerr << "UI smoke timed out\n";
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
        auto *import = control<QPushButton>(dialog, "importDictionary");
        auto *remove = control<QPushButton>(dialog, "removeDictionary");
        require(installed->topLevelItemCount() == 0 && import->isEnabled() && !remove->isEnabled(), "actionable empty library");
        answerFile(source);
        QTest::mouseClick(import, Qt::LeftButton);
        require(QTest::qWaitFor([&] { return !progress->isVisible() && installed->topLevelItemCount() == 1; }, 15000), "import finishes in UI");
        require(dialog.libraryChanged(), "import marks root for reader reload");
        require(status->text().startsWith(QStringLiteral("Installed English")), "successful import status");
        if (argc > 2) require(dialog.grab().save(QString::fromLocal8Bit(argv[2])), "save library screenshot");
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
        LibraryDialog unavailable(nullptr, temp.filePath(QStringLiteral("unavailable")));
        unavailable.show();
        auto *failure = control<QLabel>(unavailable, "libraryStatus");
        require(QTest::qWaitFor([&] { return failure->text().startsWith(QStringLiteral("Could not finish:")); }, 5000), "catalogue failure is visible");
        require(control<QPushButton>(unavailable, "importDictionary")->isEnabled(), "failed network operation does not disable local import");
        std::cout << "Library UI: empty state, file import, confirmed removal and catalogue failure recovery passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
