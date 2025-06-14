#ifndef SCANMUSIC_H
#define SCANMUSIC_H

#include <QObject>
#include <QDir>
#include <QDirIterator>
#include <QDebug>
#include <QFileInfo>
#include <QStringList>
#include <QSettings>
#include <QThread>

#include <taglib/taglib.h>
#include <taglib/fileref.h>
#include <taglib/tag.h>

#include "musicscannerworker.h"
#include "app/util/Config/configmanager.h"


class MusicScanner : public QObject
{
    Q_OBJECT
    bool m_isScanning = false;
public:
    static MusicScanner& instance();
    ~MusicScanner();

    QSettings* intSetting;

signals:
    void scanMusicStarted();
    void scanMusicFinished(int fileCount);
    void scanMusicFailed(const QString &error);
    void scanTagStarted();
    void scanTagFinished(int tagCount);
    void scanTagFailed(const QString &error);
    void musicFileTagRead(const QString &filePath, const QString &title, const QString &artist, const QString &album);
    void startScanRequested(const QStringList &musicFolders, int maxFiles);

public slots:
    void startScan();

private:
    explicit MusicScanner(QObject *parent = nullptr);
    ConfigManager &configManager;
    QStringList m_supportedFormats = {"*.mp3", "*.flac", "*.wav", "*.ogg", "*.m4a"};
    int maxFiles = 100000;

    QThread *workerThread;
    MusicScannerWorker *worker;
};

#endif // SCANMUSIC_H
