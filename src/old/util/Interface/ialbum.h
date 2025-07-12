#pragma once
#include "musicdatastruct.h"

struct AlbumInfo;
struct SongInfo;

class IAlbum {
public:
    virtual ~IAlbum() = default;
    
    // 本地
    virtual QSharedPointer<AlbumInfo> readLocalSongAlbum(const QString &path) = 0;

    // 写入数据库
    virtual int insertAlbum( const QSharedPointer<AlbumInfo> albumInfo) = 0;

    // 读取数据库
    // 检查专辑是否存在于数据库中
    virtual int albumExists(const QString &albumName, const QString &albumFirstArtist, const int albumReleaseYear) = 0;
    // 从数据库中根据专辑id获取歌曲信息
    virtual QVector<QSharedPointer<SongInfo>> getSongInfobyAlbumID(const int albumID) = 0;

    virtual QSharedPointer<AlbumInfo> getAlbumInfobyID(const int albumID) = 0;
    // 根据不同信息查询专辑id
    virtual QVector<int> searchAlbum(const QString &key, const QVariant &value) = 0;
    // 将歌曲添加至专辑
    virtual bool pairAlbumSong(const int albumID, const int songID, const int track_number = 0, const int disc_number = 0) = 0;
};