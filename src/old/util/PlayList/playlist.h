#ifndef PLAYLIST_H
#define PLAYLIST_H

#include <QObject>
#include <QHash>
#include <QVector>
#include <QSqlDatabase>

#include <algorithm>

#include "app/util/Interface/iplaylist.h"
#include "app/util/Interface/isong.h"
#include "app/util/Interface/musicdatastruct.h"
#include "app/util/Interface/api.h"

class IPlayList;
class ISong;
struct SongInfo;

class PlayList : public QObject
{
    Q_OBJECT
public:
    explicit PlayList(const int id, const QString& name, QObject* parent = nullptr);
    virtual ~PlayList() = default;
    int m_id;
    QString m_name;
    // 顺序标记
    QVector<int> m_songIDs;
    // 歌曲信息
    QHash<int,QSharedPointer<SongInfo>> m_songs;
    bool allowLoop = true;
    bool allowShuffle = false;
    int id() const;
    QString name() const;
    void setName(const QString& name);

    QHash<int, QSharedPointer<SongInfo>> getSongs() const;
    QSharedPointer<SongInfo> getFirstSong() const;
    QSharedPointer<SongInfo> getSong(const int songID) const;
    QSharedPointer<SongInfo> getPreviousSong(int currentSongID) const;
    QVector<int> getSongIDs() const;

    int addSong(const int songID);

    int moveSongs(const QVector<int> songIDs, const int newPos);
    
    int removeSongs(const QVector<int> songIDs);

    int size() const;

    bool songExist(const int songID) const;

    virtual bool isSmart() const { return false; }

private:

signals:
    void PlayListChanged();
    void InsertDuplicatedSong();
    void InsertSong();
    void RemovedSong(const QVector<int> &songIDs);

protected:
    IPlayList *pl_db;
    ISong *song_db;
    // MusicLibrary &musicLib;
    QSqlDatabase m_db;
    // QVector<int> loadAllSongs();
    // MusicLibrary::PlayList playListInfo;

    virtual PlayList* createPlayList(int playListID, const QString& name) const {
        return new PlayList(playListID, name); 
    }

    qint64 m_lastModified;

    int saveToLibrary();
    void loadFromLibrary();
};

#endif