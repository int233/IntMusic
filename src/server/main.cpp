#define APP_VERSION "1.0.0"
#define APP_NAME "IntMusicServer"

#include "intmusic_server.h"

#include <QApplication>
#include <QLocale>
#include <QTranslator>

int main(int argc, char *argv[])
{
    QApplication appserver(argc, argv);
    appserver.setApplicationName(APP_NAME);
    appserver.setApplicationVersion(APP_VERSION);

    QTranslator translator;
    const QStringList uiLanguages = QLocale::system().uiLanguages();
    for (const QString &locale : uiLanguages) {
        const QString baseName = "IntMusic_" + QLocale(locale).name();
        if (translator.load(":/i18n/" + baseName)) {
            appserver.installTranslator(&translator);
            break;
        }
    }
    appserver.setQuitOnLastWindowClosed(false);
    IntMusicServer w;
    w.show();
    return appserver.exec();
}