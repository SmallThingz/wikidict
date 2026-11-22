// Linux-only test preload: isolate QSettings before the real GUI creates QApplication.
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QSettings>
#include <QString>

#include <cstdlib>
#include <cstdio>

namespace {
[[noreturn]] void fail(const char *reason) {
    std::fprintf(stderr, "settings bootstrap: %s\n", reason);
    std::fflush(stderr);
    std::_Exit(2);
}

void checkPath(const QSettings &settings, const QString &root) {
    const QString path = QDir::cleanPath(settings.fileName());
    if (!path.startsWith(root + QLatin1Char('/'))) fail("settings path escapes root");
}

__attribute__((constructor)) void isolateSettings() {
    const QByteArray rawRoot = qgetenv("WIKIDICT_TEST_SETTINGS_ROOT");
    if (rawRoot.isEmpty()) fail("missing WIKIDICT_TEST_SETTINGS_ROOT");
    const QString root = QDir::cleanPath(QString::fromLocal8Bit(rawRoot));
    if (!QDir::isAbsolutePath(root) || !QDir(root).exists()) fail("root must be an existing absolute directory");

    QCoreApplication::setOrganizationName(QStringLiteral("SmallThingz"));
    QCoreApplication::setApplicationName(QStringLiteral("Dict"));
    for (const auto format : {QSettings::NativeFormat, QSettings::IniFormat}) {
        for (const auto scope : {QSettings::UserScope, QSettings::SystemScope}) {
            const QString path = root + (format == QSettings::NativeFormat ? QStringLiteral("/native") : QStringLiteral("/ini"))
                + (scope == QSettings::UserScope ? QStringLiteral("/user") : QStringLiteral("/system"));
            if (!QDir().mkpath(path)) fail("cannot create settings directory");
            QSettings::setPath(format, scope, path);
            QSettings explicitSettings(format, scope, QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
            checkPath(explicitSettings, root);
        }
        QSettings::setDefaultFormat(format);
        QSettings defaultSettings;
        QSettings namedSettings(QStringLiteral("SmallThingz"), QStringLiteral("Dict"));
        checkPath(defaultSettings, root);
        checkPath(namedSettings, root);
    }
    QSettings::setDefaultFormat(QSettings::NativeFormat);
    QFile marker(root + QStringLiteral("/bootstrap-ok"));
    if (!marker.open(QIODevice::WriteOnly) || marker.write("ok\n") != 3) fail("cannot write bootstrap marker");
}
}
