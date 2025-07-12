#pragma once
#include <QVector>
#include "musicdatastruct.h"

struct SongInfo;
struct AlbumInfo;

class ICache{
public:
    virtual ~ICache() = default;
    
    // 歌曲信息缓存
    // virtual QHash<int, QSharedPointer<SongInfo>> songCache = 0;
    // 专辑信息缓存
    // virtual QHash<int, QSharedPointer<AlbumInfo>> albumCache = 0;

    // 通过修改时间检查缓存是否失效
    // virtual bool cacheIsValid(const int &id, const QString &type) = 0;

    // 更新歌曲缓存
    // virtual bool updateSongCache(const int &songID) = 0;
    // 判断歌曲缓存是否存在
    // virtual bool songCacheExist(const int &songID) = 0;
    // 读取歌曲缓存
    virtual QSharedPointer<SongInfo> getSongCache(const int songID) = 0;

    // 更新专辑缓存
    // virtual bool updateAlbumCache(const int &albumID) = 0;
    // 判断专辑缓存是否存在
    // virtual bool albumCacheExist(const int &albumID) = 0;
    // 读取歌曲缓存
    virtual QSharedPointer<AlbumInfo> getAlbumCache(const int albumID) = 0;
};