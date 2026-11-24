#include "AudioPlaybackStartup.hpp"
#include "MainWindow.hpp"

#include <QApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QMessageBox>
#include <QTimer>
#include <cstdio>
#include <exception>

namespace {
int runGui(int argc, char **argv) {
    WikiDict::configureAudioOnlyPlayback();
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("SmallThingz"));
    QCoreApplication::setApplicationName(QStringLiteral("Dict"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));
    QGuiApplication::setDesktopFileName(QStringLiteral("org.smallthingz.wikidict"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Native Qt 6 Wiktionary reader"));
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption rootOption({QStringLiteral("r"), QStringLiteral("root")},
        QStringLiteral("Dictionary folder (otherwise reopen the last folder)."), QStringLiteral("path"));
    parser.addOption(rootOption);
    QCommandLineOption smokeOption(QStringLiteral("smoke"), QStringLiteral("Construct the native UI and exit after startup validation."));
    parser.addOption(smokeOption);
    parser.addPositionalArgument(QStringLiteral("word"), QStringLiteral("Word to open initially."), QStringLiteral("[word]"));
    parser.process(app);

    try {
        const QString word = parser.positionalArguments().value(0);
        MainWindow window(parser.value(rootOption), word);
        window.show();
        if (parser.isSet(smokeOption)) {
            auto *ready = new QTimer(&app);
            QObject::connect(ready, &QTimer::timeout, &app, [&] { if (!window.isLoading()) app.quit(); });
            ready->start(50);
            QTimer::singleShot(30000, &app, [&] { app.exit(2); });
        }
        return app.exec();
    } catch (const std::exception &error) {
        QMessageBox::critical(nullptr, QStringLiteral("Dict could not start"), QString::fromUtf8(error.what()));
        return 2;
    }
}
}

extern "C" Q_DECL_EXPORT int wikidict_gui_main(int argc, char **argv) noexcept {
    try {
        return runGui(argc, argv);
    } catch (const std::exception &error) {
        std::fprintf(stderr, "wikidict-gio: %s\n", error.what());
    } catch (...) {
        std::fputs("wikidict-gio: desktop startup failed\n", stderr);
    }
    return 2;
}
