#include "musicscannerworker.h"

MusicScannerWorker::MusicScannerWorker(QObject *parent)
    : QObject{parent}, song_db(API::createSongDB())
{
}


void MusicScannerWorker::doScan(const QStringList &musicFolders, int maxFiles) {
    emit scanMusicStarted();

    QStringList musicFiles;
    
    // 扫描文件阶段
    for (const QString &folderPath : musicFolders) {
        try {
            QDir dir(folderPath);

            qDebug() << "Scanning music files in folder:" << folderPath;

            if (!dir.exists()) {
                emit scanMusicFailed(QString("Directory not exists: %1").arg(folderPath));
                continue;
            }

            QStringList supportedFormats = {"*.mp3", "*.flac", "*.wav"}; 
            QDirIterator it(folderPath, supportedFormats, QDir::Files, QDirIterator::Subdirectories);
            while (it.hasNext()) {
                if (maxFiles > 0 && musicFiles.size() >= maxFiles) break;
                musicFiles.append(it.next());
            }
            if (maxFiles > 0 && musicFiles.size() >= maxFiles) break;
        } catch (const std::exception &e) {
            qCritical() << "Exception in folder" << folderPath << ":" << e.what();
            emit scanMusicFailed(QString("Exception in folder %1: %2").arg(folderPath, e.what()));
        } catch (...) {
            qCritical() << "Unknown exception in folder" << folderPath;
            emit scanMusicFailed(QString("Unknown exception in folder %1").arg(folderPath));
        }
    }
    qDebug() << "All scanned music files:";
    try {
        // 扫描结束，将扫描到的临时文件存入数据库
        song_db->insertScanResult(musicFiles);
        song_db->parseInsertResult();
        qDebug() << "Total music files:" << musicFiles.count();
        emit scanMusicFinished(musicFiles.count());

        if (musicFiles.isEmpty()) {
            emit scanTagFailed("No music files found");
            return;
        }
    } catch (const std::exception &e) {
        qCritical() << "Failed to insert scan result:" << e.what();
        emit scanTagFailed(QString("Failed to insert scan result: %1").arg(e.what()));
        return;
    }
}

// void MusicScannerWorker::music2library(const QStringList &musicFiles) {

//     emit scanTagStarted();

//     int tagsRead = 0;
//     for (const QString &filePath : musicFiles) {
//         TagLib::FileRef fileRef(filePath.toStdString().c_str());
//         if (fileRef.isNull() || !fileRef.tag()) {
//             emit scanTagFailed(QString("Failed to read tags: %1").arg(filePath));
//             continue;
//         }

//         TagLib::Tag *tag = fileRef.tag();
//         QString title = QString::fromUtf8(tag->title().toCString(true));
//         QString artist = QString::fromUtf8(tag->artist().toCString(true));
//         QString album = QString::fromUtf8(tag->album().toCString(true));
//         emit musicFileTagRead(filePath, title, artist, album);
//         tagsRead++;
//     }

//     if (tagsRead > 0) {
//         emit scanTagFinished(tagsRead);
//     } else {
//         emit scanTagFailed("No valid tags found in any files");
//     }
// }