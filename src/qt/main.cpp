#include "MainWindow.hpp"

#include <QApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QMessageBox>
#include <QTimer>

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("SmallThingz"));
    QCoreApplication::setApplicationName(QStringLiteral("Dict"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Native Qt 6 Wiktionary reader"));
    parser.addHelpOption();
    parser.addVersionOption();
    QCommandLineOption rootOption({QStringLiteral("r"), QStringLiteral("root")},
        QStringLiteral("Dictionary dataset root."), QStringLiteral("path"),
        QStringLiteral("data/wiktionary-blobs"));
    parser.addOption(rootOption);
    QCommandLineOption smokeOption(QStringLiteral("smoke"), QStringLiteral("Construct the native UI and exit after startup validation."));
    parser.addOption(smokeOption);
    parser.addPositionalArgument(QStringLiteral("word"), QStringLiteral("Word to open initially."), QStringLiteral("[word]"));
    parser.process(app);

    try {
        const QString word = parser.positionalArguments().value(0);
        MainWindow window(parser.value(rootOption), word);
        window.show();
        if (parser.isSet(smokeOption)) QTimer::singleShot(50, &app, &QCoreApplication::quit);
        return app.exec();
    } catch (const std::exception &error) {
        QMessageBox::critical(nullptr, QStringLiteral("Dict could not start"), QString::fromUtf8(error.what()));
        return 2;
    }
}
