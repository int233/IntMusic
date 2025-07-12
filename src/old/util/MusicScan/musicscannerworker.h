#ifndef MUSICSCANNERWORKER_H
#define MUSICSCANNERWORKER_H

#include <QObject>
#include <QStringList>
#include <QDir>
#include <QDirIterator>
#include <QDebug>
#include <QThread>

#include <taglib/taglib.h>
#include <taglib/fileref.h>
#include <taglib/tag.h>

// #include "app/util/Config/musiclibrary.h"
#include "app/util/Interface/isong.h"
#include "app/util/Interface/api.h"


class MusicScannerWorker : public QObject {
    Q_OBJECT
public:
    explicit MusicScannerWorker(QObject *parent = nullptr);
    void music2library(const QStringList &musicFiles);

public slots:
    void doScan(const QStringList &musicFolders, int maxFiles);

private:
    ISong *song_db;

signals:
    void scanMusicStarted();
    void scanMusicFailed(const QString &message);
    void scanMusicFinished(int count);
    void scanTagStarted();
    void scanTagFailed(const QString &message);
    void scanTagFinished(int count);
    void musicFileTagRead(const QString &filePath, const QString &title, const QString &artist, const QString &album);
};

#endif // MUSICSCANNERWORKER_H